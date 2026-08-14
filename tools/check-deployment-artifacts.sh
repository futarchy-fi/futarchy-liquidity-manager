#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DEPLOY_CONFIG=""
DEPLOYMENT_OUTPUT=""
BATCH_FILES=()

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/check-deployment-artifacts.sh --deployment-output <file> \
    [--deploy <file>] [--batch <file> ...]

Checks that deployment output and operation batches refer to the same deployed FLM stack:
  - deployment output has the expected schema;
  - deployment output records config and deployed bytecode hashes;
  - optional deploy config matches output owner/proposal-manager/token/bootstrap fields;
  - batches use the deployed manager/proposal source/token addresses;
  - owner-only, proposal-source, and bootstrap-only Safe batches are created from an expected Safe.
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

if [[ -z "$DEPLOYMENT_OUTPUT" ]]; then
  usage
  exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "deployment artifact check failed: jq is required" >&2
  exit 1
fi

require_jq() {
  local file="$1"
  local filter="$2"
  local message="$3"

  if [[ ! -f "$file" ]]; then
    echo "deployment artifact check failed (${file}): file does not exist" >&2
    exit 1
  fi

  if ! jq -e "$filter" "$file" >/dev/null; then
    echo "deployment artifact check failed (${file}): ${message}" >&2
    exit 1
  fi
}

json_string() {
  jq -r "$2 | tostring" "$1"
}

json_address() {
  jq -r "$2" "$1"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

require_same_value() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "deployment artifact check failed: ${label} mismatch (${actual} != ${expected})" >&2
    exit 1
  fi
}

require_same_address() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [[ "$(lower "$actual")" != "$(lower "$expected")" ]]; then
    echo "deployment artifact check failed: ${label} mismatch (${actual} != ${expected})" >&2
    exit 1
  fi
}

require_same_address_or() {
  local label="$1"
  local actual="$2"
  local first="$3"
  local second="$4"

  local actual_lower
  local first_lower
  local second_lower
  actual_lower="$(lower "$actual")"
  first_lower="$(lower "$first")"
  second_lower="$(lower "$second")"

  if [[ "$actual_lower" != "$first_lower" && "$actual_lower" != "$second_lower" ]]; then
    echo "deployment artifact check failed: ${label} mismatch (${actual} != ${first} or ${second})" >&2
    exit 1
  fi
}

file_keccak() {
  if ! command -v cast >/dev/null 2>&1; then
    echo "deployment artifact check failed: cast is required to verify configHash" >&2
    exit 1
  fi

  cast keccak "0x$(od -An -tx1 -v "$1" | tr -d ' \n')"
}

deployment_output_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  def bytes32: type == "string" and test("^0x[0-9a-fA-F]{64}$");
  def zero: "0x0000000000000000000000000000000000000000";
  def zero32: "0x0000000000000000000000000000000000000000000000000000000000000000";
  def nzaddress: address and (ascii_downcase != zero);
  def nzbytes32: bytes32 and (ascii_downcase != zero32);
  def chain: (type == "number" and . > 0) or (type == "string" and test("^[0-9]+$") and (tonumber > 0));
  type == "object"
  and (.chainId | chain)
  and (.configHash | nzbytes32)
  and (.organization | nzaddress)
  and (.factory | nzaddress)
  and (.owner | nzaddress)
  and (.proposalManager | nzaddress)
  and (.bootstrapRecipient | nzaddress)
  and (.companyToken | nzaddress)
  and (.wrappedNative | nzaddress)
  and (.officialProposer | nzaddress)
  and (.poolStabilityGuard | nzaddress)
  and (.proposalSource | nzaddress)
  and (.deadlineProxy | address)
  and (.spotAdapter | nzaddress)
  and (.conditionalAdapter | nzaddress)
  and (.manager | nzaddress)
  and (.factoryCodeHash | nzbytes32)
  and (.proposalSourceCreationCodeHash | nzbytes32)
  and (.spotAdapterCreationCodeHash | nzbytes32)
  and (.conditionalAdapterCreationCodeHash | nzbytes32)
  and (.managerCreationCodeHash | nzbytes32)
  and (.proposalSourceCodeHash | nzbytes32)
  and (.deadlineProxyCodeHash | bytes32)
  and (.spotAdapterCodeHash | nzbytes32)
  and (.conditionalAdapterCodeHash | nzbytes32)
  and (.managerCodeHash | nzbytes32)
