#!/usr/bin/env bash
# make lint: shellcheck every shell script, syntax-check every Python file, and
# require the executable bit on every file with a shebang.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v shellcheck >/dev/null 2>&1 || { echo "lint: shellcheck not found" >&2; exit 2; }

shell_files=() python_files=() status=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  first=$(head -n 1 "$f")
  case $first in
    '#!'*) [ -x "$f" ] || { echo "$f: has a shebang but is not executable" >&2; status=1; } ;;
  esac
  case $f in
    *.sh) shell_files+=("$f") ;;
    *.py) python_files+=("$f") ;;
    *)
      case $first in
        '#!'*bash* | '#!'*/sh | '#!'*' sh') shell_files+=("$f") ;;
        '#!'*python*) python_files+=("$f") ;;
      esac
      ;;
  esac
done < <(git ls-files --cached --others --exclude-standard)

echo "shellcheck $(shellcheck --version | sed -n 's/^version: //p'): ${#shell_files[@]} files"
if [ ${#shell_files[@]} -gt 0 ]; then shellcheck "${shell_files[@]}" || status=1; fi

echo "python syntax: ${#python_files[@]} files"
if [ ${#python_files[@]} -gt 0 ]; then
  python3 -I -c '
import ast, sys
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        ast.parse(f.read(), path)
' "${python_files[@]}" || status=1
fi

exit $status
