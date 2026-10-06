#!/usr/bin/env bash
# Tests for ecs-ir-capture: bash ecs-ir-capture/test.sh [t_name...]
# TEST_BASH=/bin/bash runs the tool and the host script under macOS's bash 3.2.
#
# The host script runs locally against a fake /proc tree (IR_CAPTURE_PROC), with fake
# docker, ss and aws first on PATH. On Linux, one more test captures a real process
# through the real /proc. The wrapper test sends the script through ../ssm-run with
# the fake aws. Nothing reaches AWS or Docker.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/ecs-ir-capture
TEST_BASH=$(command -v "${TEST_BASH:-bash}")
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ecs-ir-capture-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

CID=abcdef0123abcdef0123abcdef0123abcdef0123abcdef0123abcdef0123abcd
CID2=fedcba3210fedcba3210fedcba3210fedcba3210fedcba3210fedcba3210fedc
I1=i-0123456789abcdef0

FAKEBIN=$ROOT/fakebin
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/docker" <<'EOF'
#!/bin/sh
# Fake docker: only the read-only calls ecs-ir-capture may make. Anything else
# (kill, stop, pause, rm, exec, ...) is logged as FORBIDDEN and fails.
echo "$*" >>"$FAKE/docker.calls"
case "$1" in
  ps) [ "$*" = "ps -a --no-trunc" ] || exit 2; echo "CONTAINER ID   IMAGE   COMMAND   STATUS" ;;
  inspect) [ "$2" = --format ] || exit 2; printf '%s' "$3" >"$FAKE/inspect.format"; echo "Id=$4"; echo "Image=my-app:prod" ;;
  diff) echo "A /tmp/.x"; echo "A /tmp/.x/xmrig" ;;
  logs) [ "$2 $3 $4" = "--timestamps --since $FAKE_LOG_SINCE" ] || exit 2
    echo "2026-10-06T00:00:01Z app started"; echo "2026-10-06T00:00:02Z app error" >&2 ;;
  *) echo "FORBIDDEN $*" >>"$FAKE/docker.calls"; exit 2 ;;
esac
EOF
cat >"$FAKEBIN/ss" <<'EOF'
#!/bin/sh
echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
EOF
# ps is faked too: the real one lists every process on the machine running the tests,
# which would make the "no secret value anywhere in the evidence" checks depend on them.
cat >"$FAKEBIN/ps" <<'EOF'
#!/bin/sh
[ "$*" = auxww ] || exit 2
echo "USER  PID %CPU %MEM COMMAND"
echo "root    1  0.0  0.0 /sbin/init"
EOF
cat >"$FAKEBIN/aws" <<'EOF'
#!/usr/bin/env python3
# Fake aws: `s3 cp` for the host-side upload, and the SSM calls ssm-run makes.
import json, os, shutil, sys
state = os.environ["FAKE"]
argv = sys.argv[1:]
with open(os.path.join(state, "aws.calls"), "a") as log:
    log.write(" ".join(argv) + "\n")
def opt(name):
    return argv[argv.index(name) + 1] if name in argv else None
def out(obj):
    print(json.dumps(obj))
words = [a for i, a in enumerate(argv) if not a.startswith("--") and not (i and argv[i - 1].startswith("--"))]
cid = "aaaabbbb-cccc-dddd-eeee-ffff00001111"
if words[:2] == ["s3", "cp"] and len(words) == 4 and argv[-1] == "--only-show-errors":
    if os.path.exists(os.path.join(state, "s3_fail")):
        sys.stderr.write("upload failed: AccessDenied\n")
        sys.exit(1)
    dest = os.path.join(state, "s3", words[3][len("s3://"):])
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy(words[2], dest)
elif words == ["ssm", "send-command"]:
    shutil.copy(opt("--cli-input-json")[len("file://"):], os.path.join(state, "request.json"))
    out({"Command": {"CommandId": cid}})
elif words == ["ssm", "list-commands"]:
    out({"Commands": [{"CommandId": cid, "Status": "Success"}]})
elif words == ["ssm", "list-command-invocations"]:
    out({"CommandInvocations": [{"InstanceId": "i-0123456789abcdef0", "Status": "Success"}]})
elif words == ["ssm", "get-command-invocation"]:
    out({"InstanceId": opt("--instance-id"), "Status": "Success", "StatusDetails": "Success",
         "ResponseCode": 0, "StandardOutputContent": "ecs-ir-capture on host\n", "StandardErrorContent": ""})
