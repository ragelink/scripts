#!/usr/bin/env bash
# Tests for ssm-run: bash ssm-run/test.sh [t_name...]
#
# aws is a file-backed fake placed first on PATH; nothing here reaches AWS. Each test
# writes a scenario (command status sequence and per-instance results) for the fake.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/ssm-run
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ssm-run-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

CID=aaaabbbb-cccc-dddd-eeee-ffff00001111
I1=i-0123456789abcdef0
I2=i-0fedcba9876543210

FAKEBIN=$ROOT/fakebin
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/aws" <<'EOF'
#!/usr/bin/env python3
# File-backed fake of the aws CLI calls ssm-run makes. State lives in $FAKE.
import json, os, shutil, stat, sys

state = os.environ["FAKE"]
argv = sys.argv[1:]
with open(os.path.join(state, "aws.calls"), "a") as log:
    log.write(" ".join(argv) + "\n")

def opt(name):
    return argv[argv.index(name) + 1] if name in argv else None

def fail(msg, code=254):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

def out(obj):
    print(json.dumps(obj))

cid = "aaaabbbb-cccc-dddd-eeee-ffff00001111"
words = [a for i, a in enumerate(argv) if not a.startswith("--") and not (i and argv[i - 1].startswith("--"))]
with open(os.path.join(state, "scenario.json")) as f:
    sc = json.load(f)
if opt("--output") != "json":
    fail("fake aws: expected --output json", 2)
if words == ["ssm", "send-command"]:
    src = opt("--cli-input-json") or ""
    if not src.startswith("file://"):
        fail("fake aws: the request must arrive as a file", 2)
    path = src[len("file://"):]
    with open(os.path.join(state, "request.modes"), "w") as f:
        f.write("file=%o dir=%o\n" % (stat.S_IMODE(os.stat(path).st_mode),
                                      stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode)))
    shutil.copy(path, os.path.join(state, "request.json"))
    if sc.get("send_error"):
        fail(sc["send_error"])
    out({"Command": {"CommandId": cid, "Status": "Pending"}})
elif words == ["ssm", "list-commands"]:
    if opt("--command-id") != cid:
        fail("fake aws: wrong command id", 2)
    counter = os.path.join(state, "list-commands.count")
    n = int(open(counter).read()) if os.path.exists(counter) else 0
    with open(counter, "w") as f:
        f.write(str(n + 1))
    statuses = sc["statuses"]
    out({"Commands": [{"CommandId": cid, "Status": statuses[min(n, len(statuses) - 1)]}]})
elif words == ["ssm", "list-command-invocations"]:
    if opt("--command-id") != cid:
        fail("fake aws: wrong command id", 2)
    out({"CommandInvocations": [{"CommandId": cid, "InstanceId": iid, "Status": inv["Status"]}
                                for iid, inv in sc["invocations"].items()]})
elif words == ["ssm", "get-command-invocation"]:
    iid = opt("--instance-id")
    if opt("--command-id") != cid or iid not in sc["invocations"]:
        fail("An error occurred (InvocationDoesNotExist) when calling the GetCommandInvocation operation")
    d = {"CommandId": cid, "InstanceId": iid, "PluginName": "aws:runShellScript", "ResponseCode": -1,
         "StandardOutputContent": "", "StandardErrorContent": ""}
    d.update(sc["invocations"][iid])
    out(d)
else:
    fail("fake aws: unexpected call: " + " ".join(argv), 2)
