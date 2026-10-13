#!/usr/bin/env bash
# Fails when tracked or staged files look like they contain credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{40,}'
  'sk-[A-Za-z0-9]{32,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
)

files=$(git ls-files --cached --others --exclude-standard | grep -v '^scripts/secret-scan.sh$' || true)
status=0
for pattern in "${patterns[@]}"; do
  if matches=$(echo "$files" | xargs -I{} grep -EIl -e "$pattern" {} 2>/dev/null); then
    if [ -n "$matches" ]; then
      echo "Possible secret ($pattern) in:"
      echo "$matches"
      status=1
    fi
  fi
done

if echo "$files" | grep -E '(^|/)\.env(\.|$)' | grep -v '\.env\.example$' >/dev/null; then
  echo "Refusing to track .env files:"
  echo "$files" | grep -E '(^|/)\.env(\.|$)' | grep -v '\.env\.example$'
  status=1
fi

exit $status
