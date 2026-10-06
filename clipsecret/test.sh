#!/usr/bin/env bash
# Tests for clipsecret: bash clipsecret/test.sh
# TEST_BASH=/bin/bash runs the tool under macOS's stock bash 3.2.
#
# aws and the clipboard tools are file-backed fakes placed first on the tool's PATH,
# so nothing here touches the real clipboard or AWS.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/clipsecret
TEST_BASH=$(command -v "${TEST_BASH:-bash}")
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/clipsecret-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Test values: obviously fake, distinctive, and long enough for the default --min-length.
OLD=old-value-0000-aaaa-bbbb
NEW=new-value-1111-cccc-dddd
OTHER=other-value-2222-eeee-ffff

# ---------- fakes ----------
FAKEBIN=$ROOT/fakebin    # aws, pbcopy, pbpaste
LINUXBIN=$ROOT/linuxbin  # aws plus the few system tools clipsecret needs: no clipboard at all
mkdir -p "$FAKEBIN" "$LINUXBIN" "$ROOT/xclipbin" "$ROOT/xselbin" "$ROOT/waylandbin"

cat >"$FAKEBIN/aws" <<'EOF'
#!/usr/bin/env python3
# File-backed fake of the aws CLI calls clipsecret makes. State lives in $FAKE.
import json, os, stat, sys

state = os.environ["FAKE"]
argv = sys.argv[1:]
with open(os.path.join(state, "aws.calls"), "a") as log:
    log.write(" ".join(argv) + "\n")

def opt(name):
    return argv[argv.index(name) + 1] if name in argv else None

def fail(msg, code=254):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

# every option in these calls takes a value, so the command words are the rest
words = [a for i, a in enumerate(argv) if not a.startswith("--") and not (i and argv[i - 1].startswith("--"))]
secrets = os.path.join(state, "secrets")
if words == ["configure", "get", "cli_history"]:
    path = os.path.join(state, "cli_history")
    if not os.path.exists(path):
        sys.exit(1)
    print(open(path).read().strip())
elif words == ["secretsmanager", "get-secret-value"]:
    if (opt("--query"), opt("--output")) != ("SecretString", "json"):
        fail("fake aws: unexpected get-secret-value flags", 2)
    path = os.path.join(secrets, opt("--secret-id"))
    if os.path.exists(path + ".binary"):
        print("null")
    elif not os.path.exists(path):
        fail("An error occurred (ResourceNotFoundException) when calling the GetSecretValue "
             "operation: Secrets Manager can't find the specified secret.")
    else:
        with open(path, "rb") as f:
            out = json.dumps(f.read().decode("utf-8"), ensure_ascii=False) + "\n"
        sys.stdout.buffer.write(out.encode("utf-8"))
elif words == ["secretsmanager", "put-secret-value"]:
    src = opt("--secret-string") or ""
    if (opt("--query"), opt("--output")) != ("VersionId", "text") or not src.startswith("file://"):
        fail("fake aws: unexpected put-secret-value flags", 2)
    path = src[len("file://"):]
    with open(os.path.join(state, "aws.modes"), "a") as f:
        f.write("file=%o dir=%o\n" % (stat.S_IMODE(os.stat(path).st_mode),
                                      stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode)))
    with open(path, "rb") as f:
        value = f.read()
    if os.path.exists(os.path.join(state, "put_fail")):
        text = value.decode("utf-8")  # worst case: an error message that quotes the request
        fail("An error occurred (ValidationException) when calling the PutSecretValue operation: "
             "rejected %s (as JSON: %s)" % (text, json.dumps(text)))
    with open(os.path.join(secrets, opt("--secret-id")), "wb") as f:
        f.write(value)
    with open(os.path.join(state, "aws.puts"), "a") as f:
        f.write(opt("--secret-id") + "\n")
    print("v-%d" % sum(1 for _ in open(os.path.join(state, "aws.puts"))))
else:
    fail("fake aws: unexpected call: " + " ".join(argv), 2)
EOF