EOF
chmod +x "$FAKEBIN/aws"
[ "$(PATH=$FAKEBIN:$BASE_PATH command -v aws)" = "$FAKEBIN/aws" ] || { echo "fake aws is not first on PATH" >&2; exit 1; }

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
scenario() { printf '%s\n' "$1" >"$FAKE/scenario.json"; }
run() {  # run ARGS...: ssm-run with stdin from /dev/null; output in $FAKE/out and $FAKE/err, status in RC
  RC=0
  PATH=$FAKEBIN:$BASE_PATH "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null || RC=$?
}
run_stdin() {  # run_stdin TEXT ARGS...: like run, with TEXT on stdin
  local text=$1
  shift
  RC=0
  printf '%s' "$text" | PATH=$FAKEBIN:$BASE_PATH "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" || RC=$?
}
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_out() { grep -qF -- "$1" "$FAKE/out" || fail "stdout lacks: $1"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1"; }
calls() { grep -c -- "$1" "$FAKE/aws.calls" 2>/dev/null || true; }
request() {  # request PYTHON-EXPR: evaluate against the request the fake received, as r
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FAKE/request.json" "$1"
}
script() { printf '#!/bin/bash\necho hello\n' >"$FAKE/script.sh"; }
SUCCESS2='{"statuses": ["Success"], "invocations": {
  "'$I2'": {"Status": "Success", "StatusDetails": "Success", "ResponseCode": 0, "StandardOutputContent": "out from two\n"},
  "'$I1'": {"Status": "Success", "StatusDetails": "Success", "ResponseCode": 0, "StandardOutputContent": "out from one\n",
            "StandardErrorContent": "warning from one\n"}}}'

one_test() {
  FAKE=$ROOT/$1
  mkdir -p "$FAKE"
  export FAKE AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION
  scenario "$SUCCESS2"
  "$1"
}
PASSED=0
FAILED=""
run_test() {
  local rc=0
  set +e
  (set -e; one_test "$1")
  rc=$?
  set -e
  if [ $rc = 0 ]; then
    PASSED=$((PASSED + 1))
    echo "ok   $1"
  else
    FAILED="$FAILED $1"
    echo "FAIL $1"
  fi
}

# ---------- tests ----------
t_commands_round_trip_exactly() {
  # quotes, backquotes, $vars, a trailing backslash, a tab, CRLF, a form feed, an empty
  # line, non-ASCII, JSON-looking text and trailing spaces all reach SSM unchanged
  python3 - "$FAKE/script.sh" <<'PY'
import sys
lines = ['#!/bin/bash', 'echo "double $HOME `id`"', "echo 'single' \\", "printf '%s\\t%s\\n' a\tb",
         'crlf line', '', 'café — ünïcode', '{"json": ["looks", 1]}', 'form\x0cfeed',
         'trailing spaces   ']
data = "\n".join(lines[:4]) + "\n" + lines[4] + "\r\n" + "\n".join(lines[5:]) + "\n"
open(sys.argv[1], "wb").write(data.encode("utf-8"))
PY
  run -i "$I1" "$FAKE/script.sh"
  expect_rc 0
  request 'r["Parameters"]["commands"]' >"$FAKE/commands"
  python3 - "$FAKE/commands" <<'PY' || fail "commands did not round-trip"
import ast, sys
want = ['#!/bin/bash', 'echo "double $HOME `id`"', "echo 'single' \\", "printf '%s\\t%s\\n' a\tb",
        'crlf line', '', 'café — ünïcode', '{"json": ["looks", 1]}', 'form\x0cfeed',
        'trailing spaces   ']
got = ast.literal_eval(open(sys.argv[1], encoding="utf-8").read())
sys.exit(0 if got == want else "got %r" % (got,))
PY
}

t_request_for_instance_ids() {
  script
  run -i "$I1,$I2" -i "$I1" "$FAKE/script.sh" --timeout 120 --working-dir /opt/app --comment "deploy check" \
    --max-concurrency 10% --max-errors 1
  expect_rc 0
  [ "$(request 'r["DocumentName"]')" = AWS-RunShellScript ] || fail "wrong document"
  [ "$(request 'r["InstanceIds"]')" = "['$I1', '$I2']" ] || fail "instance ids: $(request 'r["InstanceIds"]')"
  [ "$(request 'r["Parameters"]["executionTimeout"]')" = "['120']" ] || fail "executionTimeout"
  [ "$(request 'r["Parameters"]["workingDirectory"]')" = "['/opt/app']" ] || fail "workingDirectory"
  [ "$(request 'r["Comment"], r["MaxConcurrency"], r["MaxErrors"]')" = "('deploy check', '10%', '1')" ] ||
    fail "comment/concurrency/errors"
  [ "$(request '"Targets" in r')" = False ] || fail "Targets sent with instance ids"
  [ "$(cat "$FAKE/request.modes")" = "file=600 dir=700" ] || fail "request file not private: $(cat "$FAKE/request.modes")"
}

