#!/usr/bin/env bash
# Tests for flowlog-fanout: bash flowlog-fanout/test.sh [t_name ...]
#
# The aws CLI is a file-backed fake placed first on PATH: nothing here calls AWS.
# The fake answers start-query from a scenario of pre-aggregated rows, applying
# Insights' range and limit semantics, so range splitting can be tested.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/flowlog-fanout
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/flowlog-fanout-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

T0=1791244800  # 2026-10-06T00:00:00Z
RANGE=(--log-group /vpc/flow-logs --start 2026-10-06T00:00:00Z --end 2026-10-06T01:00:00Z --poll 0)

# ---------- fake aws ----------
FAKEBIN=$ROOT/bin
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/aws" <<'EOF'
#!/usr/bin/env python3
# File-backed fake of the aws logs calls flowlog-fanout makes. State lives in $FAKE.
import json, os, re, sys, time

state = os.environ["FAKE"]
argv = sys.argv[1:]
with open(os.path.join(state, "aws.calls"), "a") as log:
    log.write(json.dumps(argv) + "\n")

def fail(msg):
    sys.stderr.write("fake aws: %s\n" % msg)
    sys.exit(2)

rest, i = [], 0
while i < len(argv):  # --profile/--region may appear anywhere; the rest must be exact
    if argv[i] in ("--profile", "--region") and i + 1 < len(argv):
        i += 2
    else:
        rest.append(argv[i])
        i += 1
if len(rest) < 2 or rest[0] != "logs" or len(rest[2:]) % 2:
    fail("unexpected call: %r" % argv)
op, pairs = rest[1], rest[2:]
opts = dict(zip(pairs[0::2], pairs[1::2]))
expected = {
    "start-query": {"--log-group-name", "--start-time", "--end-time", "--query-string", "--limit", "--output"},
    "get-query-results": {"--query-id", "--output"},
    "stop-query": {"--query-id", "--output"},
}
if op not in expected or set(opts) != expected[op] or len(opts) * 2 != len(pairs) or opts["--output"] != "json":
    fail("unexpected %s arguments: %r" % (op, pairs))

with open(os.path.join(state, "scenario.json")) as f:
    scenario = json.load(f)
qdir = os.path.join(state, "queries")
os.makedirs(qdir, exist_ok=True)

if op == "start-query":
    qid = "query-%d" % (len(os.listdir(qdir)) + 1)
    unit = re.search(r"bin\(([0-9]+)([smhd])\)", opts["--query-string"])
    size = int(unit.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit.group(2)]
    start, end, limit = int(opts["--start-time"]), int(opts["--end-time"]), int(opts["--limit"])
    # like Insights: every bin overlapping [start, end] (inclusive), ascending, at most limit rows
    rows = sorted((r for r in scenario.get("rows", []) if r[0] <= end and r[0] + size > start),
                  key=lambda r: (r[0], r[1]))[:limit]
    record = {"id": qid, "group": opts["--log-group-name"], "start": start, "end": end,
              "limit": limit, "query": opts["--query-string"]}
    with open(os.path.join(state, "queries.jsonl"), "a") as f:
        f.write(json.dumps(record) + "\n")
    with open(os.path.join(qdir, qid), "w") as f:
        json.dump({"polls": 0, "rows": rows, "bin": unit.group(0)}, f)
    print(json.dumps({"queryId": qid}))
elif op == "get-query-results":
    path = os.path.join(qdir, opts["--query-id"])
    if not os.path.exists(path):
        fail("unknown query id")
    with open(path) as f:
        q = json.load(f)
    statuses = scenario.get("statuses", [])
    if scenario.get("hang"):
        status = "Running"
    elif q["polls"] < len(statuses):
        status = statuses[q["polls"]]
    else:
        status = scenario.get("final", "Complete")
    q["polls"] += 1
    with open(path, "w") as f:
        json.dump(q, f)
    out = {"status": status, "results": [],
           "statistics": {"recordsMatched": 0.0, "recordsScanned": 0.0, "bytesScanned": 0.0}}
    if status == "Complete":
        out["results"] = [[
            {"field": "srcAddr", "value": r[1]},
            {"field": q["bin"], "value": time.strftime("%Y-%m-%d %H:%M:%S.000", time.gmtime(r[0]))},
            {"field": "dests", "value": str(r[2])},
            {"field": "flows", "value": str(r[3])},
        ] for r in q["rows"]]
        out["statistics"]["bytesScanned"] = 1048576.0
    print(json.dumps(out))
