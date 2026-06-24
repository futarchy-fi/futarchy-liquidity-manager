#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DEPLOY_CONFIG=""
DEPLOYMENT_OUTPUT=""
BATCH_FILES=()
PROPOSAL_ADDRESS=""
RUN_FORK_TESTS=false

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/preflight-limited-deploy.sh --deploy <file> [--deployment-output <file>] \
    [--batch <file> ...] [--proposal <address>] [--run-fork-tests]

Runs the strict preflight expected before a limited-funds deployment:
  1. strict deploy/batch config validation;
  2. Safe batch JSON + Markdown summary generation for every batch;
  3. optional deployment-output/batch link validation;
  4. optional final-address Gnosis fork tests when --run-fork-tests is supplied.

Example:
  tools/preflight-limited-deploy.sh \
    --deploy config/gnosis.production.json \
    --deployment-output deployments/flm.gnosis.json \
    --batch config/batches/bootstrap.production.json \
    --batch config/batches/set-proposal-validation.production.json \
    --proposal 0x1111111111111111111111111111111111111111 \
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
    --deployment-output)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      DEPLOYMENT_OUTPUT="$2"
      shift 2
      ;;
    --batch)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      BATCH_FILES+=("$2")
      shift 2
      ;;
    --proposal)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      PROPOSAL_ADDRESS="$2"
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

if [[ -z "$DEPLOY_CONFIG" && -z "$DEPLOYMENT_OUTPUT" && ${#BATCH_FILES[@]} -eq 0 ]]; then
  usage
  exit 64
fi

is_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

is_zero_address() {
  [[ "${1,,}" == "0x0000000000000000000000000000000000000000" ]]
}

validate_args=()
if [[ -n "$DEPLOY_CONFIG" ]]; then
  validate_args+=(--deploy "$DEPLOY_CONFIG")
fi
for batch in "${BATCH_FILES[@]}"; do
  validate_args+=(--batch "$batch")
done

if [[ ${#validate_args[@]} -gt 0 ]]; then
  echo "== Strict config validation =="
  bash tools/validate-configs.sh "${validate_args[@]}"
fi

if [[ ${#BATCH_FILES[@]} -gt 0 ]]; then
  echo "== Batch generation =="
  FLM_BATCH_TEMPLATE_CHECK_OUT="${FLM_BATCH_TEMPLATE_CHECK_OUT:-out/preflight-limited-deploy}" \
    bash tools/check-batch-templates.sh "${BATCH_FILES[@]}"
fi

if [[ -n "$DEPLOYMENT_OUTPUT" ]]; then
  artifact_args=(--deployment-output "$DEPLOYMENT_OUTPUT")
  if [[ -n "$DEPLOY_CONFIG" ]]; then
    artifact_args+=(--deploy "$DEPLOY_CONFIG")
  fi
  for batch in "${BATCH_FILES[@]}"; do
    artifact_args+=(--batch "$batch")
  done

  echo "== Deployment artifact links =="
  bash tools/check-deployment-artifacts.sh "${artifact_args[@]}"
fi

if [[ "$RUN_FORK_TESTS" == true ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "preflight failed: jq is required for final-address fork test binding" >&2
    exit 1
  fi

  if [[ -z "$PROPOSAL_ADDRESS" ]]; then
    for batch in "${BATCH_FILES[@]}"; do
      candidate="$(jq -r '
        select(.operation == "setOfficialProposal")
        | .proposal
        | select(type == "string" and test("^0x[0-9a-fA-F]{40}$"))
      ' "$batch")"
      if [[ -n "$candidate" && ! "$candidate" =~ ^[[:space:]]*$ ]]; then
        PROPOSAL_ADDRESS="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$PROPOSAL_ADDRESS" && -n "${TEST_FUTARCHY_PROPOSAL:-}" ]]; then
    PROPOSAL_ADDRESS="$TEST_FUTARCHY_PROPOSAL"
  fi

  if [[ -z "$PROPOSAL_ADDRESS" ]] \
    || ! is_address "$PROPOSAL_ADDRESS" \
    || is_zero_address "$PROPOSAL_ADDRESS"; then
    echo "preflight failed: --run-fork-tests requires --proposal <nonzero address> or a setOfficialProposal batch" >&2
    exit 1
  fi

  if [[ -n "$DEPLOY_CONFIG" ]]; then
    TEST_COMPANY_TOKEN="${TEST_COMPANY_TOKEN:-$(jq -r '.companyToken' "$DEPLOY_CONFIG")}"
    TEST_COLLATERAL_TOKEN="${TEST_COLLATERAL_TOKEN:-$(jq -r '.wrappedNative' "$DEPLOY_CONFIG")}"
    export TEST_COMPANY_TOKEN
    export TEST_COLLATERAL_TOKEN
  fi

  if [[ -z "${TEST_COMPANY_TOKEN:-}" ]] \
    || ! is_address "$TEST_COMPANY_TOKEN" \
    || is_zero_address "$TEST_COMPANY_TOKEN"; then
    echo "preflight failed: --run-fork-tests requires a nonzero company token from --deploy or TEST_COMPANY_TOKEN" >&2
    exit 1
  fi

  if [[ -z "${TEST_COLLATERAL_TOKEN:-}" ]] \
    || ! is_address "$TEST_COLLATERAL_TOKEN" \
    || is_zero_address "$TEST_COLLATERAL_TOKEN"; then
    echo "preflight failed: --run-fork-tests requires a nonzero collateral token from --deploy or TEST_COLLATERAL_TOKEN" >&2
    exit 1
  fi

  export TEST_FUTARCHY_PROPOSAL="$PROPOSAL_ADDRESS"
  echo "Fork proposal: $TEST_FUTARCHY_PROPOSAL"
  echo "Fork company token: $TEST_COMPANY_TOKEN"
  echo "Fork collateral token: $TEST_COLLATERAL_TOKEN"

  echo "== Gnosis fork tests =="
  RUN_GNOSIS_FORK_TESTS=true forge test --match-path 'test/fork/*'
else
  echo "== Gnosis fork tests skipped =="
  echo "Pass --run-fork-tests after setting a Gnosis RPC endpoint to include fork checks."
fi

echo "limited-funds deployment preflight passed"
