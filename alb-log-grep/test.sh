#!/usr/bin/env bash
# Tests for alb-log-grep: bash alb-log-grep/test.sh [t_name ...]
#
# The aws CLI is a strict, file-backed fake placed first on PATH. It serves a fake
# bucket of gzipped ALB logs that this script generates, so nothing here touches AWS.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$HERE/alb-log-grep
BASE_PATH=$PATH
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/alb-log-grep-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

TRACE=Root=1-66fb1e00-abcdefabcdef0123456789ab
LONG=triage/$(printf '%0120d' 0 | tr 0 x)/$(printf '%0120d' 0 | tr 0 y)  # keys past 255 bytes
US=(--account-id 123456 --log-region us-east-1)
IDS=(--fields received_bytes --no-header)  # fixture entries carry their id in received_bytes
K1205=AWSLogs/123456/elasticloadbalancing/us-east-1/2026/10/01/123456_elasticloadbalancing_us-east-1_app.my-alb.50dc6c495c0c9188_20261001T1205Z_192.0.2.1_abcdefgh.log.gz
K2010=AWSLogs/123456/elasticloadbalancing/us-east-1/2026/10/01/123456_elasticloadbalancing_us-east-1_app.my-alb.50dc6c495c0c9188_20261001T2010Z_192.0.2.1_bcdefghi.log.gz

# ---------- fake aws ----------
FAKEBIN=$ROOT/fakebin
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/aws" <<'EOF'
#!/usr/bin/env python3
# Strict, file-backed fake of the two aws CLI calls alb-log-grep makes. State lives in $FAKE.
import json, os, sys, time

state = os.environ["FAKE"]
argv = sys.argv[1:]
with open(os.path.join(state, "aws.calls"), "a") as log:
    log.write(json.dumps(argv) + "\n")

def fail(msg, code=2):
    sys.stderr.write(msg + "\n")
    sys.exit(code)

args = argv
for opt in ("--profile", "--region"):
    if args[:1] == [opt]:
        if len(args) < 2:
            fail("fake aws: %s needs a value" % opt)
        args = args[2:]
index = json.load(open(os.path.join(state, "bucket", "index.json")))

if args[:2] == ["s3api", "list-objects-v2"]:
    rest = args[2:]
    delimiter = len(rest) == 8 and rest[4:6] == ["--delimiter", "/"]
    if (len(rest) != (8 if delimiter else 6) or rest[0] != "--bucket" or rest[2] != "--prefix"
            or rest[-2:] != ["--output", "json"]):
        fail("fake aws: unexpected list-objects-v2 arguments: " + " ".join(rest))
    bucket, prefix = rest[1], rest[3]
    if bucket not in index:
        fail("An error occurred (NoSuchBucket) when calling the ListObjectsV2 operation: "
             "The specified bucket does not exist", 254)
    contents, prefixes = [], []
    for key in sorted(k for k in index[bucket] if k.startswith(prefix)):
        tail = key[len(prefix):]
        if delimiter and "/" in tail:
            common = prefix + tail.split("/", 1)[0] + "/"
            if common not in prefixes:
                prefixes.append(common)
        else:
            contents.append({"Key": key, "Size": os.path.getsize(index[bucket][key]["file"])})
    if not contents and not prefixes and os.path.exists(os.path.join(state, "empty_listing_prints_nothing")):
        sys.exit(0)
    out = {"RequestCharged": None, "Prefix": prefix}
    if contents:
        out["Contents"] = contents
    if prefixes:
        out["CommonPrefixes"] = [{"Prefix": p} for p in prefixes]
    print(json.dumps(out, indent=4))
elif args[:2] == ["s3", "cp"]:
    rest = args[2:]
    if len(rest) != 3 or not rest[0].startswith("s3://") or rest[1:] != ["-", "--only-show-errors"]:
        fail("fake aws: unexpected s3 cp arguments: " + " ".join(rest))
    bucket, _, key = rest[0][len("s3://"):].partition("/")
    obj = index.get(bucket, {}).get(key)
    if obj is None:
        fail('fatal error: An error occurred (404) when calling the HeadObject operation: Key "%s" does not exist' % key, 1)
    if obj.get("deny"):
        fail("download failed: %s to - An error occurred (AccessDenied) when calling the GetObject "
             "operation: Access Denied" % rest[0], 1)
    if os.environ.get("FAKE_SLOW_KEY") and os.environ["FAKE_SLOW_KEY"] in key:
        time.sleep(0.6)
    with open(obj["file"], "rb") as f:
        sys.stdout.buffer.write(f.read())
