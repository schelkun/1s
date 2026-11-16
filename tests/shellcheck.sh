#!/usr/bin/env bash
# Run ShellCheck on every shell script in the repository.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v shellcheck >/dev/null || { echo "shellcheck not installed" >&2; exit 1; }
mapfile -t files < <( { find scripts tests -type f -name '*.sh'; echo scripts/server/1s; } | sort -u)
shellcheck --external-sources --source-path=SCRIPTDIR --source-path=. --severity=style "${files[@]}"
echo "ShellCheck: ${#files[@]} files clean."
