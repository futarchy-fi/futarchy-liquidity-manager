#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if ! command -v jq >/dev/null 2>&1; then
  echo "batch template check failed: jq is required" >&2
  exit 1
fi

OUT_DIR="${FLM_BATCH_TEMPLATE_CHECK_OUT:-out/batch-template-check}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  FILES=(config/safe-batch.example.json config/batches/*.example.json)
fi

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "batch template check failed: missing file ${file}" >&2
    exit 1
  fi

  base="$(basename "$file" .json)"
  safe_json="${OUT_DIR}/${base}.safe.json"
  summary_md="${OUT_DIR}/${base}.summary.md"

  FLM_BATCH_CONFIG="$file" \
  FLM_BATCH_OUTPUT="$safe_json" \
  FLM_BATCH_SUMMARY="$summary_md" \
    forge script script/BuildLiquidityOperationBatch.s.sol >/dev/null

  jq -e '.version == "1.0" and (.transactions | type == "array") and (.transactions | length > 0)' \
    "$safe_json" >/dev/null
  grep -q '^# FLM Safe Batch Summary' "$summary_md"

  echo "batch template generation passed: $file"
done

for legacy_key in spotAdd spotExit yesAdd noAdd yesExit noExit; do
  legacy_json="${OUT_DIR}/legacy-${legacy_key}.json"
  jq --arg key "$legacy_key" '. + {($key): {}}' config/safe-batch.example.json > "$legacy_json"
  if tools/validate-configs.sh --allow-placeholders --batch "$legacy_json" >/dev/null 2>&1; then
    echo "batch template check failed: accepted legacy key ${legacy_key}" >&2
    exit 1
  fi
done

echo "legacy adapter parameter rejection passed"
