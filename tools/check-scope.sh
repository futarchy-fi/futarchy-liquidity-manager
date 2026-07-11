#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PATTERN='FAOSale|FAOToken|FutarchyArbitration|SXArbitration|SnapshotX|sx-evm|/Users/kas/FAO|\.\./FAO'
PATHS=(src script test config tools foundry.toml .github)

if git grep -n -E "$PATTERN" -- "${PATHS[@]}" ':(exclude)tools/check-scope.sh'; then
  echo "scope guard failed: FAO/Snapshot/arbitration-specific coupling found outside docs" >&2
  exit 1
fi

echo "scope guard passed"
