#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DEPLOY_CONFIG=""
BATCH_FILES=()
RUN_FORK_TESTS=false

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/preflight-limited-deploy.sh --deploy <file> [--batch <file> ...] [--run-fork-tests]

Runs the strict preflight expected before a limited-funds deployment:
  1. strict deploy/batch config validation;
  2. Safe batch JSON + Markdown summary generation for every batch;
  3. optional Gnosis fork tests when --run-fork-tests is supplied.

Example:
  tools/preflight-limited-deploy.sh \
    --deploy config/gnosis.production.json \
    --batch config/batches/bootstrap.production.json \
    --batch config/batches/set-proposal-validation.production.json \
    --run-fork-tests
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      DEPLOY_CONFIG="$2"
      shift 2
      ;;
    --batch)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      BATCH_FILES+=("$2")
      shift 2
      ;;
    --run-fork-tests)
      RUN_FORK_TESTS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$DEPLOY_CONFIG" && ${#BATCH_FILES[@]} -eq 0 ]]; then
  usage
  exit 64
fi

validate_args=()
if [[ -n "$DEPLOY_CONFIG" ]]; then
  validate_args+=(--deploy "$DEPLOY_CONFIG")
fi
for batch in "${BATCH_FILES[@]}"; do
  validate_args+=(--batch "$batch")
done

echo "== Strict config validation =="
bash tools/validate-configs.sh "${validate_args[@]}"

if [[ ${#BATCH_FILES[@]} -gt 0 ]]; then
  echo "== Batch generation =="
  FLM_BATCH_TEMPLATE_CHECK_OUT="${FLM_BATCH_TEMPLATE_CHECK_OUT:-out/preflight-limited-deploy}" \
    bash tools/check-batch-templates.sh "${BATCH_FILES[@]}"
fi

if [[ "$RUN_FORK_TESTS" == true ]]; then
  echo "== Gnosis fork tests =="
  RUN_GNOSIS_FORK_TESTS=true forge test --match-path 'test/fork/*'
else
  echo "== Gnosis fork tests skipped =="
  echo "Pass --run-fork-tests after setting a Gnosis RPC endpoint to include fork checks."
fi

echo "limited-funds deployment preflight passed"
