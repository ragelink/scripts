# flowlog-fanout

Find sources in your VPC whose fan-out suddenly jumps: the number of distinct
destination IPs they reach per time bin, on the ports you care about. The tool
runs a CloudWatch Logs Insights query over a VPC flow-log group, then flags bins
where a source went above `--factor` times its own median.

```sh
flowlog-fanout --log-group /vpc/flow-logs --since 6h
```

## Why

A compromised host that starts scanning, a worm that spreads, or a process
pushing data to many endpoints all look the same in flow logs: one source
suddenly talks to far more destinations than it normally does. Raw flow-log
volume hides that. Busy hosts are always busy, and a scanner can be quiet in
bytes. Comparing each source with its own baseline does not hide it, so a
load balancer with steady fan-out stays quiet while a web server that starts
reaching hundreds of addresses on 443 stands out.

## Requirements

- python3 (3.8 or later) and the AWS CLI;
- VPC flow logs delivered to CloudWatch Logs in the **default format**. Logs
  Insights discovers `srcAddr`, `dstAddr`, `dstPort` and `action` in that format
  by itself.

Copy the script to any directory on your `PATH`:

```sh
install -m 0755 flowlog-fanout/flowlog-fanout ~/.local/bin/flowlog-fanout
```

## Usage

```sh
# Last 6 hours, web ports, 5-minute bins
flowlog-fanout --log-group /vpc/flow-logs --since 6h

# A fixed window, SSH and RDP, accepted flows from one subnet only
flowlog-fanout --log-group /vpc/flow-logs --start 2026-10-06T00:00Z --end 2026-10-06T12:00Z \
    --ports 22,3389 --action ACCEPT --source-cidr 10.0.0.0/16 --profile acme

# Every row, not only flagged ones, as TSV for a spreadsheet
flowlog-fanout --log-group /vpc/flow-logs --since 1d --bin 15m --all --format tsv > fanout.tsv

# Rejected flows: scanners probing closed ports, more sensitive
flowlog-fanout --log-group /vpc/flow-logs --since 2h --action REJECT --factor 3 --min-dests 10
```

Example output (the summary line goes to stderr):

```
time                  source     dests  flows  median  ratio
2026-10-06T00:55:00Z  10.0.1.10    120    480       5   24.0
flowlog-fanout: 1 query, 37 rows, 4 sources, 1 flagged (factor 5, min-dests 20), 1.0 MB scanned
```

| Option | Meaning |
|---|---|
| `--log-group NAME` | the flow-log group (required) |
| `--since DURATION` | range ending at `--end`: `90m`, `6h`, `2d`, ... (default `1h`) |
| `--start TIME`, `--end TIME` | ISO 8601 (`2026-10-06T00:00:00Z`, `2026-10-06T00:00Z`, `2026-10-06`; UTC unless an offset is given) or epoch seconds; `--end` defaults to now |
| `--bin SIZE` | time bin: `30s`, `5m`, `1h`, `1d`, ... (default `5m`) |
| `--ports LIST` | destination ports, comma-separated (default `80,443`) |
| `--source-cidr CIDR` | only sources in this IPv4 CIDR |
| `--action ACCEPT\|REJECT\|ANY` | only flows with this action (default `ANY`) |
| `--factor N` | flag bins above N times the source's median (default 5) |
| `--min-dests N` | a flagged bin also needs at least N destinations (default 20) |
| `--all` | print every row, with a `flagged` column |
| `--format table\|tsv\|json` | output format (default `table`) |
| `--poll SECONDS` | time between result polls (default 2) |
| `--timeout SECONDS` | stop a query that has not finished after this long and fail (default 300) |
| `--query-limit N` | rows per query, at most 10000 (default 10000) |
| `--profile NAME`, `--region NAME` | AWS profile and region |

Exit status: **0** nothing flagged, **1** something flagged, **2** usage or
runtime error (bad arguments, a failed or timed-out query, an AWS CLI error).
Ctrl-C stops the running query and exits 130.

## How flagging works

The query counts, per source and per bin, the distinct destination addresses
(`dests`) and the flows (`flows`) on the given ports:

```
fields @timestamp, srcAddr, dstAddr, dstPort
| filter dstPort in [80,443]
| stats count_distinct(dstAddr) as dests, count(*) as flows by srcAddr, bin(5m)
| limit 10000
```

(`--action` and `--source-cidr` add `filter action = "..."` and
`filter isIpv4InSubnet(srcAddr, "...")` lines.)

For each source, the median of `dests` is taken over the bins **in which that
source appears**. Bins with no traffic do not count as zero. A bin is flagged
when both hold:

- `dests > factor x median`, and
- `dests >= min-dests`, so a host going from 1 destination to 8 is not reported.

`ratio` is `dests / median`. Flagged rows are sorted by ratio, highest first.

A source seen in only one or two bins has nothing to compare against. Its
median is its own count, so it is never flagged. Query a range that covers
many bins (6 hours at 5 minutes is 72) so each source has a baseline.

## Time ranges and the 10,000-row cap

Logs Insights returns at most 10,000 rows per query. When a query returns
exactly `--query-limit` rows, the result was cut off. flowlog-fanout splits that
time range at the bin boundary nearest its middle and queries each half,
recursively, until every part fits. The query's start and end times are both
inclusive, so the two halves share the boundary second. The rows for the bin
that starts at the boundary are taken from the later half only, so no bin is
counted twice and none is lost. If a single bin alone fills the limit, the
range cannot be split. The tool then warns that results may be incomplete; use
a narrower `--source-cidr`, fewer ports, or a smaller `--bin`.

The first and last bins of a range can be partial (for example, the current
bin when `--end` is now), so they may count fewer destinations than a full bin.
That can hide a spike, but cannot create one.

## Caveats

- `count_distinct` is approximate for high-cardinality data, so very large
  `dests` values are estimates.
- Logs Insights is billed by the data scanned. Long ranges over busy VPCs cost
  real money, and each split re-scans its half. The summary line shows the
  megabytes scanned.
- `--source-cidr` uses `isIpv4InSubnet`, so it is IPv4 only. Without it, IPv6
  sources are included.
- Custom flow-log formats are not supported: the query relies on the field
  names Insights discovers for the default format.

## IAM permissions

| Action | Used for |
|---|---|
| `logs:StartQuery` | running the query against the flow-log group |
| `logs:GetQueryResults` | polling for results |
| `logs:StopQuery` | stopping a query on `--timeout` or Ctrl-C |

Scope `logs:StartQuery` to the flow-log group.

## Tests

`bash flowlog-fanout/test.sh` runs the suite against a file-backed fake of
`aws logs` that applies Insights' range and row-limit semantics to a scenario
of pre-aggregated rows; nothing calls AWS. Name tests to run a subset:
`bash flowlog-fanout/test.sh t_spike_flagged_steady_sources_not`. The tests pin
"now" through the `FLOWLOG_FANOUT_NOW` environment variable (epoch seconds), a
test hook that is not meant for normal use.
