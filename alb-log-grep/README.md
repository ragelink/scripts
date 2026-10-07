# alb-log-grep

Search Application Load Balancer access logs in S3, many files at a time, and
print the matching entries as TSV.

```sh
alb-log-grep --bucket my-alb-logs --lb my-alb --start 2026-10-01 --status 5xx
```

## Why

During an incident you usually need a handful of requests: the 502s in the last
hour, everything one client IP did, every POST to `/admin`. ALB logs are written
as thousands of small gzip files per day, and Athena takes setup first (a
database, a table, partitions) before the first query. alb-log-grep lists only
the day folders and the load balancer you ask for, streams each file through
gunzip without saving it, applies the filters, and prints one TSV line per
entry, ready for `sort`, `cut`, `awk` or a spreadsheet.

## Requirements

python3 (3.8 or later, standard library only) and the AWS CLI, with credentials
that can read the log bucket. Copy the script to any directory on your `PATH`:

```sh
install -m 0755 alb-log-grep/alb-log-grep ~/.local/bin/alb-log-grep
```

## Usage

```sh
# 5xx responses of one load balancer on one day (UTC)
alb-log-grep --bucket my-alb-logs --lb my-alb --start 2026-10-01 --status 5xx

# one hour, one client network, logs under a bucket prefix
alb-log-grep --bucket my-alb-logs --prefix lb-logs --lb my-alb \
  --start 2026-10-01T12:00Z --end 2026-10-01T13:00Z --client 203.0.113.0/24

# POSTs to /admin over three days, chosen columns
alb-log-grep --bucket my-alb-logs --lb my-alb --start 2026-10-01 --end 2026-10-03 \
  --path '^/admin' --method POST --fields time,client_ip,path,elb_status,user_agent

# count requests per client IP
alb-log-grep --bucket my-alb-logs --lb my-alb --start 2026-10-01 \
  --fields client_ip --no-header | sort | uniq -c | sort -rn | head
```