else:
    sys.stderr.write("fake aws: unexpected call: %s\n" % " ".join(argv))
    sys.exit(2)
EOF
chmod +x "$FAKEBIN"/*
for t in aws docker ps ss; do
  [ "$(PATH=$FAKEBIN:$BASE_PATH command -v "$t")" = "$FAKEBIN/$t" ] || { echo "fake $t is not first on PATH" >&2; exit 1; }
done

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_out() { grep -qF -- "$1" "$FAKE/out" || fail "stdout lacks: $1"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1"; }
sum() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
mode() { python3 -c 'import os,stat,sys; print("%o" % stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))' "$1"; }

nul() { printf '%s\0' "$@"; }  # NUL-terminated records, as in /proc/PID/cmdline and environ
fake_proc() {  # fake_proc PID PPID CGROUP EXE-TARGET: one /proc/PID entry; write cmdline/environ after
  local p=$FAKE/proc/$1
  mkdir -p "$p/fd"
  : >"$p/cmdline"
  : >"$p/environ"
  printf 'Name:\tfake\nPPid:\t%s\n' "$2" >"$p/status"
  printf '00400000-00452000 r-xp 00000000 08:02 173521 %s\n' "$4" >"$p/maps"
  printf '%s\n' "$3" >"$p/cgroup"
  ln -s "$4" "$p/exe"
  ln -s /tmp "$p/cwd"
  ln -s /dev/null "$p/fd/0"
  ln -s "socket:[$1]" "$p/fd/3"
}
standard_procs() {  # three matching processes (two in one container), one other container, one kernel thread
  printf 'fake miner binary\n' >"$FAKE/xmrig.bin"
  printf 'fake proxy binary\n' >"$FAKE/proxy.bin"
  printf 'fake nginx binary\n' >"$FAKE/nginx.bin"
  fake_proc 4242 1 "0::/system.slice/docker-$CID.scope" "$FAKE/xmrig.bin"
  nul /tmp/.x/xmrig --donate-level 1 -o pool.example:3333 >"$FAKE/proc/4242/cmdline"
  nul PATH=/usr/bin DB_PASSWORD=pw-fake-aaaa API_TOKEN=tok-fake-bbbb "PRIVATE_KEY=line1-fake
line2-fake" Aws_Secret_Thing=mixed-case-fake HOME=/root >"$FAKE/proc/4242/environ"
  fake_proc 4343 4242 "0::/system.slice/docker-$CID.scope" "$FAKE/xmrig.bin"
  nul xmrig --threads 2 >"$FAKE/proc/4343/cmdline"
  fake_proc 5000 1 "0::/system.slice/docker-$CID2.scope" "$FAKE/nginx.bin"
  nul "nginx: master process" >"$FAKE/proc/5000/cmdline"
  fake_proc 6000 2 0::/ "$FAKE/nginx.bin"  # a kernel thread: empty command line
  fake_proc 7000 1 0::/user.slice "$FAKE/proxy.bin"
  nul /usr/local/bin/xmrig-proxy >"$FAKE/proc/7000/cmdline"
}
evidence_dir() {  # the one evidence directory (not the tarball) under $FAKE/evidence
  local d
  for d in "$FAKE"/evidence/*; do
    if [ -d "$d" ]; then echo "$d"; return 0; fi
  done
}
capture() {  # capture [wrapper options...]: generate the host script for pattern xmrig and run it on the fake /proc
  RC=0
  "$TEST_BASH" "$TOOL" --print-script --pattern xmrig --evidence-root "$FAKE/evidence" "$@" >"$FAKE/capture.sh" ||
    fail "--print-script failed"
  IR_CAPTURE_PROC=$FAKE/proc PATH=$FAKEBIN:$BASE_PATH "$TEST_BASH" "$FAKE/capture.sh" >"$FAKE/out" 2>"$FAKE/err" || RC=$?
  EV=$(evidence_dir)
}
wrapper() {  # wrapper ARGS...: the ssm-run path, with the fake aws
  RC=0
  PATH=$FAKEBIN:$BASE_PATH "$TEST_BASH" "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null || RC=$?
}

one_test() {
  FAKE=$ROOT/$1
  mkdir -p "$FAKE/proc"
  export FAKE FAKE_LOG_SINCE=2h AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset IR_CAPTURE_PROC
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

# ---------- host script on a fake /proc ----------
t_captures_matching_processes_only() {
  standard_procs
  capture
  expect_rc 0
  [ -n "$EV" ] || fail "no evidence directory"
  [ "$(mode "$EV")" = 700 ] || fail "evidence directory is $(mode "$EV"), not 700"
  [ "$(cd "$EV" && echo proc-*)" = "proc-4242 proc-4343 proc-7000" ] || fail "captured: $(cd "$EV" && echo proc-*)"
  expect_out "matched and captured 3 processes"
  expect_out "pattern: xmrig"
  [ "$(cat "$EV/proc-4242/cmdline.txt")" = "/tmp/.x/xmrig --donate-level 1 -o pool.example:3333 " ] || fail "cmdline"
  for f in exe.path status.txt maps.txt cgroup.txt cwd.txt fd.txt container-id.txt; do
    [ -s "$EV/proc-4242/$f" ] || fail "missing proc-4242/$f"
  done
  grep -q 'socket:\[4242\]' "$EV/proc-4242/fd.txt" || fail "fd listing lacks the socket"
  [ "$(cat "$EV/proc-4242/cwd.txt")" = /tmp ] || fail "cwd"
  [ ! -e "$EV/proc-7000/container-id.txt" ] || fail "a host process got a container id"
  for f in system.txt ps.txt sockets.txt docker-ps.txt; do [ -s "$EV/host/$f" ] || fail "missing host/$f"; done
}

t_kernel_threads_are_skipped() {
  # a pattern that matches anything still skips kernel threads (empty command line)
  standard_procs
  capture --pattern '.*'
  expect_rc 0
  [ "$(cd "$EV" && echo proc-*)" = "proc-4242 proc-4343 proc-5000 proc-7000" ] || fail "captured: $(cd "$EV" && echo proc-*)"
}

t_executable_is_copied_hashed_and_disarmed() {
  standard_procs
  capture
  expect_rc 0
  [ "$(cat "$EV/proc-4242/exe.path")" = "$FAKE/xmrig.bin" ] || fail "exe.path"
  [ "$(mode "$EV/proc-4242/exe")" = 0 ] || fail "exe mode is $(mode "$EV/proc-4242/exe"), not 000"
  [ "$(cut -d ' ' -f 1 "$EV/proc-4242/exe.sha256")" = "$(sum "$FAKE/xmrig.bin")" ] || fail "exe.sha256"
  chmod u+r "$EV/proc-4242/exe"
  cmp -s "$EV/proc-4242/exe" "$FAKE/xmrig.bin" || fail "the copy differs from the binary"
  expect_out "pid 4242  exe $FAKE/xmrig.bin  sha256 $(sum "$FAKE/xmrig.bin")  container ${CID:0:12}"
}

t_environment_is_redacted() {
  standard_procs
  capture
  expect_rc 0
  [ "$(cat "$EV/proc-4242/environ.txt")" = "PATH=/usr/bin
DB_PASSWORD=[REDACTED]
API_TOKEN=[REDACTED]
PRIVATE_KEY=[REDACTED]
Aws_Secret_Thing=[REDACTED]
HOME=/root" ] || fail "environ.txt: $(cat "$EV/proc-4242/environ.txt")"
  [ ! -e "$EV/proc-4242/environ.raw" ] || fail "raw environment kept while redacting"
  mkdir "$FAKE/untar"
  tar -xzf "$EV.tar.gz" -C "$FAKE/untar"
  chmod -R u+r "$EV" "$FAKE/untar"
  for v in pw-fake tok-fake line1-fake line2-fake mixed-case-fake; do
    ! grep -rqF -- "$v" "$EV" "$FAKE/untar" "$FAKE/out" "$FAKE/err" || fail "secret value $v kept in: $(grep -rlF -- "$v" "$EV" "$FAKE/untar" "$FAKE/out" "$FAKE/err" | tr '\n' ' ')"
  done
}

t_no_redact_keeps_values() {
  standard_procs
  capture --no-redact
  expect_rc 0
  grep -qx 'DB_PASSWORD=pw-fake-aaaa' "$EV/proc-4242/environ.txt" || fail "value redacted with --no-redact"
  grep -qxF 'PRIVATE_KEY=line1-fake\nline2-fake' "$EV/proc-4242/environ.txt" || fail "multi-line value not escaped"
  cmp -s "$EV/proc-4242/environ.raw" "$FAKE/proc/4242/environ" || fail "environ.raw differs from the original"
}

t_container_evidence_once_and_read_only() {
  standard_procs
  FAKE_LOG_SINCE=45m capture --log-since 45m  # the fake docker fails logs without exactly this --since
  expect_rc 0
  local c=$EV/container-${CID:0:12}
  [ "$(cat "$c/container-id.txt")" = "$CID" ] || fail "container id"
  [ "$(cat "$c/diff.txt")" = "A /tmp/.x
A /tmp/.x/xmrig" ] || fail "docker diff"
  grep -q 'app started' "$c/logs.txt" || fail "docker logs: container stdout missing"
  grep -q 'app error' "$c/logs.txt" || fail "docker logs: container stderr missing"
  grep -q '^Id=' "$c/inspect.txt" || fail "docker inspect"
  [ "$(grep -c "^logs --timestamps --since 45m $CID\$" "$FAKE/docker.calls")" = 1 ] || fail "logs not fetched exactly once"
  [ "$(grep -c "^diff $CID\$" "$FAKE/docker.calls")" = 1 ] || fail "diff not run exactly once"
  ! grep -q "$CID2" "$FAKE/docker.calls" || fail "looked at a container with no matching process"
  ! grep -q 'Env' "$FAKE/inspect.format" || fail "docker inspect format includes the environment"
  ! grep -q FORBIDDEN "$FAKE/docker.calls" || fail "a non-read-only docker call: $(grep FORBIDDEN "$FAKE/docker.calls")"
}

t_manifest_and_tarball_verify() {
  standard_procs
  capture
  expect_rc 0
  [ "$(mode "$EV.tar.gz")" = 600 ] || fail "tarball mode $(mode "$EV.tar.gz")"
  [ "$(cut -d ' ' -f 1 "$EV.tar.gz.sha256")" = "$(sum "$EV.tar.gz")" ] || fail "tarball checksum"
  expect_out "sha256:   $(sum "$EV.tar.gz")"
  expect_out "tarball:  $EV.tar.gz"
  chmod -R u+r "$EV"
  python3 - "$EV" <<'PY' || fail "MANIFEST.sha256 does not verify"
import hashlib, os, sys
d = sys.argv[1]
listed = {}
for line in open(os.path.join(d, "MANIFEST.sha256")):
    digest, name = line.rstrip("\n").split("  ", 1)
    listed[os.path.normpath(name)] = digest
actual = {os.path.relpath(os.path.join(r, f), d) for r, _, fs in os.walk(d) for f in fs} - {"MANIFEST.sha256"}
ok = set(listed) == actual and all(
    hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() == h for n, h in listed.items())
sys.exit(0 if ok else 1)
PY
  grep -q 'done: captured 3 processes' "$EV/collection.log" || fail "collection.log"
}

t_max_procs() {
  standard_procs
  capture --max-procs 2
  expect_rc 0
  [ "$(cd "$EV" && echo proc-*)" = "proc-4242 proc-4343" ] || fail "expected the first 2 processes"
  expect_out "matched 3 processes; captured the first 2 (--max-procs)"
}

t_pattern_is_passed_literally() {
  standard_procs
  local pattern="x'\$(touch $FAKE/pwned)\`touch $FAKE/pwned2\`; touch $FAKE/pwned3"
  capture --pattern "$pattern"
  [ ! -e "$FAKE/pwned" ] && [ ! -e "$FAKE/pwned2" ] && [ ! -e "$FAKE/pwned3" ] || fail "the pattern was executed"
  expect_rc 0
  grep -qF "pattern=$pattern " "$EV/collection.log" || fail "pattern not recorded verbatim"
  expect_out "matched and captured 0 processes"
}

t_s3_upload() {
  standard_procs
  capture --s3-uri s3://evidence-bucket/cases/case-1/
  expect_rc 0
  local name=${EV##*/}
  cmp -s "$FAKE/s3/evidence-bucket/cases/case-1/$name.tar.gz" "$EV.tar.gz" || fail "tarball not uploaded"
  cmp -s "$FAKE/s3/evidence-bucket/cases/case-1/$name.tar.gz.sha256" "$EV.tar.gz.sha256" || fail "checksum not uploaded"
  expect_out "uploaded: s3://evidence-bucket/cases/case-1/$name.tar.gz"
  touch "$FAKE/s3_fail"
  rm -rf "$FAKE/evidence"
  capture --s3-uri s3://evidence-bucket/cases/case-1
  expect_rc 1
  expect_out "upload:   FAILED; the tarball is still at"
}