'

deploy_config_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  type == "object"
  and (.chainId | type == "number" and . > 0)
  and (.organization | address)
  and (.factory | address)
  and (.owner | address)
  and (.proposalManager | address)
  and (.bootstrapRecipient | address)
  and (.companyToken | address)
  and (.wrappedNative | address)
  and (.officialProposer | address)
  and (.poolStabilityGuard | address)
'

batch_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  type == "object"
  and (.chainId | type == "number" and . > 0)
  and (.operation | type == "string" and length > 0)
  and (.createdFromSafeAddress | address)
  and (.manager | address)
  and (.proposalSource | address)
  and (.companyToken | address)
  and (.collateralToken | address)
  and (.collateralAmount | type == "number" and . >= 0)
'

require_jq "$DEPLOYMENT_OUTPUT" "$deployment_output_filter" "deployment output schema is invalid"

deployment_chain="$(json_string "$DEPLOYMENT_OUTPUT" '.chainId')"
deployment_config_hash="$(json_address "$DEPLOYMENT_OUTPUT" '.configHash')"
deployment_organization="$(json_address "$DEPLOYMENT_OUTPUT" '.organization')"
deployment_factory="$(json_address "$DEPLOYMENT_OUTPUT" '.factory')"
deployment_owner="$(json_address "$DEPLOYMENT_OUTPUT" '.owner')"
deployment_proposal_manager="$(json_address "$DEPLOYMENT_OUTPUT" '.proposalManager')"
deployment_bootstrap="$(json_address "$DEPLOYMENT_OUTPUT" '.bootstrapRecipient')"
deployment_company="$(json_address "$DEPLOYMENT_OUTPUT" '.companyToken')"
deployment_collateral="$(json_address "$DEPLOYMENT_OUTPUT" '.wrappedNative')"
deployment_official_proposer="$(json_address "$DEPLOYMENT_OUTPUT" '.officialProposer')"
deployment_pool_stability_guard="$(json_address "$DEPLOYMENT_OUTPUT" '.poolStabilityGuard')"
deployment_proposal_source="$(json_address "$DEPLOYMENT_OUTPUT" '.proposalSource')"
deployment_manager="$(json_address "$DEPLOYMENT_OUTPUT" '.manager')"

if [[ -n "$DEPLOY_CONFIG" ]]; then
  require_jq "$DEPLOY_CONFIG" "$deploy_config_filter" "deploy config schema is invalid"
  require_same_address "deploy configHash" "$deployment_config_hash" "$(file_keccak "$DEPLOY_CONFIG")"
  require_same_value "deploy chainId" \
    "$(json_string "$DEPLOYMENT_OUTPUT" '.chainId')" \
    "$(json_string "$DEPLOY_CONFIG" '.chainId')"
  require_same_address "deploy organization" \
    "$deployment_organization" \
    "$(json_address "$DEPLOY_CONFIG" '.organization')"
  config_factory="$(json_address "$DEPLOY_CONFIG" '.factory')"
  if [[ "$(lower "$config_factory")" != "0x0000000000000000000000000000000000000000" ]]; then
    require_same_address "deploy factory" "$deployment_factory" "$config_factory"
  fi
  require_same_address "deploy owner" \
    "$deployment_owner" \
    "$(json_address "$DEPLOY_CONFIG" '.owner')"
  require_same_address "deploy proposalManager" \
    "$deployment_proposal_manager" \
    "$(json_address "$DEPLOY_CONFIG" '.proposalManager')"
  require_same_address "deploy bootstrapRecipient" \
    "$deployment_bootstrap" \
    "$(json_address "$DEPLOY_CONFIG" '.bootstrapRecipient')"
  require_same_address "deploy companyToken" \
    "$deployment_company" \
    "$(json_address "$DEPLOY_CONFIG" '.companyToken')"
  require_same_address "deploy wrappedNative" \
    "$deployment_collateral" \
    "$(json_address "$DEPLOY_CONFIG" '.wrappedNative')"
  require_same_address "deploy officialProposer" \
    "$deployment_official_proposer" \
    "$(json_address "$DEPLOY_CONFIG" '.officialProposer')"
  require_same_address "deploy poolStabilityGuard" \
    "$deployment_pool_stability_guard" \
    "$(json_address "$DEPLOY_CONFIG" '.poolStabilityGuard')"
