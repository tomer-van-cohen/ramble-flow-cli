#!/bin/bash
# Fails if tracked files contain things that must never be committed: absolute home paths,
# real-looking API keys, audio, databases, key files or runtime output.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
if git grep -nE '/Users/[A-Za-z0-9._-]+/' -- ':!scripts/check-repo.sh' | grep -vE '/Users/(example[0-9]?|you)/'; then
  echo "error: absolute home paths in tracked files" >&2; status=1
fi
if git grep -nE '(gsk_[A-Za-z0-9]{40,}|sk-(proj-)?[A-Za-z0-9_-]{40,})' -- ':!scripts/check-repo.sh'; then
  echo "error: something that looks like a real API key" >&2; status=1
fi
if git ls-files | grep -E '\.(sqlite|db|log|m4a|qta|wav|caf|mp3)$|secrets\.env$|^\.build/'; then
  echo "error: runtime output, audio or key files are tracked" >&2; status=1
fi
exit $status