t_generated_script_is_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { echo "    (shellcheck not installed; skipped)" >&2; return 0; }
  "$TEST_BASH" "$TOOL" --print-script --pattern xmrig --s3-uri s3://evidence-bucket/x >"$FAKE/capture.sh"
  shellcheck -s bash "$FAKE/capture.sh" || fail "shellcheck findings in the host script"
}

t_host_script_never_kills() {
  "$TEST_BASH" "$TOOL" --print-script --pattern xmrig >"$FAKE/capture.sh"
  ! grep -nE '(^|[^a-z_-])(kill|pkill|killall)([^a-z_-]|$)|docker (stop|kill|rm|pause|exec|restart)|systemctl|reboot|shutdown' \
    "$FAKE/capture.sh" || fail "the host script contains a command that kills or changes processes"
}

t_real_proc_on_linux() {
  [ -r /proc/self/exe ] || { echo "    (no /proc here; skipped)" >&2; return 0; }
  IR_TEST_SECRET=never-copy-this-value sleep 3017 &
  local pid=$!
  RC=0
  "$TEST_BASH" "$TOOL" --print-script --pattern '^sleep 3017$' --evidence-root "$FAKE/evidence" >"$FAKE/capture.sh"
  PATH=$FAKEBIN:$BASE_PATH "$TEST_BASH" "$FAKE/capture.sh" >"$FAKE/out" 2>"$FAKE/err" || RC=$?
  kill -0 "$pid" 2>/dev/null || fail "the captured process is gone"
  local exe
  exe=$(readlink "/proc/$pid/exe")
  kill "$pid"
  expect_rc 0
  EV=$(evidence_dir)
  [ -d "$EV/proc-$pid" ] || fail "process $pid not captured: $(cat "$FAKE/out")"
  [ "$(cut -d ' ' -f 1 "$EV/proc-$pid/exe.sha256")" = "$(sum "$exe")" ] || fail "exe hash differs from $exe"
  grep -qx 'IR_TEST_SECRET=\[REDACTED\]' "$EV/proc-$pid/environ.txt" || fail "secret not redacted"
  ! grep -rq never-copy-this-value "$EV" 2>/dev/null || fail "secret value kept"
}