cat >"$FAKEBIN/pbcopy" <<'EOF'
#!/bin/sh
echo "pbcopy LC_ALL=${LC_ALL:-}" >>"$FAKE/clip.calls"
cat >"$FAKE/clipboard.$$" && mv "$FAKE/clipboard.$$" "$FAKE/clipboard"
EOF
cat >"$FAKEBIN/pbpaste" <<'EOF'
#!/bin/sh
echo "pbpaste LC_ALL=${LC_ALL:-}" >>"$FAKE/clip.calls"
cat "$FAKE/clipboard" 2>/dev/null || true
EOF

# Like the real tools, the fake X11/Wayland writers leave a child process behind that
# keeps their stdout/stderr open (the selection owner), to catch pipe hangs.
cat >"$ROOT/xclipbin/xclip" <<'EOF'
#!/bin/sh
echo "xclip $*" >>"$FAKE/clip.calls"
case "$*" in
  "-selection clipboard -o") cat "$FAKE/clipboard" 2>/dev/null || exit 1 ;;
  "-selection clipboard -i") cat >"$FAKE/clipboard.$$" && mv "$FAKE/clipboard.$$" "$FAKE/clipboard"; sleep 8 & ;;
  *) echo "fake xclip: unexpected arguments: $*" >&2; exit 2 ;;
esac
EOF
cat >"$ROOT/xselbin/xsel" <<'EOF'
#!/bin/sh
echo "xsel $*" >>"$FAKE/clip.calls"
case "$*" in
  "--clipboard --output") cat "$FAKE/clipboard" 2>/dev/null || exit 1 ;;
  "--clipboard --input") cat >"$FAKE/clipboard.$$" && mv "$FAKE/clipboard.$$" "$FAKE/clipboard"; sleep 8 & ;;
  "--clipboard --clear") : >"$FAKE/clipboard" ;;
  *) echo "fake xsel: unexpected arguments: $*" >&2; exit 2 ;;
esac
EOF
cat >"$ROOT/waylandbin/wl-copy" <<'EOF'
#!/bin/sh
echo "wl-copy $*" >>"$FAKE/clip.calls"
case "$*" in
  "") cat >"$FAKE/clipboard.$$" && mv "$FAKE/clipboard.$$" "$FAKE/clipboard"; sleep 8 & ;;
  "--clear") : >"$FAKE/clipboard" ;;
  *) echo "fake wl-copy: unexpected arguments: $*" >&2; exit 2 ;;
