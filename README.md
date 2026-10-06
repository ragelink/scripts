# scripts

Scripts and other utilitarian junk: small, single-purpose command-line tools,
one folder per tool. Each folder has a README with the details.

## Tools

| Tool | What it does | Language |
|---|---|---|
| [clipsecret](clipsecret/) | Move secrets between the clipboard and AWS Secrets Manager without ever printing them | Bash, Python |
| [csv-epoch-localtime](csv-epoch-localtime/) | Rewrite epoch UTC timestamps in a CSV (e.g. a Zoom chat export) as local time | Python |
| [ecs-ir-capture](ecs-ir-capture/) | Read-only incident-response capture on ECS/EC2 hosts via SSM: binaries, environment, container diff and logs of matching processes | Bash |
| [flowlog-fanout](flowlog-fanout/) | Flag sources whose fan-out (distinct destination IPs per time bin) spikes in VPC flow logs, via Logs Insights | Python |
| [ssm-run](ssm-run/) | Run a local shell script on EC2 instances through SSM Run Command and print each instance's output | Python |

## Conventions

- One folder per tool, holding the executable, a `README.md`, and a `test.sh`
  for tools that have tests.
- Bash tools run under the stock macOS bash 3.2 as well as bash 5, use
  `set -euo pipefail`, and are shellcheck-clean.
- Tests never touch real services or the real clipboard: the AWS CLI and
  similar tools are replaced by file-backed fakes placed first on `PATH`.
- No real account ids, hostnames, ARNs, or secret names anywhere, examples
  included. Use placeholders like `prod-secrets`, `API_TOKEN`, `--profile acme`.

## Development

```sh
pre-commit install   # once per clone: gitleaks scans every commit (pipx install pre-commit, or brew install pre-commit)
make lint            # shellcheck, Python syntax, executable bits
make test            # every tool's test.sh; on macOS also under /bin/bash 3.2
make scan            # before every push: gitleaks + pattern grep over origin/master..HEAD
```

`make scan` fails on any finding. Besides gitleaks, it greps the outgoing
commits (added lines, file names, messages, author identities) for AWS access
key ids, private key blocks, ARNs, AWS hostnames, and 12-digit account ids. It
also reads extra patterns from `.git/info/scan-denylist`, one case-insensitive
extended regex per line. That file lives inside `.git`, so it is never
committed: names that must never be published belong there.

CI runs gitleaks over the full history, plus lint and tests on Ubuntu and macOS.

## License

[Apache-2.0](LICENSE)