else:
    with open(os.path.join(state, "stops"), "a") as f:
        f.write(opts["--query-id"] + "\n")
    print(json.dumps({"success": True}))
EOF
chmod +x "$FAKEBIN/aws"

# Refuse to run unless the fake wins on PATH: the tests must never reach real AWS.
[ "$(PATH=$FAKEBIN:$BASE_PATH command -v aws)" = "$FAKEBIN/aws" ] || { echo "fake aws is not first on PATH" >&2; exit 1; }

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
run() {  # run ARGS...: the tool; output in $FAKE/out and $FAKE/err, exit status in RC
  RC=0
  PATH=$FAKEBIN:$BASE_PATH "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null || RC=$?
}
scenario() { printf '%s\n' "$1" >"$FAKE/scenario.json"; }
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_out() { grep -qF -- "$1" "$FAKE/out" || fail "stdout lacks: $1"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1"; }
expect_stdout() {  # expect_stdout TEXT: stdout is exactly TEXT
  printf '%s' "$1" >"$FAKE/expected"
  cmp -s "$FAKE/expected" "$FAKE/out" || fail "stdout differs:$(printf '\n')$(diff "$FAKE/expected" "$FAKE/out" || true)"
}
q() {  # q N FIELD: a field of the Nth start-query call
  python3 - "$FAKE/queries.jsonl" "$1" "$2" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1]).read().splitlines()[int(sys.argv[2]) - 1])[sys.argv[3]])
PY
}
ranges() {  # every start-query range as "start end" offsets from T0, one per line
  python3 - "$FAKE/queries.jsonl" "$T0" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    print(r["start"] - int(sys.argv[2]), r["end"] - int(sys.argv[2]))
PY
}
ncalls() {  # ncalls OPERATION: how many times the fake saw it
  [ -f "$FAKE/aws.calls" ] || { echo 0; return; }
  python3 - "$FAKE/aws.calls" "$1" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    try:
        n += sys.argv[2] in json.loads(line)
    except ValueError:  # a line the fake is still writing
        pass
print(n)
PY
}
fanout_scenario() {  # 12 five-minute bins from T0 for four sources, written as the scenario
  python3 - "$T0" "$@" >"$FAKE/scenario.json" <<'PY'
import json, sys
t0 = int(sys.argv[1])
sources = {
    "10.0.1.10": [4, 5, 4, 6, 5, 4, 5, 5, 4, 5, 5, 120],      # median 5, spike in the last bin
    "10.0.1.20": [30, 32, 31, 29, 30, 31, 30, 32, 31, 29, 30, 31],  # busy but steady
    "10.0.1.30": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 8],         # 8x its median, but only 8 destinations
}
rows = [[t0 + i * 300, src, d, d * 4] for src, ds in sources.items() for i, d in enumerate(ds)]
rows.append([t0 + 1800, "192.0.2.10", 50, 60])  # seen in one bin only: its own median
extra = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
print(json.dumps(dict({"rows": rows}, **extra)))
PY
}