else:
    fail("fake aws: unexpected call: " + " ".join(argv))
EOF
chmod +x "$FAKEBIN/aws"
[ "$(PATH=$FAKEBIN:$BASE_PATH command -v aws)" = "$FAKEBIN/aws" ] || { echo "fake aws is not first on PATH" >&2; exit 1; }

# ---------- fixture bucket ----------
python3 - "$ROOT/bucket" "$LONG/" <<'PY'
import gzip, io, json, os, sys

root, long_base = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(root, "objects"))
objects = {}
TRACE = "Root=1-66fb1e00-abcdefabcdef0123456789ab"

def put(key, data, **meta):
    path = os.path.join(root, "objects", "%d.bin" % len(objects))
    with open(path, "wb") as f:
        f.write(data)
    objects[key] = dict(meta, file=path)

def gz(lines):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g:
        g.write("".join(line + "\n" for line in lines).encode("utf-8"))
    return buf.getvalue()

def key(day, end, lb="my-alb", lbid="50dc6c495c0c9188", region="us-east-1", base="", rand="abcdefgh"):
    return ("%sAWSLogs/123456/elasticloadbalancing/%s/%s/123456_elasticloadbalancing_%s_app.%s.%s_%s_192.0.2.1_%s.log.gz"
            % (base, region, day, region, lb, lbid, end, rand))

def entry(eid, time, client, request, ua="curl/8.4.0", status="200", tstatus="200", target="10.0.1.15:8080",
          times=("0.001", "0.012", "0.000"), lb="my-alb", lbid="50dc6c495c0c9188", fmt="current"):
    # ua and request are written as they appear in the log, escapes included
    q = lambda s: '"%s"' % s
    tokens = ["https", time, "app/%s/%s" % (lb, lbid), client, target] + list(times) + [
        status, tstatus, str(eid), "310", q(request), q(ua), "ECDHE-RSA-AES128-GCM-SHA256", "TLSv1.2", "-",
        q(TRACE), q("www.example.com"), q("-"), "0", time, q("forward"), q("-"), q("-"), q(target),
        q(tstatus), q("-"), q("-"), "TID_1234abcd5678ef90"]
    if fmt == "old":  # an early format: nothing after trace_id
        tokens = tokens[:18]
    elif fmt == "new":  # a later format with fields this tool does not know yet
        tokens += [q("-"), q("-"), q("-")]
    return " ".join(tokens)

