# ssm-run

Run a local shell script on EC2 instances through SSM Run Command, wait for it,
and print each instance's status, exit code, stdout and stderr.

```sh
ssm-run -i i-0123456789abcdef0 check-disk.sh
ssm-run -t Role=web collect-logs.sh --output-dir ./results
echo 'df -h /' | ssm-run -i i-0123456789abcdef0,i-0fedcba9876543210
```

## Why

`aws ssm send-command` is awkward for anything beyond a one-liner. The script
has to be squeezed into a `--parameters commands=...` string, where quotes,
commas and backslashes need escaping. The results then come back through
separate polling calls, one instance at a time. ssm-run takes a real script
file and sends it line for line in a JSON request (built with `json.dumps`, so
nothing needs escaping). It then waits and prints every instance's result in
one place.

## Install

Needs python3 (3.8 or later) and the AWS CLI. The instances need a running SSM
agent and an instance profile that allows Systems Manager, for example the
`AmazonSSMManagedInstanceCore` managed policy.

```sh
install -m 0755 ssm-run/ssm-run ~/.local/bin/ssm-run
```

## Usage

```
ssm-run [options] (-i ID[,ID...] | -t KEY=VALUE ...) [SCRIPT | -]
```

| Option | Meaning |
|---|---|
| `SCRIPT` | local script file; `-` or nothing reads it from stdin |
| `-i, --instance-ids ID[,ID...]` | target instances, comma-separated or repeated (at most 50) |
| `-t, --tag KEY=VALUE` | target instances by tag, repeatable (see below) |
| `--timeout SECONDS` | stop the script on the host after SECONDS (default 600) |
| `--wait SECONDS` | stop waiting locally after SECONDS (default: `--timeout` + 60) |
| `--working-dir DIR` | working directory on the host |
| `--comment TEXT` | command comment (default `ssm-run SCRIPT`, cut to 100 characters) |
| `--max-concurrency N\|N%` | SSM MaxConcurrency |
| `--max-errors N\|N%` | SSM MaxErrors |
| `--output-dir DIR` | also write `INSTANCE.stdout`, `INSTANCE.stderr` and `INSTANCE.json` per instance |
| `-q, --quiet` | print status lines and the summary, not the script output |
| `--dry-run` | print the send-command request as JSON and call nothing |
| `--profile NAME`, `--region NAME` | AWS profile and region |

### How the script runs

- AWS-RunShellScript runs the script as root. The agent writes the lines to a
  file and starts it with `sh`, so a first line such as `#!/bin/bash` selects
  the interpreter.
- Each line of the script becomes one element of the document's `commands`
  parameter, exactly as written; CRLF line ends become LF. The request goes to
  the AWS CLI as a file (`--cli-input-json file://...`, in a private temporary
  directory), so the script never appears on a command line and its size is
  not limited by argv.
- `--timeout` sets the document's `executionTimeout`: the agent stops the
  script after that long and reports `TimedOut`. `--wait` only bounds the local
  wait. When it runs out, ssm-run prints the statuses so far and the command
  keeps running on the hosts.
- Tags: `-t Env=prod -t Env=staging -t Role=web` targets instances whose Env is
  prod or staging and whose Role is web. Values may contain commas.

### Output

```
== i-0123456789abcdef0: Success, exit 0
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1   30G   12G   19G  39% /
== i-0fedcba9876543210: Failed, exit 1
-- stderr
df: /data: No such file or directory
2 instances: 1 succeeded, 1 did not
  i-0fedcba9876543210: Failed (exit 1)
```

Instances are listed in id order. SSM returns at most 24,000 characters of
stdout and of stderr per instance, and ssm-run says so when an output hit that
limit. Write bigger outputs to a file on the host instead. `--output-dir`
writes each instance's stdout, stderr and a small JSON status file (status,
details, exit code, command id), mode 0600 in a 0700 directory.

### Exit status

| Code | Meaning |
|---|---|
| 0 | every instance succeeded |
| 1 | an instance failed, timed out or was cancelled; no instance matched; or `--wait` ran out |
| 2 | usage error, unreadable script, or a failed AWS call |

## IAM permissions

- `ssm:SendCommand` on the `AWS-RunShellScript` document and on the target
  instances;
- `ssm:ListCommands`, `ssm:ListCommandInvocations` and
  `ssm:GetCommandInvocation`.

## Notes

- Permission to run ssm-run on an instance is root on that instance. Scope
  `ssm:SendCommand` by instance tags.
- SSM keeps each command, including the script text, in its command history,
  and the output in the invocation results. Keep secrets out of scripts and
  out of what they print.
- Ctrl-C stops waiting but does not cancel the command. To cancel it, run
  `aws ssm cancel-command --command-id ID`.

## Tests

`bash ssm-run/test.sh` runs the suite against a file-backed fake of the AWS
CLI; nothing reaches AWS. Name tests to run a subset:
`bash ssm-run/test.sh t_commands_round_trip_exactly`.