one_test() {  # runs in its own subshell: fresh fake state per test
  FAKE=$ROOT/$1
  mkdir -p "$FAKE"
  export FAKE AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION FLOWLOG_FANOUT_NOW
  scenario '{"rows": []}'
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

# ---------- query ----------
t_query_string_default() {
  run "${RANGE[@]}"
  expect_rc 0
  [ "$(q 1 query)" = 'fields @timestamp, srcAddr, dstAddr, dstPort
| filter dstPort in [80,443]
| stats count_distinct(dstAddr) as dests, count(*) as flows by srcAddr, bin(5m)
| limit 10000' ] || fail "unexpected default query: $(q 1 query)"
  [ "$(q 1 group)" = /vpc/flow-logs ] || fail "wrong log group"
  [ "$(q 1 limit)" = 10000 ] || fail "wrong --limit"
}

t_query_string_with_filters() {
  run "${RANGE[@]}" --source-cidr 10.0.0.5/16 --action accept --ports 22,3389,22 --bin 1h --query-limit 500
  expect_rc 0
  [ "$(q 1 query)" = 'fields @timestamp, srcAddr, dstAddr, dstPort
| filter dstPort in [22,3389]
| filter action = "ACCEPT"
| filter isIpv4InSubnet(srcAddr, "10.0.0.0/16")
| stats count_distinct(dstAddr) as dests, count(*) as flows by srcAddr, bin(1h)
| limit 500' ] || fail "unexpected filtered query: $(q 1 query)"
  [ "$(q 1 limit)" = 500 ] || fail "wrong --limit"
  run "${RANGE[@]}" --action REJECT
  expect_rc 0
  case $(q 2 query) in *'| filter action = "REJECT"'*) ;; *) fail "no REJECT filter" ;; esac
}

# ---------- time range ----------
t_time_range_from_start_and_end() {
  run "${RANGE[@]}"
  [ "$(ranges)" = "0 3600" ] || fail "unexpected range: $(ranges)"
  rm -f "$FAKE/queries.jsonl"
  run --log-group g --poll 0 --start 2026-10-06 --end 2026-10-07
  run --log-group g --poll 0 --start 1791244800 --end "2026-10-06 00:30"
  run --log-group g --poll 0 --start 2026-10-06T02:00:00+02:00 --end 2026-10-06T00:10:00.750Z
  run --log-group g --poll 0 --start 2026-10-05T19:00-0500 --end 2026-10-06T00:05Z
  [ "$(ranges)" = "0 86400
0 1800
0 600
0 300" ] || fail "unexpected ranges: $(ranges)"
}

t_time_range_from_since_and_now() {
  export FLOWLOG_FANOUT_NOW=$((T0 + 3600))
  run --log-group g --poll 0 --since 1h
  run --log-group g --poll 0 --since 90m
  run --log-group g --poll 0  # no range given: the last hour
  run --log-group g --poll 0 --since 30m --end 2026-10-06T00:30:00Z
  run --log-group g --poll 0 --start 2026-10-06T00:50:00Z  # --end defaults to now
  run --log-group g --poll 0 --since 2d
  [ "$(ranges)" = "0 3600
-1800 3600
0 3600
0 1800
3000 3600
-169200 3600" ] || fail "unexpected ranges: $(ranges)"
}

# ---------- polling and failures ----------
t_polls_until_complete() {
  fanout_scenario '{"statuses": ["Scheduled", "Running", "Running"]}'
  run "${RANGE[@]}"
  expect_rc 1
  [ "$(ncalls get-query-results)" = 4 ] || fail "expected 4 polls, saw $(ncalls get-query-results)"
  expect_out "10.0.1.10"
}

t_failed_query_is_an_error() {
  fanout_scenario '{"statuses": ["Running"], "final": "Failed"}'
  run "${RANGE[@]}"
  expect_rc 2
  expect_err "query query-1 ended with status Failed"
  [ ! -s "$FAKE/out" ] || fail "printed results for a failed query"
}

t_timeout_stops_the_query() {
  scenario '{"hang": true}'
  local start=$SECONDS
  run --log-group g --since 1h --poll 0.1 --timeout 1
  expect_rc 2
  expect_err "query query-1 did not finish within 1s; stopped it"
  [ "$(cat "$FAKE/stops")" = query-1 ] || fail "stop-query was not called for query-1"
  [ $((SECONDS - start)) -lt 10 ] || fail "the timeout did not bound the wait"
}

t_ctrl_c_stops_the_query() {
  scenario '{"hang": true}'
  # a shell's background job ignores SIGINT; restore the default so python raises KeyboardInterrupt
  PATH=$FAKEBIN:$BASE_PATH python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$TOOL" --log-group g --since 1h --poll 0.1 >"$FAKE/out" 2>"$FAKE/err" </dev/null &
  local pid=$! i=0
  until [ "$(ncalls get-query-results)" -ge 2 ]; do
    i=$((i + 1))
    [ $i -le 100 ] || { kill "$pid"; fail "the query never started polling"; }
    sleep 0.1
  done
  kill -INT "$pid"
  RC=0
  wait "$pid" || RC=$?
  expect_rc 130
  expect_err "interrupted"
  [ "$(cat "$FAKE/stops")" = query-1 ] || fail "stop-query was not called for query-1"
}

# ---------- flagging and output ----------
t_spike_flagged_steady_sources_not() {
  fanout_scenario
  run "${RANGE[@]}"
  expect_rc 1
  expect_stdout "time                  source     dests  flows  median  ratio
2026-10-06T00:55:00Z  10.0.1.10    120    480       5   24.0
"
  expect_err "flowlog-fanout: 1 query, 37 rows, 4 sources, 1 flagged (factor 5, min-dests 20), 1.0 MB scanned"
}

t_nothing_flagged_exits_zero() {
  fanout_scenario
  run "${RANGE[@]}" --factor 30
  expect_rc 0
  [ ! -s "$FAKE/out" ] || fail "printed rows with nothing flagged"
  expect_err "0 flagged (factor 30, min-dests 20)"
}

t_min_dests_gate() {
  fanout_scenario
  run "${RANGE[@]}" --min-dests 5 --format tsv
  expect_rc 1
  expect_stdout "time	source	dests	flows	median	ratio
2026-10-06T00:55:00Z	10.0.1.10	120	480	5	24.0
2026-10-06T00:55:00Z	10.0.1.30	8	32	1	8.0
"
}

t_all_rows_and_json() {
  fanout_scenario
  run "${RANGE[@]}" --all --format tsv
  expect_rc 1
  [ "$(head -n 1 "$FAKE/out")" = "time	source	dests	flows	median	ratio	flagged" ] || fail "bad tsv header"
  [ "$(wc -l <"$FAKE/out" | tr -d ' ')" = 38 ] || fail "expected a header and 37 rows"
  [ "$(grep -c '	yes$' "$FAKE/out")" = 1 ] || fail "expected exactly one flagged row"
  expect_out "2026-10-06T00:30:00Z	192.0.2.10	50	60	50	1.0	no"
  # --all sorts by time, then source
  [ "$(sed -n 2p "$FAKE/out" | cut -f 1,2)" = "2026-10-06T00:00:00Z	10.0.1.10" ] || fail "rows are not in time order"
  run "${RANGE[@]}" --format json
  expect_rc 1
  python3 - "$FAKE/out" <<'PY' || fail "unexpected json output: $(cat "$FAKE/out")"
import json, sys
data = json.load(open(sys.argv[1]))
assert data == [{"time": "2026-10-06T00:55:00Z", "source": "10.0.1.10", "dests": 120, "flows": 480,
                 "median": 5, "ratio": 24.0, "flagged": True}], data
PY
}

# ---------- truncation ----------
t_truncated_range_is_split_on_bin_boundaries() {
  scenario "{\"rows\": [[$T0, \"10.0.1.10\", 3, 9], [$((T0 + 600)), \"10.0.1.10\", 4, 9],
    [$((T0 + 2400)), \"10.0.1.10\", 5, 9], [$((T0 + 3000)), \"10.0.1.10\", 6, 9]]}"
  run "${RANGE[@]}" --query-limit 3 --all --format tsv
  expect_rc 0
  [ "$(ranges)" = "0 3600
0 1800
1800 3600" ] || fail "unexpected query ranges: $(ranges)"
  [ "$(cut -f 1,3 "$FAKE/out")" = "time	dests
2026-10-06T00:00:00Z	3
2026-10-06T00:10:00Z	4
2026-10-06T00:40:00Z	5
2026-10-06T00:50:00Z	6" ] || fail "rows lost or duplicated: $(cat "$FAKE/out")"
  expect_err "3 queries, 4 rows, 1 sources"
}

t_split_point_is_aligned_to_a_bin() {
  # 45 minutes: the midpoint (+22.5m) is inside a bin, so the split goes to the boundary below it
  scenario "{\"rows\": [[$T0, \"10.0.1.10\", 3, 9], [$((T0 + 600)), \"10.0.1.10\", 4, 9],
    [$((T0 + 1800)), \"10.0.1.10\", 5, 9]]}"
  run --log-group g --poll 0 --start "$T0" --end $((T0 + 2700)) --query-limit 3 --all --format tsv
  expect_rc 0
  [ "$(ranges)" = "0 2700
0 1200
1200 2700" ] || fail "unexpected query ranges: $(ranges)"
  [ "$(wc -l <"$FAKE/out" | tr -d ' ')" = 4 ] || fail "expected a header and 3 rows: $(cat "$FAKE/out")"
}

t_boundary_bin_comes_from_the_later_chunk() {
  # the bin starting at the split point is in both chunks' ranges; it must appear once
  scenario "{\"rows\": [[$T0, \"10.0.1.10\", 3, 9], [$((T0 + 1800)), \"10.0.1.10\", 4, 9],
    [$((T0 + 1800)), \"10.0.1.20\", 7, 9], [$((T0 + 2400)), \"10.0.1.10\", 5, 9]]}"
  run "${RANGE[@]}" --query-limit 4 --all --format tsv
  expect_rc 0
  [ "$(ranges)" = "0 3600
0 1800
1800 3600" ] || fail "unexpected query ranges: $(ranges)"
  [ "$(cut -f 1-3 "$FAKE/out")" = "time	source	dests
2026-10-06T00:00:00Z	10.0.1.10	3
2026-10-06T00:30:00Z	10.0.1.10	4
2026-10-06T00:30:00Z	10.0.1.20	7
2026-10-06T00:40:00Z	10.0.1.10	5" ] || fail "rows lost or duplicated: $(cat "$FAKE/out")"
}

t_single_bin_cannot_split() {
  scenario "{\"rows\": [[$T0, \"10.0.1.10\", 3, 9], [$T0, \"10.0.1.20\", 4, 9]]}"
  run --log-group g --poll 0 --start "$T0" --end $((T0 + 299)) --query-limit 1 --all
  expect_rc 0
  expect_err "results may be incomplete"
  [ "$(ncalls start-query)" = 1 ] || fail "tried to split a single bin"
}

# ---------- arguments ----------
t_bad_arguments() {
  local args
  for args in "--bin 5x" "--bin 0m" "--ports 70000" "--ports 80,,443" "--ports ²" \
    "--source-cidr 2001:db8::/32" "--source-cidr 10.0.0.0/33" "--since 0h" "--since 6w" \
    "--start 2026-13-01" "--start yesterday" "--start 2026-10-06T01:00Z --end 2026-10-06T00:00Z" \
    "--since 1h --start 2026-10-06" "--query-limit 0" "--query-limit 10001" "--factor 0" \
    "--min-dests -1" "--timeout 0" "--poll -1" "--action BLOCK" "--format csv"; do
    # shellcheck disable=SC2086  # each case is a word list on purpose
    run --log-group g $args
    [ "$RC" = 2 ] || fail "'$args': expected exit 2, got $RC"
    grep -q "error:" "$FAKE/err" || fail "'$args': no error message"
  done
  run --since 1h
  expect_rc 2
  expect_err "the following arguments are required: --log-group"
  [ "$(ncalls start-query)" = 0 ] || fail "aws was called for invalid arguments"
  [ ! -e "$FAKE/aws.calls" ] || fail "aws was called for invalid arguments"
}

t_profile_and_region_on_every_call() {
  scenario '{"hang": true}'
  run --log-group g --since 1h --poll 0 --timeout 0.2 --profile acme --region eu-west-1
  expect_rc 2
  python3 - "$FAKE/aws.calls" <<'PY' || fail "a call lacked --profile/--region"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
ops = {c[c.index("logs") + 1] for c in calls}
assert ops == {"start-query", "get-query-results", "stop-query"}, ops
for c in calls:
    assert c[:4] == ["--profile", "acme", "--region", "eu-west-1"], c
PY
}

t_help_and_version() {
  run --version
  expect_rc 0
  expect_out "flowlog-fanout 1.0.0"
  run --help
  expect_rc 0
  expect_out "Exit status: 0 nothing flagged, 1 something flagged, 2 usage or runtime error."
}

echo "flowlog-fanout tests"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
