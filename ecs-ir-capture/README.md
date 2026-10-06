# ecs-ir-capture

Incident-response evidence capture on ECS and EC2 hosts, through SSM. Point it at
suspicious processes by command-line pattern, including processes inside
containers, and it collects what you need for analysis into a sealed, checksummed
bundle on each host. It never kills, stops or pauses anything.

```sh
ecs-ir-capture --pattern 'xmrig|kdevtmpfsi' -t Cluster=prod --s3-uri s3://my-ir-evidence/case-42
```

## Why

When something odd shows up on a container host (a miner, a reverse shell, an
unexpected binary in a task), the first instinct is to kill it. Killing it
destroys the best evidence: the binary may only exist in memory, the container's
filesystem changes vanish with the task, and the logs rotate. ecs-ir-capture
takes a read-only snapshot first, on every targeted host at once, so containment
can follow without losing the trail.

## What it captures

For each process whose command line matches `--pattern` (an extended regex, as
with `grep -E`), into `EVIDENCE-ROOT/<UTC time>-<hostname>/proc-PID/`:

| File | Content |
|---|---|
| `exe`, `exe.sha256`, `exe.path` | the executable read through `/proc/PID/exe` (the binary that is running, even if it was deleted or replaced on disk), its sha256, and the path it ran from; `exe` is set to mode 000 |
| `cmdline.txt` | the command line |
| `environ.txt` | the environment, one `NAME=value` per line; values of names containing SECRET, PASSWORD, TOKEN or KEY (any case) become `[REDACTED]` |
| `status.txt`, `maps.txt`, `cgroup.txt` | `/proc/PID/status`, memory maps, cgroup |
| `fd.txt`, `cwd.txt` | open files and sockets (`ls -l /proc/PID/fd`), working directory |
| `container-id.txt` | the Docker container id, from the cgroup |

Once per container, in `container-<id>/`: `docker diff` (files the container
changed), `docker logs --timestamps --since 2h` (stdout and stderr, capped at
50 MB), and selected `docker inspect` fields (image, command, labels, state,
mounts, privileges; never the environment). In `host/`: `ps auxww`,
`ss -tanp`, `docker ps -a`, `uname` and `uptime`.

Then it seals the bundle. `collection.log` records what was done, when (UTC) and
with which settings. `MANIFEST.sha256` holds the sha256 of every file.
`<name>.tar.gz` and `<name>.tar.gz.sha256` sit next to the directory, and with
`--s3-uri` both are uploaded from the host. Each host prints a summary: matched
processes, executable hashes, the bundle path and its sha256.

## Install

Needs bash, and [ssm-run](../ssm-run/) from this repository, next to this
script (`../ssm-run/ssm-run`) or on `PATH`. The hosts need the SSM agent (the
ECS-optimized AMIs include it), bash and coreutils. Docker and the AWS CLI on
the host are used when present.

```sh
install -m 0755 ecs-ir-capture/ecs-ir-capture ssm-run/ssm-run ~/.local/bin/
```

## Usage

```sh
# Every host in a cluster, upload the bundles
ecs-ir-capture --pattern 'xmrig|kdevtmpfsi' -t Cluster=prod --s3-uri s3://my-ir-evidence/case-42

# One host, a wider log window, local copies of each host's summary
ecs-ir-capture --pattern '/tmp/\.[a-z]+/' -i i-0123456789abcdef0 --log-since 12h --output-dir ./case-42

# No SSM: print the host script, review it, run it yourself as root
ecs-ir-capture --pattern 'xmrig' --print-script > capture.sh
sudo bash capture.sh
```

| Option | Meaning |
|---|---|
| `-p, --pattern REGEX` | processes to capture, matched against the full command line (required) |
| `-i, --instance-ids IDS`, `-t, --tag KEY=VALUE` | target hosts, as in ssm-run |
| `--max-procs N` | capture at most N matching processes per host (default 20) |
| `--log-since DURATION` | docker logs window, e.g. `30m`, `6h` (default `2h`) |
| `--no-redact` | keep environment values whose names look secret, and add `environ.raw` |
| `--s3-uri s3://BUCKET/PREFIX` | upload the bundle and its checksum from the host |
| `--evidence-root DIR` | where on the host (default `/var/tmp/ir-capture`, which survives reboots) |
| `--timeout SECONDS` | stop the capture on the host after SECONDS (default 900) |
| `--output-dir DIR` | keep each host's SSM output locally (passed to ssm-run) |
| `--print-script` | print the host script instead of running it |
| `--profile NAME`, `--region NAME` | AWS profile and region |

Exit status is ssm-run's: 0 when every host succeeded, 1 when a host failed
(including a failed upload), 2 on a usage error. A host where nothing matched
still succeeds and keeps its host listings, which are evidence too.

## Chain of custody basics

Evidence is only useful if you can show it was not altered between collection
and analysis. The tool does the mechanical part; the rest is process:

- **Record who, when and why.** Write down who authorized the capture, the
  incident or ticket reference, and the time. SSM keeps the command, its id and
  the caller's identity (and CloudTrail logs the call), which gives an
  independent record of who ran it and the hashes it printed at collection
  time.
- **Hash at collection, verify at every hop.** The bundle's sha256 is printed
  on the host before anything moves it. Check it again after every copy:
  `sha256sum -c <name>.tar.gz.sha256`, and after unpacking,
  `sha256sum -c MANIFEST.sha256` inside the directory.
- **Get it off the host quickly.** A compromised host is not a safe place to
  keep evidence. Use `--s3-uri` with a bucket that has versioning and S3 Object
  Lock (compliance mode), default encryption, and access limited to the
  responders. The host's instance role needs `s3:PutObject` on that prefix and
  nothing more. No delete, no read.
- **Work on copies.** Analyse a copy, never the original bundle. The `exe`
  files are live malware samples more often than not: they are mode 000 so
  nothing runs them by accident; keep it that way outside a sandbox.
- **Keep a custody log.** For every transfer or access, note the date and
  time, the person, the action, and that the hash still matched.
- **Know what it does not capture.** It takes no memory image. If you need one,
  use a memory acquisition tool (LiME, AVML) before anything else. Live
  collection also changes the host a little: new files under the evidence root,
  and processes that read `/proc`. Accurate clocks (chrony on Amazon Linux)
  keep timelines comparable across hosts.
- **Mind the secrets.** Environment values with secret-looking names are
  redacted by default. Command lines, logs and `ps` output are captured
  verbatim and can still contain credentials, so treat the bundle as sensitive.
  `--no-redact` keeps everything; use it only when the evidence store is
  protected accordingly.

Containment (isolating the instance, draining it, stopping the task) is a
separate decision that should come after capture. This tool never does it.

## IAM permissions

- Caller: what ssm-run needs (`ssm:SendCommand` on `AWS-RunShellScript` and the
  hosts, `ssm:ListCommands`, `ssm:ListCommandInvocations`,
  `ssm:GetCommandInvocation`).
- Host instance role, only with `--s3-uri`: `s3:PutObject` on the evidence
  prefix, plus `kms:GenerateDataKey` if the bucket uses SSE-KMS.

## Tests

`bash ecs-ir-capture/test.sh` runs the host script against a fake `/proc` tree,
with fakes of `docker`, `ps`, `ss` and `aws` that reject anything but the
read-only calls the tool makes. On Linux, one more test captures a real `sleep`
process through the real `/proc` and checks that it is still running afterwards.
The wrapper test sends the script through `../ssm-run` with the fake `aws`.
`IR_CAPTURE_PROC` points the host script at a fake `/proc`; it is a test hook,
not for normal use.