t_tag_targets_group_values_by_key() {
  script
  run -t Env=prod -t Role=web,api -t Env=staging "$FAKE/script.sh"
  expect_rc 0
  [ "$(request 'r["Targets"]')" = "[{'Key': 'tag:Env', 'Values': ['prod', 'staging']}, {'Key': 'tag:Role', 'Values': ['web,api']}]" ] ||
    fail "targets: $(request 'r["Targets"]')"
  [ "$(request '"InstanceIds" in r')" = False ] || fail "InstanceIds sent with tags"
}

t_script_from_stdin() {
  run_stdin $'uname -a\nid\n' -i "$I1"
  expect_rc 0
  [ "$(request 'r["Parameters"]["commands"]')" = "['uname -a', 'id']" ] || fail "commands from stdin"
  [ "$(request 'r["Comment"]')" = "ssm-run stdin" ] || fail "default comment"
}

t_prints_results_sorted_and_exits_0() {
  script
  run -i "$I2,$I1" "$FAKE/script.sh"
  expect_rc 0
  python3 - "$FAKE/out" "$I1" "$I2" <<'PY' || fail "unexpected output: $(cat "$FAKE/out")"
import sys
out, i1, i2 = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
want = ("== %s: Success, exit 0\nout from one\n-- stderr\nwarning from one\n"
        "== %s: Success, exit 0\nout from two\n"
        "2 instances: 2 succeeded, 0 did not\n") % (i1, i2)
sys.exit(0 if out == want else 1)
PY
  expect_err "sent command $CID"
}

t_failed_instance_exits_1() {
  script
  scenario '{"statuses": ["InProgress", "Failed"], "invocations": {
    "'$I1'": {"Status": "Success", "StatusDetails": "Success", "ResponseCode": 0, "StandardOutputContent": "fine\n"},
    "'$I2'": {"Status": "Failed", "StatusDetails": "Failed", "ResponseCode": 3, "StandardErrorContent": "boom"}}}'
  run -i "$I1,$I2" "$FAKE/script.sh"
  expect_rc 1
  expect_out "== $I2: Failed, exit 3"
  expect_out "boom"
  expect_out "2 instances: 1 succeeded, 1 did not"
  expect_out "  $I2: Failed (exit 3)"
  [ "$(calls list-commands)" = 2 ] || fail "expected two status polls"
}

t_timed_out_on_host() {
  script
  scenario '{"statuses": ["TimedOut"], "invocations": {
    "'$I1'": {"Status": "TimedOut", "StatusDetails": "ExecutionTimedOut", "ResponseCode": -1}}}'
  run -i "$I1" "$FAKE/script.sh"
  expect_rc 1
  expect_out "== $I1: TimedOut (ExecutionTimedOut)"
  expect_out "  $I1: TimedOut"
}

t_local_wait_runs_out() {
  script
  scenario '{"statuses": ["InProgress"], "invocations": {"'$I1'": {"Status": "InProgress"}}}'
  run -i "$I1" "$FAKE/script.sh" --wait 1
  expect_rc 1
  expect_out "== $I1: InProgress"
  expect_out "still running after 1s: aws ssm list-command-invocations --command-id $CID --details"
  [ "$(calls get-command-invocation)" = 0 ] || fail "fetched output of an unfinished invocation"
}

t_no_instances_matched() {
  script
  scenario '{"statuses": ["Success"], "invocations": {}}'
  run -t Env=nowhere "$FAKE/script.sh"
  expect_rc 1
  expect_out "no instances matched the targets"
}