fi

if [[ ${#BATCH_FILES[@]} -gt 0 ]]; then
  for batch in "${BATCH_FILES[@]}"; do
    require_jq "$batch" "$batch_filter" "batch schema is invalid"

    operation="$(json_string "$batch" '.operation')"
    require_same_value "${batch} chainId" "$(json_string "$batch" '.chainId')" "$deployment_chain"

    case "$operation" in
      initializeFromBootstrap|depositToSpot|sync|redeem|armEmergencyExit|disarmEmergencyExit|executeEmergencyExit|sweepIdleToBootstrapRecipient)
        require_same_address "${batch} manager" \
          "$(json_address "$batch" '.manager')" \
          "$deployment_manager"
        ;;
    esac

    case "$operation" in
      setOfficialProposal|setProposalValidationConfig)
        require_same_address "${batch} proposalSource" \
          "$(json_address "$batch" '.proposalSource')" \
          "$deployment_proposal_source"
        ;;
    esac

    case "$operation" in
      initializeFromBootstrap|depositToSpot)
        require_same_address "${batch} companyToken" \
          "$(json_address "$batch" '.companyToken')" \
          "$deployment_company"
        if [[ "$(json_string "$batch" '.collateralAmount')" != "0" ]]; then
          require_same_address "${batch} collateralToken" \
            "$(json_address "$batch" '.collateralToken')" \
            "$deployment_collateral"
        fi
        ;;
    esac

    case "$operation" in
      initializeFromBootstrap)
        require_same_address "${batch} createdFromSafeAddress" \
          "$(json_address "$batch" '.createdFromSafeAddress')" \
          "$deployment_bootstrap"
        ;;
      setOfficialProposal|setProposalValidationConfig)
        require_same_address_or "${batch} createdFromSafeAddress" \
          "$(json_address "$batch" '.createdFromSafeAddress')" \
          "$deployment_owner" \
          "$deployment_proposal_manager"
        ;;
      armEmergencyExit|disarmEmergencyExit|executeEmergencyExit|sweepIdleToBootstrapRecipient)
        require_same_address "${batch} createdFromSafeAddress" \
          "$(json_address "$batch" '.createdFromSafeAddress')" \
          "$deployment_owner"
        ;;
    esac

    if [[ "$operation" == "setOfficialProposal" ]]; then
      require_same_address "${batch} creator" \
        "$(json_address "$batch" '.creator')" \
        "$deployment_official_proposer"
    fi

    if [[ "$operation" == "setProposalValidationConfig" ]]; then
      require_same_address "${batch} validation.expectedProposalToken" \
        "$(json_address "$batch" '.validation.expectedProposalToken')" \
        "$deployment_company"
      require_same_address "${batch} validation.expectedCollateralToken" \
        "$(json_address "$batch" '.validation.expectedCollateralToken')" \
        "$deployment_collateral"
    fi

    echo "deployment artifact links passed: $batch"
  done
fi

echo "deployment artifact check passed: $DEPLOYMENT_OUTPUT"