URL = "https://www.example.com:443"
put(key("2026/10/01", "20261001T1205Z"), gz([
    entry(101, "2026-10-01T12:01:00.100000Z", "192.0.2.10:51000", "GET %s/api/orders?id=42&debug=true HTTP/1.1" % URL),
    entry(102, "2026-10-01T12:02:30.250000Z", "198.51.100.7:40000", "POST %s/api/login HTTP/1.1" % URL,
          ua='Mozilla/5.0 (X11; Linux x86_64) \\"quoted\\" agent\ttab C:\\\\dir', status="502", tstatus="-",
          times=("0.000", "-1", "-1")),
    entry(103, "2026-10-01T12:03:00.000000Z", "2001:db8::5:52000", "GET %s/health HTTP/1.1" % URL),
]))
put(key("2026/10/01", "20261001T2010Z", rand="bcdefghi"), gz([
    entry(104, "2026-10-01T20:06:10.000000Z", "203.0.113.5:61000", "GET %s/admin/login.php HTTP/1.1" % URL,
          ua="sqlmap/1.7.2#stable (https://sqlmap.org)", status="404", tstatus="404"),
    entry(105, "2026-10-01T20:07:00.000000Z", "203.0.113.5:61001", "- - - ", ua="-", status="400", tstatus="-",
          target="-", times=("-1", "-1", "-1")),
]))
put(key("2026/10/01", "20261001T1205Z", lb="my-alb-2", lbid="aaaabbbbccccdddd"), gz([
    entry(201, "2026-10-01T12:00:30.000000Z", "192.0.2.10:51001", "GET https://other.example.com:443/api/orders HTTP/1.1",
          status="503", tstatus="503", lb="my-alb-2", lbid="aaaabbbbccccdddd"),
]))
put(key("2026/10/02", "20261002T0905Z"), gz([
    entry(106, "2026-10-02T09:01:00.000000Z", "192.0.2.10:51002", "DELETE %s/api/orders/42 HTTP/1.1" % URL,
          status="204", tstatus="204", fmt="old"),
    entry(107, "2026-10-02T09:02:00.000000Z", "198.51.100.7:40001", "GET %s/api/orders?id=7 HTTP/1.1" % URL,
          status="500", tstatus="500", fmt="new"),
]))
put(key("2026/10/03", "20261003T0005Z"), gz([  # the late file: the last minutes of 10-02 live here
    entry(108, "2026-10-02T23:58:00.000000Z", "192.0.2.10:51003", "GET %s/api/orders HTTP/1.1" % URL),
    entry(109, "2026-10-03T00:01:00.000000Z", "192.0.2.10:51004", "GET %s/api/orders HTTP/1.1" % URL),
]))
put(key("2026/10/03", "20261003T1205Z"), gz([
    entry(110, "2026-10-03T12:01:00.000000Z", "192.0.2.10:51005", "GET %s/api/orders HTTP/1.1" % URL),
]))
put(key("2026/10/01", "20261001T1505Z", region="eu-west-1", lbid="eeeeffff00001111"), gz([
    entry(301, "2026-10-01T15:01:00.000000Z", "192.0.2.20:52000", "GET https://eu.example.com:443/api/orders HTTP/1.1",
          lbid="eeeeffff00001111"),
]))
put("AWSLogs/123456/ELBAccessLogTestFile", b"Enable AccessLog for ELB: my-alb at 2026-09-30T10:00:00.000Z")
put("AWSLogs/654321/CloudTrail/us-east-1/2026/10/01/trail.json.gz", gz(["{}"]))

# broken/: a malformed line, a non-gzip object, a denied download, a truncated gzip, then a good file
put(key("2026/10/01", "20261001T0105Z", base="broken/"), gz([
    entry(401, "2026-10-01T01:01:00.000000Z", "192.0.2.30:50000", "GET %s/ HTTP/1.1" % URL),
    "this is not an alb log line",
]))
put(key("2026/10/01", "20261001T0110Z", base="broken/", rand="corrupt0"), b"this is not gzip data at all\n")
put(key("2026/10/01", "20261001T0115Z", base="broken/", rand="denied00"),
    gz([entry(499, "2026-10-01T01:11:00.000000Z", "192.0.2.30:50001", "GET %s/ HTTP/1.1" % URL)]), deny=True)
whole = gz([entry(450, "2026-10-01T01:16:%02d.000000Z" % (i % 60), "192.0.2.30:5%04d" % i, "GET %s/x%d HTTP/1.1" % (URL, i),
                  status="404", tstatus="404") for i in range(400)])
