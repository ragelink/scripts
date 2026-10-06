#!/usr/bin/env bash
# make scan: the gate before every push; any finding fails it.
#
#  1. gitleaks over the commits about to be pushed (BASE..HEAD) and over the working tree.
#  2. A grep of everything those commits publish (added lines, file names, messages,
#     author and committer identities) for AWS access key ids, private key blocks,
#     ARNs, AWS hostnames and 12-digit account ids, plus the extra patterns in
#     .git/info/scan-denylist: one case-insensitive extended regex per line, '#'
#     comments allowed. That file lives inside .git, so it is never committed: keep
#     names there that must not appear in this public repository.
#
# BASE defaults to origin/master; run `git fetch` first.
set -euo pipefail
cd "$(dirname "$0")/.."

base=${BASE:-origin/master}
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "scan: no such base '$base'" >&2; exit 2; }
command -v gitleaks >/dev/null 2>&1 || { echo "scan: gitleaks not found" >&2; exit 2; }

status=0
echo "== gitleaks: commits $base..HEAD"
gitleaks git --no-banner --redact --config .gitleaks.toml --log-opts="$base..HEAD" . || status=1
echo "== gitleaks: working tree"
gitleaks dir --no-banner --redact --config .gitleaks.toml . || status=1

echo "== patterns: commits $base..HEAD"
text=$(
  git diff --no-color --unified=0 "$base...HEAD" | grep -E '^\+' | grep -vE '^\+\+\+ ' || true
  git diff --name-only "$base...HEAD"
  git log --format='%an <%ae>%n%cn <%ce>%n%B' "$base..HEAD"
)
check() {  # check LABEL GREP_FLAGS PATTERN SHOW: count matching lines; SHOW=1 prints them
  local n
  n=$(printf '%s\n' "$text" | grep -c "$2" -- "$3" || true)
  case $n in '' | *[!0-9]*) echo "scan: unusable pattern: $3" >&2; status=1; return 0 ;; esac
  [ "$n" -gt 0 ] || return 0
  echo "FOUND $1 ($n line(s)): $3"
  [ "$4" = 0 ] || printf '%s\n' "$text" | grep "$2" -- "$3" | head -n 20 | sed 's/^/    /'
  status=1
}
check "AWS access key id" -E 'AKIA[0-9A-Z]{16}' 0
check "private key block" -E 'BEGIN[ A-Z]*PRIVATE[ ]KEY' 0
check "AWS ARN" -E 'arn:(aws|aws-cn|aws-us-gov|aws-iso[a-z-]*):' 1
check "AWS hostname" -E '[A-Za-z0-9.-]+\.amazonaws\.com' 1
check "12-digit number (AWS account id?)" -E '(^|[^0-9])[0-9]{12}([^0-9]|$)' 1

denylist=$(git rev-parse --git-path info/scan-denylist)
if [ -f "$denylist" ]; then
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case $pattern in '' | '#'*) continue ;; esac
    check "denylisted name" -iE "$pattern" 1
  done <"$denylist"
else
  echo "(no $denylist: only the generic patterns were checked)"
fi

if [ $status = 0 ]; then
  echo "scan: clean"
else
  echo "scan: FAILED, do not push" >&2
  exit 1
fi
