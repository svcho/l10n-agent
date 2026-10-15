#!/usr/bin/env bash
# Fails when files look like they contain credentials. Scans the staged (index)
# version of every tracked file, which is what a commit records, plus the working
# copy of tracked and untracked files.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}'
self='scripts/secret-scan.sh'
status=0

report() {
  echo "Possible secret in $1"
  status=1
}

# Staged blobs (also covers files whose working copy was cleaned after staging).
while IFS= read -r -d '' path; do
  [ "$path" = "$self" ] && continue
  # grep -c reads the whole blob: an early-exiting `grep -q` would SIGPIPE `git show`,
  # and with pipefail the pipeline would then look clean.
  # -a: binary blobs are scanned as text too (-I would skip them).
  hits=$(git show ":$path" 2>/dev/null | LC_ALL=C grep -Eac -e "$pattern" || true)
  if [ "${hits:-0}" -gt 0 ]; then
    report "$path (staged)"
  fi
done < <(git ls-files --cached -z)

# Working copies of tracked and untracked files.
while IFS= read -r -d '' path; do
  [ "$path" = "$self" ] && continue
  [ -f "$path" ] || continue
  if LC_ALL=C grep -Eaq -e "$pattern" "$path"; then
    report "$path"
  fi
done < <(git ls-files --cached --others --exclude-standard -z)

if git ls-files --cached --others --exclude-standard | grep -E '(^|/)\.env(\.|$)' | grep -v '\.env\.example$' >/dev/null; then
  echo "Refusing to track .env files:"
  git ls-files --cached --others --exclude-standard | grep -E '(^|/)\.env(\.|$)' | grep -v '\.env\.example$'
  status=1
fi

exit $status