put(key("2026/10/01", "20261001T0120Z", base="broken/", rand="truncate"), whole[:len(whole) * 2 // 3])
put(key("2026/10/01", "20261001T0125Z", base="broken/", rand="lastgood"), gz([
    entry(402, "2026-10-01T01:21:00.000000Z", "192.0.2.30:50002", "GET %s/ HTTP/1.1" % URL),
]))

# one problem each: a non-gzip object next to a good file, and a malformed line in a good file
put(key("2026/10/01", "20261001T0205Z", base="corrupt-only/"), gz([
    entry(601, "2026-10-01T02:01:00.000000Z", "192.0.2.50:50000", "GET %s/ HTTP/1.1" % URL),
]))
put(key("2026/10/01", "20261001T0210Z", base="corrupt-only/", rand="corrupt1"), b"\x1f\x8b but not really gzip")
put(key("2026/10/01", "20261001T0305Z", base="malformed-only/"), gz([
    entry(701, "2026-10-01T03:01:00.000000Z", "192.0.2.60:50000", "GET %s/ HTTP/1.1" % URL),
    "2026-10-01T03:02:00.000000Z too few fields",
]))

put(key("2026/10/01", "20261001T1205Z", base=long_base), gz([
    entry(501, "2026-10-01T12:01:00.000000Z", "192.0.2.40:50000", "GET %s/ HTTP/1.1" % URL),
]))

with open(os.path.join(root, "index.json"), "w") as f:
    json.dump({"my-alb-logs": objects}, f)
PY

# ---------- helpers ----------
fail() { echo "    $*" >&2; exit 1; }
run() {  # run ARGS...: alb-log-grep with the fake aws; output in $FAKE/out and $FAKE/err, status in RC
  RC=0
  PATH=$FAKEBIN:$BASE_PATH "$TOOL" "$@" >"$FAKE/out" 2>"$FAKE/err" </dev/null || RC=$?
}
search() { run --bucket my-alb-logs --lb my-alb "$@"; }
calls() {  # every aws call of this test, one per line, arguments joined by spaces
  [ -f "$FAKE/aws.calls" ] || return 0
  python3 -c 'import json, sys
for line in open(sys.argv[1]):
    print(" ".join(json.loads(line)))' "$FAKE/aws.calls"
}
got_ids() { tr '\n' ' ' <"$FAKE/out" | sed 's/ $//'; }
expect_rc() { [ "$RC" = "$1" ] || fail "expected exit $1, got $RC; stderr: $(cat "$FAKE/err")"; }
expect_ids() { [ "$(got_ids)" = "$1" ] || fail "expected entries [$1], got [$(got_ids)]; stderr: $(cat "$FAKE/err")"; }
expect_err() { grep -qF -- "$1" "$FAKE/err" || fail "stderr lacks: $1; stderr: $(cat "$FAKE/err")"; }
expect_out_file() {  # expect_out_file FILE: stdout must equal FILE byte for byte
  cmp -s "$1" "$FAKE/out" || fail "unexpected stdout: $(cat "$FAKE/out")"
}
expect_search() {  # expect_search "IDS" ARGS...: us-east-1, 2026-10-01 through 2026-10-02
  local want=$1
  shift
  search "${US[@]}" --start 2026-10-01 --end 2026-10-02 "${IDS[@]}" "$@"
  [ "$(got_ids)" = "$want" ] || fail "$*: expected [$want], got [$(got_ids)]; stderr: $(cat "$FAKE/err")"
  if [ -n "$want" ]; then expect_rc 0; else expect_rc 1; fi
}

one_test() {  # runs in its own subshell: fresh call log per test
  FAKE=$ROOT/$1
  mkdir -p "$FAKE"
  ln -s "$ROOT/bucket" "$FAKE/bucket"
  export FAKE AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION FAKE_SLOW_KEY
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
t_date_range_reads_the_late_file_and_skips_the_rest() {
  search "${US[@]}" --start 2026-10-01 --end 2026-10-02 "${IDS[@]}"
  expect_rc 0
  expect_ids "101 102 103 104 105 106 107 108"  # 108 sits in the 10-03 00:05 file; 109 is past --end
  local d
  for d in 2026/09/30 2026/10/01 2026/10/02 2026/10/03; do
    calls | grep -qxF "s3api list-objects-v2 --bucket my-alb-logs --prefix AWSLogs/123456/elasticloadbalancing/us-east-1/$d/123456_elasticloadbalancing_us-east-1_app.my-alb. --output json" ||
      fail "day $d was not listed"
  done
  [ "$(calls | grep -c '^s3api ')" = 4 ] || fail "unexpected listings: $(calls | grep '^s3api ')"
  [ "$(calls | grep -c '^s3 cp ')" = 4 ] || fail "expected 4 downloads, got: $(calls | grep '^s3 cp ')"
  ! calls | grep -q '^s3 cp .*20261003T1205Z' || fail "downloaded a file outside the range"
  ! calls | grep -q '^s3 cp .*my-alb-2' || fail "downloaded another load balancer's file"
  expect_err "searched 4 file(s), 9 entries, 8 matched"
}

t_lb_name_is_exact() {
  search "${US[@]}" --start 2026-10-01 "${IDS[@]}"
  expect_ids "101 102 103 104 105"
  run --bucket my-alb-logs --lb my-alb-2 "${US[@]}" --start 2026-10-01 "${IDS[@]}"
  expect_rc 0
  expect_ids "201"
}

t_discovers_accounts_and_regions() {
  search --start 2026-10-01 "${IDS[@]}"
  expect_rc 0
  expect_ids "101 102 103 301 104 105"  # files in time order across regions
  calls | grep -qxF "s3api list-objects-v2 --bucket my-alb-logs --prefix AWSLogs/ --delimiter / --output json" ||
    fail "accounts were not discovered"
  calls | grep -qxF "s3api list-objects-v2 --bucket my-alb-logs --prefix AWSLogs/123456/elasticloadbalancing/ --delimiter / --output json" ||
    fail "regions were not discovered"
  calls | grep -qxF "s3api list-objects-v2 --bucket my-alb-logs --prefix AWSLogs/654321/elasticloadbalancing/ --delimiter / --output json" ||
    fail "the second account was not checked"
}

t_time_range_filters_entries() {
  search "${US[@]}" --start 2026-10-01T12:02:00Z --end 2026-10-01T20:06:30Z "${IDS[@]}"
  expect_rc 0
  expect_ids "102 103 104"
  ! calls | grep -q '2026/10/02' || fail "listed a day outside the range"
}

t_each_filter() {
  expect_search "101 106 107 108" --path '^/api/orders'
  expect_search "" --path 'debug'  # the path excludes the query string
  expect_search "101" --url 'debug=true'
  expect_search "102 107" --client 198.51.100.0/24
  expect_search "103" --client 2001:db8::/32
  expect_search "103" --client 2001:db8::5
  expect_search "101 106 108" --client 192.0.2.10
  expect_search "102 107" --status 5xx
  expect_search "104 105" --status 404,400
  expect_search "101 103 106 108" --target-status 2xx
  expect_search "102" --method post
  expect_search "101 103 104 106 107 108" --method GET,DELETE
}

t_filters_combine() {
  expect_search "101 108" --method GET --status 2xx --path '^/api/'
  expect_search "107" --client 198.51.100.7 --status 5xx --method GET
  expect_search "" --client 198.51.100.7 --status 4xx
}

t_tsv_output_is_exact() {
  search "${US[@]}" --start 2026-10-01 --method POST
  expect_rc 0
  {
    printf '%s\t' time client elb_status target_status method url request_time target_time response_time \
      received_bytes sent_bytes user_agent
    printf '%s\n' trace_id
    printf '%s\t' 2026-10-01T12:02:30.250000Z 198.51.100.7:40000 502 - POST https://www.example.com:443/api/login \
      0.000 -1 -1 102 310 'Mozilla/5.0 (X11; Linux x86_64) "quoted" agent\ttab C:\\dir'
    printf '%s\n' "$TRACE"
  } >"$FAKE/want"
  expect_out_file "$FAKE/want"
}

t_fields_and_request_forms() {
  search "${US[@]}" --start 2026-10-01T12:02:00Z --end 2026-10-01T20:08:00Z \
    --fields time,client_ip,client_port,method,path,protocol,elb_status,target_status,key
  expect_rc 0
  {
    printf 'time\tclient_ip\tclient_port\tmethod\tpath\tprotocol\telb_status\ttarget_status\tkey\n'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      2026-10-01T12:02:30.250000Z 198.51.100.7 40000 POST /api/login HTTP/1.1 502 - "$K1205" \
      2026-10-01T12:03:00.000000Z 2001:db8::5 52000 GET /health HTTP/1.1 200 200 "$K1205" \
      2026-10-01T20:06:10.000000Z 203.0.113.5 61000 GET /admin/login.php HTTP/1.1 404 404 "$K2010" \
      2026-10-01T20:07:00.000000Z 203.0.113.5 61001 - - - 400 - "$K2010"
  } >"$FAKE/want"
  expect_out_file "$FAKE/want"
}

t_old_and_new_log_formats() {
  search "${US[@]}" --start 2026-10-02 --fields received_bytes,conn_trace_id,domain_name,user_agent --no-header
  expect_rc 0
  {
    printf '106\t-\t-\tcurl/8.4.0\n'  # early format: no fields after trace_id
    printf '107\tTID_1234abcd5678ef90\twww.example.com\tcurl/8.4.0\n'  # extra trailing fields ignored
    printf '108\tTID_1234abcd5678ef90\twww.example.com\tcurl/8.4.0\n'
  } >"$FAKE/want"
  expect_out_file "$FAKE/want"
}

t_header_once_or_never() {
  search "${US[@]}" --start 2026-10-01 --end 2026-10-02 --fields received_bytes
  expect_rc 0
  [ "$(head -n 1 "$FAKE/out")" = received_bytes ] || fail "the header is not the first line"
  [ "$(grep -c '^received_bytes$' "$FAKE/out")" = 1 ] || fail "the header repeats"
  [ "$(wc -l <"$FAKE/out" | tr -d ' ')" = 9 ] || fail "expected a header and 8 entries"
  search "${US[@]}" --start 2026-10-01 --end 2026-10-02 "${IDS[@]}"
  ! grep -q received_bytes "$FAKE/out" || fail "--no-header printed a header"
}

t_order_is_stable_in_parallel() {
  export FAKE_SLOW_KEY=20261001T1205Z  # the first file finishes last
  search "${US[@]}" --start 2026-10-01 --end 2026-10-02 "${IDS[@]}" --jobs 4
  expect_rc 0
  expect_ids "101 102 103 104 105 106 107 108"
  search "${US[@]}" --start 2026-10-01 --end 2026-10-02 "${IDS[@]}" --jobs 1
  expect_ids "101 102 103 104 105 106 107 108"
}

t_broken_objects_exit_2_and_the_rest_still_prints() {
  run --bucket my-alb-logs --prefix broken --lb my-alb "${US[@]}" --start 2026-10-01 --status 200 "${IDS[@]}"
  expect_rc 2
  expect_ids "401 402"
  expect_err "_corrupt0.log.gz: not a readable gzip stream"
  expect_err "_denied00.log.gz: download failed:"
  expect_err "AccessDenied"
  expect_err "_truncate.log.gz: not a readable gzip stream"
  expect_err "_abcdefgh.log.gz: skipped 1 malformed line(s)"
  expect_err "searched 5 file(s)"
}

t_a_corrupt_object_alone_exits_2() {
  run --bucket my-alb-logs --prefix corrupt-only --lb my-alb "${US[@]}" --start 2026-10-01 "${IDS[@]}"
  expect_rc 2
  expect_ids "601"
  expect_err "_corrupt1.log.gz: not a readable gzip stream"
  ! grep -q malformed "$FAKE/err" || fail "unexpected malformed-line report"
}

t_a_malformed_line_alone_exits_2() {
  run --bucket my-alb-logs --prefix malformed-only --lb my-alb "${US[@]}" --start 2026-10-01 "${IDS[@]}"
  expect_rc 2
  expect_ids "701"
  expect_err "skipped 1 malformed line(s)"
  expect_err "searched 1 file(s), 1 entries, 1 matched"
}

t_no_matches_exit_1() {
  search "${US[@]}" --start 2026-10-01 --path '^/nothing$'
  expect_rc 1
  [ ! -s "$FAKE/out" ] || fail "stdout is not empty"
  expect_err "searched 2 file(s), 5 entries, 0 matched"
}

t_no_files_in_range_exit_1() {
  touch "$FAKE/empty_listing_prints_nothing"  # the CLI may print nothing for an empty listing
  search "${US[@]}" --start 2026-11-01
  expect_rc 1
  expect_err "no log files for my-alb in s3://my-alb-logs/AWSLogs/"
  ! calls | grep -q '^s3 cp ' || fail "downloaded something"
}

t_wrong_prefix_is_an_error() {
  run --bucket my-alb-logs --prefix lb-logs --lb my-alb --start 2026-10-01
  expect_rc 2
  expect_err "no AWSLogs/<account-id>/ folders under s3://my-alb-logs/lb-logs/"
}

t_argument_errors_make_no_aws_calls() {
  bad() { run "$@"; expect_rc 2; }
  local b=(--bucket my-alb-logs --lb my-alb --start 2026-10-01)
  bad
  bad --bucket my-alb-logs --lb my-alb
  bad --bucket my-alb-logs --start 2026-10-01
  bad --bucket my-alb-logs --lb my-alb --start 2026-13-01
  expect_err "--start: expected YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z (UTC), got '2026-13-01'"
  bad "${b[@]}" --end 2026-09-30
  expect_err "--end must be after --start"
  bad "${b[@]}" --status 6xx
  expect_err "--status: expected codes like 502 or classes like 5xx, got '6xx'"
  bad "${b[@]}" --status abc
  bad "${b[@]}" --target-status 20
  bad "${b[@]}" --client 999.1.1.1
  expect_err "--client: expected an IP address or CIDR, got '999.1.1.1'"
  bad "${b[@]}" --path '('
  expect_err "--path: bad regex"
  bad "${b[@]}" --method 'GET;rm'
  bad "${b[@]}" --fields time,nope
  expect_err "--fields: unknown nope"
  bad "${b[@]}" --jobs 0
  bad --bucket my-alb-logs --lb my.alb --start 2026-10-01
  bad --bucket s3://my-alb-logs --lb my-alb --start 2026-10-01
  bad "${b[@]}" --prof acme  # no abbreviated options
  [ ! -e "$FAKE/aws.calls" ] || fail "aws ran for invalid arguments: $(calls)"
}

t_profile_and_region_on_every_call() {
  search --start 2026-10-01 --profile acme --region us-west-2 "${IDS[@]}"
  expect_rc 0
  expect_ids "101 102 103 301 104 105"
  python3 - "$FAKE/aws.calls" <<'PY' || fail "a call lacked --profile acme --region us-west-2"
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
sys.exit(0 if len(calls) > 3 and all(c[:4] == ["--profile", "acme", "--region", "us-west-2"] for c in calls) else 1)
PY
  [ "$(calls | grep -c ' s3 cp ')" = 3 ] || fail "expected 3 downloads"
}

t_long_keys() {
  run --bucket my-alb-logs --prefix "$LONG" --lb my-alb "${US[@]}" --start 2026-10-01 --fields received_bytes,key --no-header
  expect_rc 0
  [ "$(cut -f 1 "$FAKE/out")" = 501 ] || fail "the entry under the long prefix was not found"
  [ "$(cut -f 2 "$FAKE/out" | tr -d '\n' | wc -c | tr -d ' ')" -gt 255 ] || fail "the key is not longer than 255 bytes"
}

t_missing_aws_cli() {
  mkdir -p "$FAKE/noaws"
  ln -s "$(command -v python3)" "$FAKE/noaws/python3"
  RC=0
  PATH=$FAKE/noaws "$TOOL" --bucket my-alb-logs --lb my-alb --start 2026-10-01 >"$FAKE/out" 2>"$FAKE/err" || RC=$?
  expect_rc 2
  expect_err "aws CLI not found"
}

t_help_and_version() {
  run --version
  expect_rc 0
  [ "$(cat "$FAKE/out")" = "alb-log-grep 1.0.0" ] || fail "unexpected version: $(cat "$FAKE/out")"
  run --help
  expect_rc 0
  grep -qF -- "--bucket BUCKET" "$FAKE/out" || fail "help lacks --bucket"
  grep -qF "exit status: 0 = matches printed" "$FAKE/out" || fail "help lacks the exit codes"
}

echo "alb-log-grep tests (harness under bash $BASH_VERSION)"
for t in ${1+"$@"}; do
  declare -F "$t" >/dev/null || { echo "no such test: $t" >&2; exit 2; }
done
for t in ${1+"$@"} $([ $# -gt 0 ] || declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  run_test "$t"
done
echo "$PASSED passed${FAILED:+, failed:$FAILED}"
[ -z "$FAILED" ]
