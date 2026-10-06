# clipsecret

Move a secret between your clipboard and AWS Secrets Manager without the value
ever appearing in your terminal, shell history, process list, or logs.

```sh
clipsecret set  <secret-id> [json-key]   # wait for a new value on the clipboard, store it
clipsecret copy <secret-id> [json-key]   # put a stored value on the clipboard
```

## Why

Rotating a credential usually means generating it in a vendor's web console and
then getting it into your secret store. The quick ways to do that leak it:

- `aws secretsmanager put-secret-value --secret-string '...'` leaves the value in
  your shell history, and in the process list while it runs;
- pasting it into a terminal leaves it in the scrollback, and on any screen share;
- pasting it into a chat or a ticket to hand it to someone else is worse.

With clipsecret you run `clipsecret set prod-secrets CLIENT_SECRET`, click
"copy" in the vendor console, and that's it. The value goes from the clipboard to
a private temporary file to Secrets Manager, the clipboard is cleared, and only
the value's length is printed. `clipsecret copy` is the reverse, for pasting a
stored value into a console.

## Install

Needs bash 3.2 or later (the stock macOS bash works), python3, the AWS CLI, and
a clipboard tool:

| Platform | Clipboard tool |
|---|---|
| macOS | `pbcopy` / `pbpaste` (built in) |
| Linux, Wayland | `wl-copy` / `wl-paste` (package `wl-clipboard`) |
| Linux, X11 | `xclip` or `xsel`, with `DISPLAY` set |

Copy the script to any directory on your `PATH`:

```sh
install -m 0755 clipsecret/clipsecret ~/.local/bin/clipsecret
```

## Usage

```sh
# Rotate one key of a JSON secret: start this, then copy the new value in the vendor console
clipsecret set prod-secrets CLIENT_SECRET --profile acme

# Replace a whole (non-JSON) secret
clipsecret set my-plain-secret

# Add a key that does not exist yet
clipsecret set prod-secrets NEW_API_KEY --create-key

# Headless: read the value from a pipe instead of the clipboard
generate-token | clipsecret set prod-secrets API_TOKEN --stdin

# Put a stored value on the clipboard; it is cleared after 30 s if still there
clipsecret copy prod-secrets API_TOKEN --clear-after 30

# Check access and the key without changing anything
clipsecret copy prod-secrets API_TOKEN --dry-run
```

`set` waits for the clipboard to change and judges each change once. A value is
rejected, and clipsecret keeps waiting, when it is:

- shorter than `--min-length` characters (default 16);
- contains whitespace, or invisible characters such as a zero-width space,
  unless `--allow-whitespace` is given;
- the value already stored (you copied the old one);
- empty, or not UTF-8 text.

One trailing newline (LF or CRLF) is dropped. If no valid value arrives within
`--timeout` seconds, nothing is written. Problems that do not depend on the
clipboard (unreadable secret, a json-key on a secret that is not a JSON object,
a missing key without `--create-key`) are reported before any waiting.

| Option | Command | Meaning |
|---|---|---|
| `--profile NAME` | both | AWS profile (default: `$AWS_PROFILE`) |
| `--region NAME` | both | AWS region (default: `$AWS_REGION` or the profile's) |
| `--timeout SECONDS` | set | how long to wait for the clipboard (default 120) |
| `--min-length N` | set | reject values shorter than N characters (default 16) |
| `--allow-whitespace` | set | accept whitespace and invisible characters |
| `--create-key` | set | allow adding a json-key that does not exist yet |
| `--stdin` | set | read the value from a pipe instead of the clipboard |
| `--clear-after SECS` | copy | clear the clipboard after SECS if it still holds the value; 0 = never (default 60) |
| `--dry-run` | both | read and validate, change nothing |

Exit status is 0 on success and 1 on any error. A secret is only written when the
output says `updated`.

## IAM permissions

| Command | Actions |
|---|---|
| `copy` | `secretsmanager:GetSecretValue` |
| `set` | `secretsmanager:GetSecretValue`, `secretsmanager:PutSecretValue` |

If the secret is encrypted with a customer-managed KMS key, the caller also needs
`kms:Decrypt` on that key (both commands) and `kms:GenerateDataKey` (set). Scope
`Resource` to the secrets you actually rotate:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"],
      "Resource": "<ARN of the prod-secrets secret>"
    }
  ]
}
```

## Security notes

- **Clipboard managers and history.** Anything on the clipboard can be captured
  by a clipboard manager or history tool (Raycast, Alfred, Maccy, Paste,
  Klipper, GPaste, cliphist, ...) and kept long after clipsecret clears it.
  Pause it, or exclude your terminal and browser, while you rotate. `pbcopy`
  cannot mark the value as concealed (the nspasteboard.org convention password
  managers use), so managers that honour that marker will still record it.
- **Clipboard sync.** macOS Universal Clipboard can send the value to your other
  Apple devices; remote desktop and VM tools may sync the clipboard too.
- **Auto-clear is best effort.** `copy` clears the clipboard after
  `--clear-after` seconds, and only if it still holds the value, so it never
  wipes something you copied later. `set` clears it after a successful write. A
  failed write leaves the new value on the clipboard on purpose, so a freshly
  rotated credential is not lost.
- **JSON re-serialization.** Updating one json-key rewrites the whole secret as
  compact JSON. Whitespace, string escaping (non-ASCII becomes `\uXXXX`) and
  number formatting may differ from the original, and duplicate keys collapse to
  the last value. Key order is kept, other values keep their types, and the
  updated key is always stored as a string. Anything that diffs the raw secret
  string will see more change than the one key.
- **Read-modify-write.** A json-key update reads the secret, changes one key, and
  writes the whole secret back. A change to another key made by someone else
  between the read and the write is lost.
- **Versions.** Each write creates a new secret version and moves `AWSCURRENT` to
  it; the previous value stays available as `AWSPREVIOUS`. To roll back, find
  the version ids with `aws secretsmanager list-secret-version-ids --secret-id
  prod-secrets`, then run `aws secretsmanager update-secret-version-stage
  --secret-id prod-secrets --version-stage AWSCURRENT --move-to-version-id
  <previous-id> --remove-from-version-id <current-id>`.
- **Never printed.** The value never appears on a command line (the AWS CLI reads
  it from a `file://` path) and is never echoed. AWS CLI errors are shown with
  any secret material masked, and the Python helper reports unexpected errors by
  exception type only, because exception messages can quote the data.
- **AWS CLI history.** With `cli_history` enabled, the AWS CLI stores request and
  response bodies, which means secret values, in `~/.aws/cli/history`.
  clipsecret refuses to run until it is disabled for the profile.
- **Temporary files.** The value passes through files that are mode 0600, in a
  0700 directory under `$TMPDIR`, and removed on exit, Ctrl-C, or SIGTERM. A
  SIGKILL or a crash can leave them behind.

## Tests

`bash clipsecret/test.sh` runs the suite against file-backed fakes of `aws`,
`pbcopy`/`pbpaste`, `xclip`, `xsel` and `wl-copy`/`wl-paste`; nothing touches
AWS or the real clipboard. `TEST_BASH=/bin/bash` runs the tool under the stock
macOS bash 3.2, and `make test` at the repository root does both. Name tests to
run a subset: `bash clipsecret/test.sh t_set_plain t_copy_json_key`.
