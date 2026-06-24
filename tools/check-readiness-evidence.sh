#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

MANIFEST="${1:-audit/readiness-evidence.json}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "readiness evidence check failed: missing ${MANIFEST}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "readiness evidence check failed: jq is required" >&2
  exit 1
fi

jq -e '
  def nonempty: type == "string" and length > 0;
  def known_status:
    . == "ready-to-audit"
    or . == "awaits-final-inputs";
  type == "object"
  and .version == 1
  and (.status | nonempty)
  and (.requirements | type == "array" and length > 0)
  and all(.requirements[];
    (.id | nonempty)
    and (.title | nonempty)
    and (.status | known_status)
    and (.evidence | type == "array" and length > 0)
    and all(.evidence[];
      (.description | nonempty)
      and (
        (.path? | nonempty)
        or (.ciStep? | nonempty)
        or (.command? | nonempty)
      )
    )
    and (.remaining | type == "array")
    and all(.remaining[]; nonempty)
    and (
      if .status == "awaits-final-inputs"
      then (.remaining | length > 0)
      else true
      end
    )
  )
' "$MANIFEST" >/dev/null

missing=0
while IFS= read -r path; do
  if [[ ! -e "$path" ]]; then
    echo "readiness evidence check failed: referenced path does not exist: ${path}" >&2
    missing=1
  fi
done < <(jq -r '.requirements[].evidence[] | select(.path? != null) | .path' "$MANIFEST")

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

duplicates="$(jq -r '.requirements[].id' "$MANIFEST" | sort | uniq -d)"
if [[ -n "$duplicates" ]]; then
  echo "readiness evidence check failed: duplicate requirement id(s):" >&2
  echo "$duplicates" >&2
  exit 1
fi

echo "readiness evidence check passed: $MANIFEST"