# ---------- wrapper ----------
t_wrapper_sends_the_script_through_ssm_run() {
  wrapper --pattern xmrig -i "$I1" --profile acme --region eu-west-1 --timeout 600
  expect_rc 0
  expect_out "ecs-ir-capture on host"
  python3 - "$FAKE/request.json" "$I1" <<'PY' || fail "unexpected SSM request"
import json, sys
r = json.load(open(sys.argv[1]))
c = r["Parameters"]["commands"]
ok = (r["InstanceIds"] == [sys.argv[2]] and r["Parameters"]["executionTimeout"] == ["600"]
      and r["Comment"] == "ecs-ir-capture 1.0.0" and c[0] == "#!/bin/bash"
      and "PATTERN=xmrig" in c and "REDACT=1" in c and "EVIDENCE_ROOT=/var/tmp/ir-capture" in c)
sys.exit(0 if ok else 1)
PY
  [ "$(grep -vc -- '^--profile acme --region eu-west-1 ssm ' "$FAKE/aws.calls" || true)" = 0 ] ||
    fail "an aws call without --profile/--region"
}

t_wrapper_argument_errors() {
  wrapper -i "$I1"
  expect_rc 2
  expect_err "--pattern is required"
  wrapper --pattern xmrig
  expect_rc 2
  expect_err "give target instances"
  wrapper --pattern 'a[' -i "$I1"
  expect_rc 2
  expect_err "not a valid extended regex"
  wrapper --pattern x -i "$I1" --log-since 2x
  expect_rc 2
  wrapper --pattern x -i "$I1" --s3-uri https://example.com/x
  expect_rc 2
  wrapper --pattern x -i "$I1" --evidence-root relative/dir
  expect_rc 2
  wrapper --pattern x -i "$I1" --max-procs 0
  expect_rc 2
  wrapper --pattern x -i "$I1" --bogus
  expect_rc 2
  expect_err "unknown argument '--bogus'"
  [ ! -e "$FAKE/aws.calls" ] || fail "aws ran for invalid arguments"
}

echo "ecs-ir-capture tests, tool under: $("$TEST_BASH" --version | head -n 1)"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