| Option | Meaning |
|---|---|
| `--bucket B` | bucket holding the logs (required) |
| `--prefix P` | the load balancer's log prefix, i.e. the part of the key before `AWSLogs/` |
| `--lb NAME` | load balancer name (required); exact, so `my-alb` does not match `my-alb-2` |
| `--account-id ID` | account folder under `AWSLogs/` (default: every account found) |
| `--log-region R` | region folder of the logs (default: every region found) |
| `--start T` | `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS]Z`, UTC (required) |
| `--end T` | exclusive end, same formats; a date means the end of that day (default: the end of `--start`'s day) |
| `--path REGEX` | regex searched in the URL path (no query string) |
| `--url REGEX` | regex searched in the full request URL |
| `--client IP\|CIDR` | client address or network, IPv4 or IPv6 |
| `--status CODES` | ELB status: codes and classes, e.g. `5xx` or `502,503` |
| `--target-status CODES` | target status, same syntax |
| `--method LIST` | HTTP methods, e.g. `GET,POST` (case-insensitive) |
| `--fields LIST` | output columns (default below) |
| `--no-header` | omit the header line |
| `--jobs N` | files searched in parallel, 1 to 64 (default 8) |
| `--profile NAME` | AWS profile |
| `--region R` | AWS API region for the S3 calls (not the log region) |

All filters must match. Entries are always limited to `--start` <= time <
`--end`, using each entry's own `time` field.

## How it searches

The logs live at:

```
s3://BUCKET[/PREFIX]/AWSLogs/<account-id>/elasticloadbalancing/<region>/YYYY/MM/DD/
  <account-id>_elasticloadbalancing_<region>_app.<lb-name>.<lb-id>_<end-time>_<ip>_<random>.log.gz
```

1. Without `--account-id` and `--log-region`, it discovers them by listing one
   folder level at a time under `AWSLogs/`.
2. For each account, region and day it lists the day folder, narrowed to the
   file-name prefix of the load balancer, so other load balancers in the same
   bucket cost nothing.
3. A file covers about the 5 minutes before the end time in its name, and long
   requests or late entries can stray further. Files are therefore read from 5
   minutes before `--start` to 10 minutes after `--end`; the entries are then
   filtered by their own time. This is why a search ending at midnight also
   reads the first files of the next day's folder.
4. Each file is streamed with `aws s3 cp s3://... -` into Python's gzip reader,
   line by line, with no temporary files. `--jobs` files run in parallel.
5. Output follows the files' time order, and inside a file the file's own
   order (not necessarily strictly by time), whatever order the parallel
   downloads finish in.

### Why no xargs

The usual shell pipeline (`aws s3 ls ... | xargs -I{} -P8 aws s3 cp s3://.../{} -`)
breaks on macOS: BSD `xargs -I` limits each replaced argument to 255 bytes
(unless raised with `-S`) and aborts with "command line cannot be assembled, too
long" on longer input lines. ALB log keys are often longer than that once a
prefix is added. The parallelism here is a Python thread pool, with no length
limits and no shell quoting.

## Output

Tab-separated values, one line per entry, with a header line before the first
match (`--no-header` to drop it). Inside values, tab, newline, carriage return
and backslash are written as `\t`, `\n`, `\r` and `\\`, so every entry is exactly
one line. Quoted log fields (request, user agent, ...) are unquoted, with `\"`
turned back into `"`.

Default columns: `time client elb_status target_status method url request_time
target_time response_time received_bytes sent_bytes user_agent trace_id`.

`--fields` accepts:

- every ALB log field, by its documented name: `type time elb client target
  request_processing_time target_processing_time response_processing_time
  elb_status_code target_status_code received_bytes sent_bytes request
  user_agent ssl_cipher ssl_protocol target_group_arn trace_id domain_name
  chosen_cert_arn matched_rule_priority request_creation_time actions_executed
  redirect_url error_reason target_port_list target_status_code_list
  classification classification_reason conn_trace_id`;
- short aliases: `elb_status`, `target_status`, `request_time`, `target_time`,
  `response_time`;
- derived values: `method`, `url` and `protocol` (from `request`), `path` (the
  URL path), `client_ip`/`client_port`, `target_ip`/`target_port`, `key` (the
  S3 key of the file), and `raw` (the whole log line).

### Field notes

- `client` and `target` are logged as `ip:port`. IPv6 addresses appear without
  brackets, so the port is whatever follows the last colon.
- A request ALB could not parse is logged as `"- - - "`; its method, url,
  protocol and path are all `-`.
- `target_status` is `-` when no target answered (for example on a 502 or 503
  from the load balancer itself); `--target-status` never matches `-`.
- AWS appends new fields to the log format over time. Older files lack the
  trailing fields, which print as `-`; fields newer than `conn_trace_id` are
  ignored. A line with fewer than 14 fields, or without a timestamp in the
  second field, is reported as malformed.

## Performance and cost

Every file is one S3 GET request plus its size in transfer; listing is one LIST
request per account, region and day (more for folders with over 1000 files). A
load balancer writes a file per node every 5 minutes, more under heavy traffic,
so a day can mean thousands of GETs. Narrow the search with `--start`/`--end`,
`--lb`, `--account-id` and `--log-region` before reaching for more `--jobs`.
Transfer from S3 to the internet is billed; running from an instance in the
bucket's region avoids that. Decompression and filtering share one Python
process, so very large searches become CPU-bound; more `--jobs` mostly hides
network latency.

## IAM permissions

- `s3:ListBucket` on the log bucket. It can be limited to the log prefix with an
  `s3:prefix` condition.
- `s3:GetObject` on the log objects.
- `kms:Decrypt` on the bucket's key, if the bucket uses SSE-KMS.

## Exit status

| Status | Meaning |
|---|---|
| 0 | at least one entry matched |
| 1 | nothing matched, or no log files in the range |
| 2 | usage error, a listing that failed, or a file that could not be downloaded or parsed (a broken gzip stream, or malformed lines); matches from the other files are still printed |

Errors and a summary line (`searched N file(s), N entries, N matched`) go to
stderr, so stdout stays clean TSV.

## Tests

`bash alb-log-grep/test.sh` runs the suite against a strict, file-backed fake of
the AWS CLI serving a generated bucket of gzipped logs (two days, two load
balancers, two regions, plus broken and very long keys); nothing touches AWS.
Name tests to run a subset: `bash alb-log-grep/test.sh t_each_filter`.
