#!/usr/bin/env bash
# Tests for gha-pin: bash gha-pin/test.sh [t_name...]
#
# gh is a file-backed fake placed first on PATH. It answers `gh api PATH` from a
# fixture table and logs every call, so nothing here talks to GitHub.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/gha-pin
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gha-pin-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Fixture object ids: 40 hex digits built from patterns, one per object.
C_CHECKOUT=abcdef0123abcdef0123abcdef0123abcdef0123  # actions/checkout v4, lightweight tag
C_PYTHON=bcdefa1234bcdefa1234bcdefa1234bcdefa1234    # actions/setup-python v5, lightweight tag
T_DEPLOY=defabc3456defabc3456defabc3456defabc3456    # acme/deploy-action v1, annotated tag object
C_DEPLOY=cdefab2345cdefab2345cdefab2345cdefab2345    # ...and the commit it tags
T_CODEQL1=fabcde5678fabcde5678fabcde5678fabcde5678   # github/codeql-action v3: a tag of a tag
T_CODEQL2=a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5
C_CODEQL=efabcd4567efabcd4567efabcd4567efabcd4567
C_SHARED=b2c3d4e5f6b2c3d4e5f6b2c3d4e5f6b2c3d4e5f6    # acme/shared v2 (reusable workflow)
C_MAIN=c3d4e5f6a7c3d4e5f6a7c3d4e5f6a7c3d4e5f6a7      # acme/deploy-action main, a branch
C_CACHE=d4e5f6a7b8d4e5f6a7b8d4e5f6a7b8d4e5f6a7b8     # already pinned in the fixtures
T_LOOP=e5f6a7b8c9e5f6a7b8c9e5f6a7b8c9e5f6a7b8c9      # a tag object that tags itself
O_TREE=f6a7b8c9d0f6a7b8c9d0f6a7b8c9d0f6a7b8c9d0      # a tag pointing at a tree

FAKEBIN=$ROOT/fakebin
mkdir -p "$FAKEBIN" "$ROOT/pyonly"
cat >"$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env python3
# File-backed fake of `gh api PATH`: answers from $FAKE/api.json and logs each call.
import json, os, sys

state = os.environ["FAKE"]
args = sys.argv[1:]
with open(os.path.join(state, "gh.calls"), "a") as log:
    log.write(" ".join(args) + "\n")
if len(args) != 2 or args[0] != "api":
    sys.stderr.write("fake gh: unexpected arguments: %s\n" % " ".join(args))
    sys.exit(97)
with open(os.path.join(state, "api.json")) as f:
    table = json.load(f)
if args[1] not in table:
    sys.stderr.write("fake gh: unexpected path: %s\n" % args[1])
    sys.exit(98)
entry = table[args[1]]
status = entry.get("status", 200)
if status == 200:
    print(json.dumps(entry["body"]))
    sys.exit(0)
message = {401: "Bad credentials", 404: "Not Found"}[status]
print(json.dumps({"message": message, "status": str(status)}))
sys.stderr.write("gh: %s (HTTP %d)\n" % (message, status))
sys.exit(1)
EOF
chmod +x "$FAKEBIN/gh"
ln -s "$(command -v python3)" "$ROOT/pyonly/python3"  # a PATH with python3 but no gh

# Refuse to run unless the fake wins on PATH: the tests must never reach the real gh.
[ "$(PATH=$FAKEBIN:$BASE_PATH command -v gh)" = "$FAKEBIN/gh" ] || { echo "fake gh is not first on PATH" >&2; exit 1; }