esac
EOF
cat >"$ROOT/waylandbin/wl-paste" <<'EOF'
#!/bin/sh
echo "wl-paste $*" >>"$FAKE/clip.calls"
[ "$*" = "--no-newline" ] || { echo "fake wl-paste: unexpected arguments: $*" >&2; exit 2; }
if [ -s "$FAKE/clipboard" ]; then cat "$FAKE/clipboard"; else echo "Nothing is copied" >&2; exit 1; fi
EOF
chmod +x "$FAKEBIN"/* "$ROOT"/xclipbin/* "$ROOT"/xselbin/* "$ROOT"/waylandbin/*
for t in python3 mktemp rm chmod sleep cat mv; do ln -s "$(command -v "$t")" "$LINUXBIN/$t"; done
ln -s "$FAKEBIN/aws" "$LINUXBIN/aws"

# Refuse to run unless the fakes win on PATH: the tests must never reach real AWS or the real clipboard.
for t in aws pbcopy pbpaste; do
  [ "$(PATH=$FAKEBIN:$BASE_PATH command -v "$t")" = "$FAKEBIN/$t" ] || { echo "fake $t is not first on PATH" >&2; exit 1; }
done

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
put_secret() { printf '%s' "$2" >"$FAKE/secrets/$1"; }  # put_secret ID VALUE
get_secret() { cat "$FAKE/secrets/$1"; }
setclip() { printf '%s' "$1" >"$FAKE/clipboard.t" && mv "$FAKE/clipboard.t" "$FAKE/clipboard"; }  # the user copies
getclip() { cat "$FAKE/clipboard" 2>/dev/null || true; }
json_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$FAKE/secrets/$1" "$2"; }
puts() { if [ -f "$FAKE/aws.puts" ]; then wc -l <"$FAKE/aws.puts" | tr -d ' '; else echo 0; fi; }
log_output() { cat "$FAKE/out" "$FAKE/err" >>"$FAKE/all-output" 2>/dev/null || true; }

cs() {  # run clipsecret; stdout/stderr in $FAKE/out and $FAKE/err, exit status in RC
  RC=0
  PATH=$TOOL_PATH "$TEST_BASH" "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null || RC=$?
  log_output
}
cs_stdin() {  # cs_stdin VALUE ARGS...: like cs, with VALUE piped to stdin
  local value=$1
  shift
  RC=0
  printf '%s' "$value" | PATH=$TOOL_PATH "$TEST_BASH" "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" || RC=$?
  log_output
}
cs_bg() {  # start clipsecret in the background, PID in BG
  PATH=$TOOL_PATH "$TEST_BASH" "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null &
  BG=$!
}
wait_bg() {  # wait for the background run (20s max), exit status in RC
  local i=0
  while kill -0 "$BG" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 200 ]; then kill "$BG"; fail "clipsecret did not finish"; fi
    sleep 0.1
  done
  RC=0
  wait "$BG" || RC=$?
  log_output
}
wait_for() {  # wait_for TEXT [COUNT]: until stdout shows TEXT COUNT times (10s max)
  local i=0 n
  while :; do
    n=$(grep -cF -- "$1" "$FAKE/out" 2>/dev/null) || n=0
    [ "$n" -lt "${2:-1}" ] || return 0
    i=$((i + 1))
    [ $i -le 100 ] || fail "timed out waiting for: $1"
    sleep 0.1
  done
}
wait_clip_call() {  # wait_clip_call PATTERN: until a clipboard tool call matching PATTERN is logged (10s max)
  local i=0
  until grep -q -- "$1" "$FAKE/clip.calls" 2>/dev/null; do
    i=$((i + 1))
    [ $i -le 100 ] || fail "timed out waiting for a '$1' clipboard call"
    sleep 0.1
  done
}
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_out() { grep -qF -- "$1" "$FAKE/out" || fail "stdout lacks: $1"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1"; }
check_tmp_modes() {  # while clipsecret waits: its temp dir is 0700 and every file in it 0600
  local d
  d=$(ls -d "$FAKE"/tmp/clipsecret.*) || fail "no clipsecret temp dir while waiting"
  python3 - "$d" <<'PY' || fail "temp dir or file permissions are too open"
import os, stat, sys
d = sys.argv[1]
files = os.listdir(d)
ok = stat.S_IMODE(os.stat(d).st_mode) == 0o700 and files and all(
    stat.S_IMODE(os.stat(os.path.join(d, f)).st_mode) == 0o600 for f in files)
sys.exit(0 if ok else 1)
PY
}

# After every test: no secret value in anything clipsecret printed or on any aws
# command line, no temp files left, and pbcopy/pbpaste always ran under UTF-8.
after_test() {
  local v
  for v in ${SENSITIVE[@]+"${SENSITIVE[@]}"}; do
    if grep -qF -- "$v" "$FAKE/all-output" "$FAKE/aws.calls" 2>/dev/null; then
      fail "a secret value appeared in clipsecret's output or an aws command line"
    fi
  done
  [ -z "$(ls -A "$FAKE/tmp")" ] || fail "temp files left behind: $(ls -A "$FAKE/tmp")"
  if [ -f "$FAKE/clip.calls" ] && grep '^pb' "$FAKE/clip.calls" | grep -qv 'LC_ALL=en_US.UTF-8$'; then
    fail "pbcopy/pbpaste ran without a UTF-8 locale"
  fi
}

one_test() {  # runs in its own subshell: fresh fake AWS and clipboard state per test
  FAKE=$ROOT/$1
  mkdir -p "$FAKE/secrets" "$FAKE/tmp"
  touch "$FAKE/all-output"
  export FAKE TMPDIR=$FAKE/tmp AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION DISPLAY WAYLAND_DISPLAY
  TOOL_PATH=$FAKEBIN:$BASE_PATH
  SENSITIVE=()
  "$1"
  after_test
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

# ---------- copy ----------
t_copy_json_key() {
  put_secret app "{\"API_TOKEN\":\"$OLD\",\"OTHER\":\"$OTHER\"}"
  SENSITIVE=("$OLD" "$OTHER")
  setclip "previous clipboard"
  cs copy app API_TOKEN --clear-after 0
  expect_rc 0
  [ "$(getclip)" = "$OLD" ] || fail "the clipboard does not hold the key's value"
  expect_out "copied app:API_TOKEN to the clipboard (length 24)"
}

t_copy_plain_is_byte_exact() {
  # trailing newline and non-ASCII survive (the old --output text path dropped newlines)
  printf 'line-one-aaaa\nline-two-caf\303\251\n' >"$FAKE/secrets/plain"
  SENSITIVE=(line-one-aaaa line-two-caf)
  cs copy plain --clear-after 0
  expect_rc 0
  cmp -s "$FAKE/secrets/plain" "$FAKE/clipboard" || fail "the clipboard is not byte-identical to the secret"
  expect_out "copied plain to the clipboard (length 28)"
}

t_copy_missing_key() {
  put_secret app "{\"API_TOKEN\":\"$OLD\"}"
  SENSITIVE=("$OLD")
  setclip "previous clipboard"
  cs copy app NOPE
  expect_rc 1
  expect_err "key 'NOPE' not found in secret"
  [ "$(getclip)" = "previous clipboard" ] || fail "the clipboard changed"
}

t_copy_unreadable_and_binary_secrets() {
  setclip "previous clipboard"
  cs copy missing
  expect_rc 1
  expect_err "ResourceNotFoundException"
  expect_err "could not read secret 'missing'"
  touch "$FAKE/secrets/blob.binary"
  cs copy blob
  expect_rc 1
  expect_err "binary secrets are not supported"
  [ "$(getclip)" = "previous clipboard" ] || fail "the clipboard changed"
}

t_python_errors_report_type_only() {
  # a lone surrogate cannot be encoded: the helper fails, and must not quote the data
  put_secret app '{"API_TOKEN":"\ud800-lone-surrogate-value"}'
  SENSITIVE=(lone-surrogate-value)
  cs copy app API_TOKEN
  expect_rc 1
  [ "$(cat "$FAKE/err")" = "clipsecret: internal error (UnicodeEncodeError)" ] ||
    fail "unexpected stderr: $(cat "$FAKE/err")"
}

t_copy_clear_after_does_not_block() {
  put_secret app "$OLD"
  SENSITIVE=("$OLD")
  local start=$SECONDS
  # stdout is a pipe here: the background clear must not keep it open
  PATH=$TOOL_PATH "$TEST_BASH" "$TOOL" copy app --clear-after 4 2>&1 | cat >"$FAKE/out"
  log_output
  [ $((SECONDS - start)) -lt 3 ] || fail "copy waited for the background clear"
  expect_out "cleared in 4s"
  [ "$(getclip)" = "$OLD" ] || fail "the value is not on the clipboard"
  local i=0
  while [ -n "$(getclip)" ]; do
    i=$((i + 1))
    [ $i -le 100 ] || fail "the clipboard was not cleared"
    sleep 0.1
  done
}

t_copy_clear_keeps_a_newer_clipboard() {
  put_secret app "$OLD"
  SENSITIVE=("$OLD")
  cs copy app --clear-after 1
  expect_rc 0
  setclip "something copied later"
  wait_clip_call '^pbpaste'  # the background clear looked at the clipboard...
  sleep 0.5
  [ "$(getclip)" = "something copied later" ] || fail "cleared a clipboard that no longer held the secret"
}

t_dry_run() {
  put_secret app "{\"API_TOKEN\":\"$OLD\"}"
  SENSITIVE=("$OLD" "$NEW")
  setclip "before"
  cs copy app API_TOKEN --dry-run
  expect_rc 0
  expect_out "dry run: app:API_TOKEN is readable (length 24); clipboard not touched"
  [ "$(getclip)" = "before" ] || fail "copy --dry-run touched the clipboard"
  cs_bg set app API_TOKEN --dry-run --timeout 20
  wait_for "waiting up to 20s"
  setclip "$NEW"
  wait_bg
  expect_rc 0
  expect_out "dry run: would update app:API_TOKEN (length 24); nothing written"
  [ "$(puts)" = 0 ] || fail "set --dry-run wrote the secret"
  [ "$(json_get app API_TOKEN)" = "$OLD" ] || fail "the secret changed"
  [ "$(getclip)" = "$NEW" ] || fail "set --dry-run cleared the clipboard"
}

# ---------- set ----------
t_set_json_key_after_clipboard_change() {
  put_secret app "{\"API_TOKEN\":\"$OLD\",\"OTHER\":\"$OTHER\",\"PORT\":5432}"
  SENSITIVE=("$OLD" "$NEW" "$OTHER")
  setclip "unrelated text already on the clipboard"
  cs_bg set app API_TOKEN --timeout 20
  wait_for "waiting up to 20s"
  check_tmp_modes
  setclip "$NEW"
  wait_bg
  expect_rc 0
  expect_out "updated app:API_TOKEN (length 24) -> version v-1; clipboard cleared"
  [ "$(cat "$FAKE/secrets/app")" = "{\"API_TOKEN\":\"$NEW\",\"OTHER\":\"$OTHER\",\"PORT\":5432}" ] ||
    fail "unexpected secret after update: other keys, order or types changed"
  [ -z "$(getclip)" ] || fail "the clipboard was not cleared"
  [ "$(puts)" = 1 ] || fail "expected exactly one write"
  [ "$(cat "$FAKE/aws.modes")" = "file=600 dir=700" ] || fail "the value file was not 0600 in a 0700 dir"
}

t_set_plain() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD" "$NEW")
  cs_bg set plain --timeout 20
  wait_for "waiting up to 20s"
  setclip "$NEW"
  wait_bg
  expect_rc 0
  expect_out "updated plain (length 24) -> version v-1; clipboard cleared"
  [ "$(get_secret plain)" = "$NEW" ] || fail "the secret was not replaced"
}

t_set_rejects_identical() {
  put_secret app "{\"API_TOKEN\":\"$OLD\"}"
  SENSITIVE=("$OLD")
  cs_bg set app API_TOKEN --timeout 3
  wait_for "waiting up to 3s"
  setclip "$OLD"
  wait_for "is the value already stored; copy the NEW value"
  wait_bg
  expect_rc 1
  expect_err "no valid value copied within 3s; nothing changed"
  [ "$(puts)" = 0 ] || fail "the secret was written"
}

t_set_rejects_short_and_whitespace_then_accepts() {
  put_secret app "{\"API_TOKEN\":\"$OLD\"}"
  SENSITIVE=("$OLD" "$NEW")
  cs_bg set app API_TOKEN --timeout 20
  wait_for "waiting up to 20s"
  setclip "short
"
  wait_for "is shorter than 16 characters"
  sleep 2  # a few more polls of the same clipboard: it must be judged once
  [ "$(grep -c "is shorter" "$FAKE/out")" = 1 ] || fail "the same clipboard content was judged repeatedly"
  setclip "has white space in it 12345"
  wait_for "contains whitespace or invisible characters"
  setclip "$NEW"
  wait_bg
  expect_rc 0
  [ "$(json_get app API_TOKEN)" = "$NEW" ] || fail "the valid value was not stored"
  [ "$(puts)" = 1 ] || fail "expected exactly one write"
}

t_set_strips_one_trailing_newline() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD" "$NEW" "$OTHER")
  cs_bg set plain --timeout 20
  wait_for "waiting up to 20s"
  setclip "$NEW
"
  wait_bg
  expect_rc 0
  [ "$(wc -c <"$FAKE/secrets/plain" | tr -d ' ')" = 24 ] || fail "the trailing LF was stored"
  [ "$(get_secret plain)" = "$NEW" ] || fail "the secret was not replaced"
  cs_bg set plain --timeout 20
  wait_for "waiting up to 20s"
  setclip "$OTHER"$'\r\n'
  wait_bg
  expect_rc 0
  [ "$(wc -c <"$FAKE/secrets/plain" | tr -d ' ')" = 26 ] || fail "the trailing CRLF was stored"
  [ "$(get_secret plain)" = "$OTHER" ] || fail "the secret was not replaced"
}

t_set_timeout_writes_nothing() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD")
  setclip "unchanged clipboard"
  cs set plain --timeout 2
  expect_rc 1
  expect_err "no valid value copied within 2s; nothing changed"
  [ "$(puts)" = 0 ] || fail "the secret was written"
  [ "$(get_secret plain)" = "$OLD" ] || fail "the secret changed"
  [ "$(getclip)" = "unchanged clipboard" ] || fail "the clipboard changed"
}

t_set_create_key() {
  put_secret app "{\"API_TOKEN\":\"$OLD\"}"
  SENSITIVE=("$OLD" "$NEW")
  cs set app NEW_KEY --timeout 20
  expect_rc 1
  expect_err "key 'NEW_KEY' not in secret (use --create-key to add it)"
  ! grep -q waiting "$FAKE/out" || fail "a missing key must fail before waiting for the clipboard"
  cs_bg set app NEW_KEY --create-key --timeout 20
  wait_for "waiting up to 20s"
  expect_out "key 'NEW_KEY' does not exist yet; it will be added"
  setclip "$NEW"
  wait_bg
  expect_rc 0
  [ "$(json_get app NEW_KEY)" = "$NEW" ] || fail "the new key was not added"
  [ "$(json_get app API_TOKEN)" = "$OLD" ] || fail "an existing key changed"
}

t_set_key_needs_a_json_secret() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD")
  cs set plain API_TOKEN
  expect_rc 1
  expect_err "secret is not a JSON object"
  ! grep -q waiting "$FAKE/out" || fail "must fail before waiting for the clipboard"
}

t_set_stdin() {
  put_secret app "{\"API_TOKEN\":\"$OLD\"}"
  SENSITIVE=("$OLD" "$NEW")
  setclip "clipboard stays as it is"
  cs_stdin "$NEW
" set app API_TOKEN --stdin
  expect_rc 0
  expect_out "updated app:API_TOKEN (length 24) -> version v-1"
  [ "$(json_get app API_TOKEN)" = "$NEW" ] || fail "the value was not stored"
  [ "$(getclip)" = "clipboard stays as it is" ] || fail "--stdin touched the clipboard"
  cs_stdin "short" set app API_TOKEN --stdin
  expect_rc 1
  expect_err "the value on stdin is shorter than 16 characters (see --min-length); nothing changed"
  [ "$(puts)" = 1 ] || fail "an invalid value was written"
}

t_set_write_failure_is_scrubbed_and_keeps_clipboard() {
  put_secret app "{\"API_TOKEN\":\"$OLD\",\"OTHER\":\"$OTHER\"}"
  SENSITIVE=("$OLD" "$NEW" "$OTHER")
  touch "$FAKE/put_fail"
  cs_bg set app API_TOKEN --timeout 20
  wait_for "waiting up to 20s"
  setclip "$NEW"
  wait_bg
  expect_rc 1
  expect_err "ValidationException"
  expect_err "[redacted]"
  expect_err "nothing changed, and the new value is still on the clipboard"
  [ "$(getclip)" = "$NEW" ] || fail "the clipboard was cleared after a failed write"
  [ "$(json_get app API_TOKEN)" = "$OLD" ] || fail "the secret changed"
}

# ---------- environment and arguments ----------
t_refuses_when_cli_history_is_on() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD")
  echo enabled >"$FAKE/cli_history"
  cs copy plain
  expect_rc 1
  expect_err "cli_history"
  ! grep -q get-secret-value "$FAKE/aws.calls" || fail "read the secret despite cli_history"
}

t_profile_and_region_reach_aws() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD")
  # No --profile/--region: an empty array under set -u. bash 3.2 dies on that with exit status 0
  # (status lost inside a function in an || list), so check the effect, not just the status.
  cs copy plain --clear-after 0
  expect_rc 0
  expect_out "copied plain to the clipboard (length 24)"
  grep -qx -- "secretsmanager get-secret-value --secret-id plain --query SecretString --output json" "$FAKE/aws.calls" ||
    fail "the secret was not read without --profile"
  cs copy plain --profile acme --region eu-west-1 --clear-after 0
  expect_rc 0
  grep -qx -- "--profile acme --region eu-west-1 configure get cli_history" "$FAKE/aws.calls" || fail "profile not passed"
  grep -q -- "^--profile acme --region eu-west-1 secretsmanager get-secret-value" "$FAKE/aws.calls" || fail "profile not passed"
}

t_sigterm_cleans_up() {
  put_secret plain "$OLD"
  SENSITIVE=("$OLD")
  cs_bg set plain --timeout 30
  wait_for "waiting up to 30s"
  ls -d "$FAKE"/tmp/clipsecret.* >/dev/null || fail "no temp dir while waiting"
  kill -TERM "$BG"
  wait_bg
  expect_rc 143
  [ "$(puts)" = 0 ] || fail "the secret was written"
}

t_bad_arguments() {
  cs
  expect_rc 1
  expect_err "Usage:"
  cs --help
  expect_rc 0
  expect_out "Usage:"
  cs frobnicate x
  expect_rc 1
  expect_err "unknown command 'frobnicate'"
  cs set
  expect_rc 1
  expect_err "expected <secret-id> [json-key]"
  cs set a b c
  expect_rc 1
  cs set app --timeout abc
  expect_rc 1
  expect_err "option --timeout needs a whole number, got 'abc'"
  cs set app --timeout 0
  expect_rc 1
  expect_err "--timeout must be at least 1"
  cs set app --profile
  expect_rc 1
  expect_err "option --profile needs a value"
  cs copy app --stdin
  expect_rc 1
  expect_err "--stdin only applies to set"
  cs set app --bogus
  expect_rc 1
  expect_err "unknown option '--bogus'"
  [ ! -e "$FAKE/aws.calls" ] || fail "aws ran for invalid arguments"
}

# ---------- Linux clipboard backends ----------
backend_round_trip() {  # copy then set through whichever backend TOOL_PATH and DISPLAY select
  put_secret plain "$OLD"
  SENSITIVE=("$OLD" "$NEW")
  local start=$SECONDS
  PATH=$TOOL_PATH "$TEST_BASH" "$TOOL" copy plain --clear-after 0 2>&1 | cat >"$FAKE/out"
  log_output
  [ $((SECONDS - start)) -lt 4 ] || fail "copy hung on the selection owner holding its stdout"
  [ "$(getclip)" = "$OLD" ] || fail "copy did not reach the clipboard"
  cs_bg set plain --timeout 20
  wait_for "waiting up to 20s"
  setclip "$NEW"
  wait_bg
  expect_rc 0
  [ "$(get_secret plain)" = "$NEW" ] || fail "set did not store the value"
  [ -z "$(getclip)" ] || fail "the clipboard was not cleared"
}

t_backend_xclip() {
  TOOL_PATH=$ROOT/xclipbin:$LINUXBIN
  export DISPLAY=:0
  backend_round_trip
  grep -q '^xclip -selection clipboard -o' "$FAKE/clip.calls" || fail "xclip not used"
}

t_backend_xsel() {
  TOOL_PATH=$ROOT/xselbin:$LINUXBIN
  export DISPLAY=:0
  backend_round_trip
  grep -q '^xsel --clipboard --clear' "$FAKE/clip.calls" || fail "xsel not used to clear"
}

t_backend_wayland() {
  TOOL_PATH=$ROOT/waylandbin:$ROOT/xclipbin:$LINUXBIN  # Wayland wins over X11 when both are available
  export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0
  backend_round_trip
  grep -q '^wl-copy --clear' "$FAKE/clip.calls" || fail "wl-copy not used to clear"
  ! grep -q '^xclip' "$FAKE/clip.calls" || fail "xclip used under Wayland"
}

t_no_clipboard() {
  TOOL_PATH=$LINUXBIN
  put_secret plain "$OLD"
  SENSITIVE=("$OLD" "$NEW")
  cs copy plain
  expect_rc 1
  expect_err "no usable clipboard"
  cs_stdin "$NEW" set plain --stdin  # headless: no clipboard needed
  expect_rc 0
  [ "$(get_secret plain)" = "$NEW" ] || fail "--stdin did not store the value"
}

echo "clipsecret tests, tool under: $("$TEST_BASH" --version | head -n 1)"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