t_output_dir_files() {
  script
  run -i "$I1,$I2" "$FAKE/script.sh" --output-dir "$FAKE/results" --quiet
  expect_rc 0
  ! grep -q "out from one" "$FAKE/out" || fail "--quiet printed script output"
  [ "$(cat "$FAKE/results/$I1.stdout")" = "out from one" ] || fail "stdout file"
  [ "$(cat "$FAKE/results/$I1.stderr")" = "warning from one" ] || fail "stderr file"
  [ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["Status"], d["ResponseCode"], d["CommandId"])' "$FAKE/results/$I2.json")" = "Success 0 $CID" ] ||
    fail "json file"
  python3 - "$FAKE/results" <<'PY' || fail "result files or directory not private"
import os, stat, sys
d = sys.argv[1]
ok = stat.S_IMODE(os.stat(d).st_mode) == 0o700 and all(
    stat.S_IMODE(os.stat(os.path.join(d, f)).st_mode) == 0o600 for f in os.listdir(d))
sys.exit(0 if ok and len(os.listdir(d)) == 6 else 1)
PY
}

t_truncation_note() {
  script
  python3 - "$FAKE/scenario.json" "$I1" <<'PY'
import json, sys
json.dump({"statuses": ["Success"], "invocations": {sys.argv[2]: {
    "Status": "Success", "StatusDetails": "Success", "ResponseCode": 0,
    "StandardOutputContent": "x" * 24000}}}, open(sys.argv[1], "w"))
PY
  run -i "$I1" "$FAKE/script.sh" --quiet
  expect_rc 0
  expect_out "($I1: stdout truncated by SSM at 24000 characters)"
}

t_dry_run_calls_nothing() {
  script
  run -i "$I1" "$FAKE/script.sh" --dry-run
  expect_rc 0
  [ ! -e "$FAKE/aws.calls" ] || fail "--dry-run called aws"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["Parameters"]["commands"] == ["#!/bin/bash", "echo hello"] else 1)' "$FAKE/out" ||
    fail "--dry-run did not print the request"
}

t_profile_and_region_on_every_call() {
  script
  scenario '{"statuses": ["Success"], "invocations": {"'$I1'": {"Status": "Success", "ResponseCode": 0}}}'
  run -i "$I1" "$FAKE/script.sh" --profile acme --region eu-west-1
  expect_rc 0
  [ "$(grep -vc -- '^--profile acme --region eu-west-1 ssm ' "$FAKE/aws.calls" || true)" = 0 ] ||
    fail "a call without --profile/--region: $(cat "$FAKE/aws.calls")"
  [ "$(wc -l <"$FAKE/aws.calls" | tr -d ' ')" = 4 ] || fail "expected 4 aws calls"
}

t_aws_error_exits_2() {
  script
  scenario '{"statuses": ["Success"], "invocations": {}, "send_error": "An error occurred (InvalidInstanceId) when calling the SendCommand operation: Instances not in a valid state"}'
  run -i "$I1" "$FAKE/script.sh"
  expect_rc 2
  expect_err "aws ssm send-command failed: An error occurred (InvalidInstanceId)"
}

t_argument_errors() {
  script
  run "$FAKE/script.sh"
  expect_rc 2
  expect_err "give either --instance-ids or --tag"
  run -i "$I1" -t Env=prod "$FAKE/script.sh"
  expect_rc 2
  run -i i-nothex "$FAKE/script.sh"
  expect_rc 2
  expect_err "not an instance id: i-nothex"
  run -t Env "$FAKE/script.sh"
  expect_rc 2
  expect_err "--tag needs KEY=VALUE"
  run -i "$I1" "$FAKE/script.sh" --timeout 0
  expect_rc 2
  run -i "$I1" "$FAKE/script.sh" --max-errors lots
  expect_rc 2
  run -i "$I1" "$FAKE/missing.sh"
  expect_rc 2
  expect_err "cannot read $FAKE/missing.sh"
  printf '\n  \n' >"$FAKE/empty.sh"
  run -i "$I1" "$FAKE/empty.sh"
  expect_rc 2
  expect_err "the script is empty"
  printf 'caf\351\n' >"$FAKE/latin1.sh"
  run -i "$I1" "$FAKE/latin1.sh"
  expect_rc 2
  expect_err "not UTF-8"
  local ids="" n
  for n in $(seq 10 60); do ids="$ids,i-0aaaaaaaaaaaaa$n"; done
  run -i "${ids#,}" "$FAKE/script.sh"
  expect_rc 2
  expect_err "at most 50 instance ids"
  [ ! -e "$FAKE/aws.calls" ] || fail "aws ran for invalid arguments"
}

echo "ssm-run tests"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