write_api() {
  cat >"$FAKE/api.json" <<EOF
{
  "repos/actions/checkout/git/ref/tags/v4": {"body": {"ref": "refs/tags/v4", "object": {"type": "commit", "sha": "$C_CHECKOUT"}}},
  "repos/actions/setup-python/git/ref/tags/v5": {"body": {"ref": "refs/tags/v5", "object": {"type": "commit", "sha": "$C_PYTHON"}}},
  "repos/acme/deploy-action/git/ref/tags/v1": {"body": {"ref": "refs/tags/v1", "object": {"type": "tag", "sha": "$T_DEPLOY"}}},
  "repos/acme/deploy-action/git/tags/$T_DEPLOY": {"body": {"sha": "$T_DEPLOY", "tag": "v1", "object": {"type": "commit", "sha": "$C_DEPLOY"}}},
  "repos/github/codeql-action/git/ref/tags/v3": {"body": {"ref": "refs/tags/v3", "object": {"type": "tag", "sha": "$T_CODEQL1"}}},
  "repos/github/codeql-action/git/tags/$T_CODEQL1": {"body": {"sha": "$T_CODEQL1", "tag": "v3", "object": {"type": "tag", "sha": "$T_CODEQL2"}}},
  "repos/github/codeql-action/git/tags/$T_CODEQL2": {"body": {"sha": "$T_CODEQL2", "tag": "v3.0", "object": {"type": "commit", "sha": "$C_CODEQL"}}},
  "repos/acme/shared/git/ref/tags/v2": {"body": {"ref": "refs/tags/v2", "object": {"type": "commit", "sha": "$C_SHARED"}}},
  "repos/acme/deploy-action/git/ref/tags/main": {"status": 404},
  "repos/acme/deploy-action/git/ref/heads/main": {"body": {"ref": "refs/heads/main", "object": {"type": "commit", "sha": "$C_MAIN"}}},
  "repos/acme/missing-action/git/ref/tags/v9": {"status": 404},
  "repos/acme/missing-action/git/ref/heads/v9": {"status": 404},
  "repos/acme/loop-action/git/ref/tags/v1": {"body": {"ref": "refs/tags/v1", "object": {"type": "tag", "sha": "$T_LOOP"}}},
  "repos/acme/loop-action/git/tags/$T_LOOP": {"body": {"sha": "$T_LOOP", "tag": "v1", "object": {"type": "tag", "sha": "$T_LOOP"}}},
  "repos/acme/tree-action/git/ref/tags/v1": {"body": {"ref": "refs/tags/v1", "object": {"type": "tree", "sha": "$O_TREE"}}},
  "repos/acme/locked-action/git/ref/tags/v1": {"status": 401}
}
EOF
}

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
run() {  # run ARGS...: gha-pin in $WORK; stdout, stderr and status in $FAKE/out, $FAKE/err, RC
  RC=0
  (cd "$WORK" && PATH=$TOOL_PATH "$TOOL" "$@") >"$FAKE/out" 2>"$FAKE/err" || RC=$?
}
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1 (stderr: $(cat "$FAKE/err"))"; }
same_bytes() {  # same_bytes EXPECTED ACTUAL
  cmp -s "$1" "$2" || { diff "$1" "$2" >&2 || true; fail "$2 differs from the expected bytes"; }
}
calls_to() { grep -cxF -- "api $1" "$FAKE/gh.calls" 2>/dev/null || true; }  # calls_to PATH: how many times
no_gh_calls() { [ ! -e "$FAKE/gh.calls" ] || fail "gh was called: $(cat "$FAKE/gh.calls")"; }
mode_of() { python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }

one_test() {  # runs in its own subshell: fresh fixture state and work directory per test
  FAKE=$ROOT/$1
  WORK=$FAKE/work
  mkdir -p "$WORK"
  export FAKE GH_CONFIG_DIR=$FAKE/gh-config
  mkdir -p "$GH_CONFIG_DIR"
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
  TOOL_PATH=$FAKEBIN:$BASE_PATH
  write_api
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
t_mixed_forms_exact_output() {
  cat >"$WORK/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python
        uses: "actions/setup-python@v5"
      - uses: 'acme/deploy-action@v1'   # deploys the preview
      - uses: ./.github/actions/local-thing
      - uses: docker://alpine:3.20
      - uses: actions/cache@d4e5f6a7b8d4e5f6a7b8d4e5f6a7b8d4e5f6a7b8 # v4
      - uses: github/codeql-action/init@v3
      - uses: actions/checkout@v4
      - run: |
          echo "uses: actions/checkout@v4"
          cat <<'EOF'
            uses: acme/deploy-action@v1
          EOF
      - name: after the block
        uses: actions/setup-python@v5
  call:
    uses: acme/shared/.github/workflows/build.yml@v2
YAML
  cat >"$FAKE/expected" <<YAML
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$C_CHECKOUT # v4
      - name: Set up Python
        uses: "actions/setup-python@$C_PYTHON" # v5
      - uses: 'acme/deploy-action@$C_DEPLOY'   # v1 deploys the preview
      - uses: ./.github/actions/local-thing
      - uses: docker://alpine:3.20
      - uses: actions/cache@$C_CACHE # v4
      - uses: github/codeql-action/init@$C_CODEQL # v3
      - uses: actions/checkout@$C_CHECKOUT # v4
      - run: |
          echo "uses: actions/checkout@v4"
          cat <<'EOF'
            uses: acme/deploy-action@v1
          EOF
      - name: after the block
        uses: actions/setup-python@$C_PYTHON # v5
  call:
    uses: acme/shared/.github/workflows/build.yml@$C_SHARED # v2
YAML
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$WORK/ci.yml"
  expect_err "gha-pin: pinned 7, already pinned 1, skipped 2 (local/docker), failed 0"
  [ ! -s "$FAKE/out" ] || fail "unexpected stdout: $(cat "$FAKE/out")"
}

t_annotated_tags_resolve_to_the_commit() {
  printf 'steps:\n  - uses: acme/deploy-action@v1\n  - uses: github/codeql-action/analyze@v3\n' >"$WORK/ci.yml"
  printf 'steps:\n  - uses: acme/deploy-action@%s # v1\n  - uses: github/codeql-action/analyze@%s # v3\n' \
    "$C_DEPLOY" "$C_CODEQL" >"$FAKE/expected"
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$WORK/ci.yml"
  ! grep -qE "$T_DEPLOY|$T_CODEQL1|$T_CODEQL2" "$WORK/ci.yml" || fail "pinned to a tag object instead of its commit"
  printf '%s\n' \
    "api repos/acme/deploy-action/git/ref/tags/v1" \
    "api repos/acme/deploy-action/git/tags/$T_DEPLOY" \
    "api repos/github/codeql-action/git/ref/tags/v3" \
    "api repos/github/codeql-action/git/tags/$T_CODEQL1" \
    "api repos/github/codeql-action/git/tags/$T_CODEQL2" >"$FAKE/expected-calls"
  same_bytes "$FAKE/expected-calls" "$FAKE/gh.calls"
}

t_duplicate_reference_is_looked_up_once() {
  printf 'steps:\n  - uses: actions/checkout@v4\n  - uses: actions/checkout@v4\n' >"$WORK/a.yml"
  printf 'steps:\n  - uses: Actions/Checkout@v4\n' >"$WORK/b.yml"
  run a.yml b.yml
  expect_rc 0
  [ "$(calls_to repos/actions/checkout/git/ref/tags/v4)" = 1 ] || fail "looked up more than once: $(cat "$FAKE/gh.calls")"
  [ "$(wc -l <"$FAKE/gh.calls" | tr -d ' ')" = 1 ] || fail "unexpected calls: $(cat "$FAKE/gh.calls")"
  [ "$(grep -c "@$C_CHECKOUT # v4" "$WORK/a.yml")" = 2 ] || fail "a.yml not pinned twice"
  grep -qxF "  - uses: Actions/Checkout@$C_CHECKOUT # v4" "$WORK/b.yml" || fail "b.yml not pinned"
  expect_err "pinned 3, already pinned 0"
}

t_crlf_is_preserved() {
  printf 'jobs:\r\n  x:\r\n    steps:\r\n      - uses: actions/checkout@v4 # first\r\n      - run: echo hi\r\n' >"$WORK/ci.yml"
  printf 'jobs:\r\n  x:\r\n    steps:\r\n      - uses: actions/checkout@%s # v4 first\r\n      - run: echo hi\r\n' \
    "$C_CHECKOUT" >"$FAKE/expected"
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$WORK/ci.yml"
}

t_missing_final_newline_is_preserved() {
  printf 'steps:\n  - uses: actions/checkout@v4' >"$WORK/ci.yml"
  printf 'steps:\n  - uses: actions/checkout@%s # v4' "$C_CHECKOUT" >"$FAKE/expected"
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$WORK/ci.yml"
}

t_file_mode_is_preserved_and_no_temp_file_left() {
  printf 'steps:\n  - uses: actions/checkout@v4\n' >"$WORK/ci.yml"
  chmod 640 "$WORK/ci.yml"
  run ci.yml
  expect_rc 0
  grep -qF "@$C_CHECKOUT # v4" "$WORK/ci.yml" || fail "not pinned"
  [ "$(mode_of "$WORK/ci.yml")" = 640 ] || fail "mode changed to $(mode_of "$WORK/ci.yml")"
  [ "$(ls -A "$WORK")" = ci.yml ] || fail "left files behind: $(ls -A "$WORK")"
}

t_dry_run_prints_a_diff_and_writes_nothing() {
  printf 'jobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n      - run: echo hi\n' >"$WORK/ci.yml"
  printf 'steps:\n  - uses: actions/setup-python@v5' >"$WORK/tail.yml"
  cp "$WORK/ci.yml" "$FAKE/ci.orig"
  cp "$WORK/tail.yml" "$FAKE/tail.orig"
  cat >"$FAKE/expected" <<EOF
--- a/ci.yml
+++ b/ci.yml
@@ -1,5 +1,5 @@
 jobs:
   build:
     steps:
-      - uses: actions/checkout@v4
+      - uses: actions/checkout@$C_CHECKOUT # v4
       - run: echo hi
--- a/tail.yml
+++ b/tail.yml
@@ -1,2 +1,2 @@
 steps:
-  - uses: actions/setup-python@v5
\\ No newline at end of file
+  - uses: actions/setup-python@$C_PYTHON # v5
\\ No newline at end of file
EOF
  run --dry-run ci.yml tail.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$FAKE/out"
  same_bytes "$FAKE/ci.orig" "$WORK/ci.yml"
  same_bytes "$FAKE/tail.orig" "$WORK/tail.yml"
  expect_err "dry run, nothing written: would have pinned 2, already pinned 0, skipped 0 (local/docker), failed 0"
}

t_unresolvable_refs_exit_1_and_the_rest_is_pinned() {
  printf 'steps:\n  - uses: acme/missing-action@v9\n  - uses: actions/checkout@v4\n  - uses: just-a-name@v1\n' >"$WORK/ci.yml"
  printf 'steps:\n  - uses: acme/missing-action@v9\n  - uses: actions/checkout@%s # v4\n  - uses: just-a-name@v1\n' \
    "$C_CHECKOUT" >"$FAKE/expected"
  run ci.yml
  expect_rc 1
  same_bytes "$FAKE/expected" "$WORK/ci.yml"
  expect_err "ci.yml:2: cannot resolve acme/missing-action@v9: no such tag or branch"
  expect_err "ci.yml:4: not a pinnable reference: just-a-name@v1"
  expect_err "pinned 1, already pinned 0, skipped 0 (local/docker), failed 2"
}

t_tag_chain_failures_are_reported() {
  printf 'steps:\n  - uses: acme/loop-action@v1\n  - uses: acme/tree-action@v1\n' >"$WORK/ci.yml"
  cp "$WORK/ci.yml" "$FAKE/orig"
  run ci.yml
  expect_rc 1
  same_bytes "$FAKE/orig" "$WORK/ci.yml"
  expect_err "ci.yml:2: cannot resolve acme/loop-action@v1: the tag chain does not end in a commit"
  expect_err "ci.yml:3: cannot resolve acme/tree-action@v1: it points to a tree, not a commit"
  [ "$(calls_to "repos/acme/loop-action/git/tags/$T_LOOP")" = 1 ] || fail "the tag loop was followed more than once"
}

t_branch_ref_pins_with_a_note() {
  printf 'steps:\n  - uses: acme/deploy-action@main\n' >"$WORK/ci.yml"
  printf 'steps:\n  - uses: acme/deploy-action@%s # main\n' "$C_MAIN" >"$FAKE/expected"
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$WORK/ci.yml"
  expect_err "ci.yml:2: note: acme/deploy-action@main is a branch, a moving ref; pinned to its current head"
}

t_default_directory_covers_yml_and_yaml() {
  mkdir -p "$WORK/.github/workflows"
  printf 'steps:\n  - uses: actions/checkout@v4\n' >"$WORK/.github/workflows/a.yml"
  printf 'steps:\n  - uses: actions/setup-python@v5\n' >"$WORK/.github/workflows/b.yaml"
  printf 'uses: actions/checkout@v4\n' >"$WORK/.github/workflows/notes.txt"
  run
  expect_rc 0
  grep -qxF "  - uses: actions/checkout@$C_CHECKOUT # v4" "$WORK/.github/workflows/a.yml" || fail "a.yml not pinned"
  grep -qxF "  - uses: actions/setup-python@$C_PYTHON # v5" "$WORK/.github/workflows/b.yaml" || fail "b.yaml not pinned"
  grep -qxF "uses: actions/checkout@v4" "$WORK/.github/workflows/notes.txt" || fail "notes.txt was changed"
  mkdir -p "$WORK/other"
  printf 'steps:\n  - uses: actions/checkout@v4\n' >"$WORK/other/c.yml"
  run --dir other
  expect_rc 0
  grep -qxF "  - uses: actions/checkout@$C_CHECKOUT # v4" "$WORK/other/c.yml" || fail "--dir not honoured"
}

t_explicit_action_file() {
  mkdir -p "$WORK/my-action"
  printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/setup-python@v5\n' >"$WORK/my-action/action.yml"
  printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/setup-python@%s # v5\n' "$C_PYTHON" >"$FAKE/expected"
  run my-action/action.yml
  expect_rc 0
  same_bytes "$FAKE/expected" "$WORK/my-action/action.yml"
}

t_argument_errors_exit_2_without_gh_calls() {
  printf 'steps:\n  - uses: actions/checkout@v4\n' >"$WORK/ci.yml"
  run --bogus
  expect_rc 2
  expect_err "unrecognized arguments: --bogus"
  run --dir . ci.yml
  expect_rc 2
  expect_err "give FILE arguments or --dir, not both"
  run nope.yml
  expect_rc 2
  expect_err "no such file: nope.yml"
  run
  expect_rc 2
  expect_err "no such directory: .github/workflows"
  printf 'steps:\n  - uses: actions/checkout@v4 # caf\351\n' >"$WORK/latin1.yml"
  run ci.yml latin1.yml
  expect_rc 2
  expect_err "latin1.yml is not UTF-8 text"
  no_gh_calls
  grep -qxF "  - uses: actions/checkout@v4" "$WORK/ci.yml" || fail "a file was written"
  run --version
  expect_rc 0
  grep -qxF "gha-pin 1.0.0" "$FAKE/out" || fail "unexpected --version output"
  run --help
  expect_rc 0
  grep -qF "usage: gha-pin" "$FAKE/out" || fail "unexpected --help output"
}

t_gh_failure_stops_before_writing() {
  # every reference is resolved before any file is written: a.yml alone would pin fine
  printf 'steps:\n  - uses: actions/checkout@v4\n' >"$WORK/a.yml"
  printf 'steps:\n  - uses: acme/locked-action@v1\n' >"$WORK/b.yml"
  cp "$WORK/a.yml" "$FAKE/a.orig"
  cp "$WORK/b.yml" "$FAKE/b.orig"
  run a.yml b.yml
  expect_rc 2
  expect_err "Bad credentials (HTTP 401)"
  expect_err "nothing was written"
  same_bytes "$FAKE/a.orig" "$WORK/a.yml"
  same_bytes "$FAKE/b.orig" "$WORK/b.yml"
}

t_gh_not_installed() {
  printf 'steps:\n  - uses: actions/checkout@v4\n' >"$WORK/ci.yml"
  TOOL_PATH=$ROOT/pyonly
  run ci.yml
  expect_rc 2
  expect_err "gh not found"
  grep -qxF "  - uses: actions/checkout@v4" "$WORK/ci.yml" || fail "the file was written"
}

t_nothing_to_pin() {
  printf 'steps:\n  - uses: ./local\n  - uses: docker://alpine:3.20\n' >"$WORK/ci.yml"
  cp "$WORK/ci.yml" "$FAKE/orig"
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/orig" "$WORK/ci.yml"
  expect_err "pinned 0, already pinned 0, skipped 2 (local/docker), failed 0"
  no_gh_calls
  mkdir -p "$WORK/.github/workflows"
  run
  expect_rc 0
  expect_err "no workflow files found; nothing to pin"
}

t_second_run_changes_nothing() {
  printf 'steps:\n  - uses: actions/checkout@v4\n  - uses: "acme/deploy-action@v1" # note\n  - uses: ./local\n' >"$WORK/ci.yml"
  run ci.yml
  expect_rc 0
  cp "$WORK/ci.yml" "$FAKE/after-first"
  rm "$FAKE/gh.calls"
  run ci.yml
  expect_rc 0
  same_bytes "$FAKE/after-first" "$WORK/ci.yml"
  no_gh_calls
  expect_err "pinned 0, already pinned 2, skipped 1 (local/docker), failed 0"
}

echo "gha-pin tests"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
