#!/usr/bin/env bash
# make test: run every tool's test.sh. On macOS, also run them with the stock
# /bin/bash 3.2 when another bash comes first on PATH (Homebrew's, on most dev
# machines). GitHub's macOS runners have /bin/bash first, so CI covers 3.2 there
# and bash 5 on Ubuntu.
set -euo pipefail
cd "$(dirname "$0")/.."

bashes=("$(command -v bash)")
if [ "${bashes[0]}" != /bin/bash ] && [ -x /bin/bash ]; then
  case $(/bin/bash --version) in *"version 3."*) bashes+=(/bin/bash) ;; esac
fi

failed=""
for t in */test.sh; do
  [ -f "$t" ] || continue  # no tool has tests yet: the glob stays unexpanded
  for b in "${bashes[@]}"; do
    echo "== $t ($("$b" --version | head -n 1))"
    TEST_BASH=$b "$b" "$t" || failed="$failed $t(${b})"
  done
done
if [ -n "$failed" ]; then
  echo "FAILED:$failed" >&2
  exit 1
fi
