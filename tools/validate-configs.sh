#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

ALLOW_PLACEHOLDERS=false
DEPLOY_FILES=()
BATCH_FILES=()

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/validate-configs.sh [--allow-placeholders] --deploy <file> [--batch <file> ...]

Examples:
  tools/validate-configs.sh --allow-placeholders \
    --deploy config/gnosis.example.json \
    --batch config/safe-batch.example.json

  tools/validate-configs.sh \
    --deploy config/gnosis.production.json \
    --batch config/batches/bootstrap.production.json
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-placeholders)
      ALLOW_PLACEHOLDERS=true
      shift
      ;;
    --deploy)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      DEPLOY_FILES+=("$2")
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

if [[ ${#DEPLOY_FILES[@]} -eq 0 && ${#BATCH_FILES[@]} -eq 0 ]]; then
  usage
  exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "config validation failed: jq is required" >&2
  exit 1
fi

require_jq() {
  local file="$1"
  local filter="$2"
  local message="$3"

  if [[ ! -f "$file" ]]; then
    echo "config validation failed (${file}): file does not exist" >&2
    exit 1
  fi

  if ! jq -e "$filter" "$file" >/dev/null; then
    echo "config validation failed (${file}): ${message}" >&2
    exit 1
  fi
}

deploy_schema_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  type == "object"
  and (.chainId | type == "number" and . > 0)
  and (.owner | address)
  and (.bootstrapRecipient | address)
  and (.companyToken | address)
  and (.officialProposer | address)
  and (.wrappedNative | address)
  and (.positionManager | address)
  and (.algebraFactory | address)
  and (.futarchyRouter | address)
  and (.tickLower | type == "number")
  and (.tickUpper | type == "number")
  and (.tickLower < .tickUpper)
  and (.lpTokenName | type == "string" and length > 0)
  and (.lpTokenSymbol | type == "string" and length > 0)
  and (.deployDeadlineProxy | type == "boolean")
  and (.deadlineProxy.conditionalTokens | address)
  and (.deadlineProxy.realitio | address)
  and (.deadlineProxy.maxQuestionDuration | type == "number" and . >= 0)
  and (.validation.enabled | type == "boolean")
  and (.validation.expectedProposalToken | address)
  and (.validation.expectedCollateralToken | address)
  and (.validation.conditionalTokens | address)
  and (.validation.trustedOracle | address)
  and (.validation.realitio | address)
  and (.validation.trustedArbitrator | address)
  and (.validation.maxOpeningDelay | type == "number" and . >= 0)
  and (.validation.minTimeout | type == "number" and . >= 0)
  and (.validation.maxTimeout | type == "number" and . >= 0)
  and (.validation.maxTimeout >= .validation.minTimeout)
  and (.validation.maxMinBond | type == "number" and . >= 0)
  and (.validation.requirePools | type == "boolean")
'

deploy_strict_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  def zero: "0x0000000000000000000000000000000000000000";
  def nzaddress: address and (ascii_downcase != zero);
  (.owner | nzaddress)
  and (.bootstrapRecipient | nzaddress)
  and (.companyToken | nzaddress)
  and (.officialProposer | nzaddress)
  and (.wrappedNative | nzaddress)
  and (.positionManager | nzaddress)
  and (.algebraFactory | nzaddress)
  and (.futarchyRouter | nzaddress)
  and (.validation.enabled == true)
  and (.validation.expectedProposalToken | nzaddress)
  and (.validation.expectedCollateralToken | nzaddress)
  and (.validation.conditionalTokens | nzaddress)
  and (
    if .deployDeadlineProxy == true
    then (.validation.trustedOracle | address)
    else (.validation.trustedOracle | nzaddress)
    end
  )
  and (.validation.realitio | nzaddress)
  and (.validation.trustedArbitrator | nzaddress)
  and (.validation.maxOpeningDelay > 0)
  and (.validation.minTimeout > 0)
  and (.validation.maxTimeout >= .validation.minTimeout)
  and (.validation.requirePools == true)
  and (
    if .deployDeadlineProxy == true
    then
      (.deadlineProxy.conditionalTokens | nzaddress)
      and (.deadlineProxy.realitio | nzaddress)
      and (.deadlineProxy.maxQuestionDuration > 0)
    else true
    end
  )
'

batch_schema_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  def oneof($values): . as $value | $values | index($value) != null;
  def nonnegative: type == "number" and . >= 0;
  def addparams($p):
    ($p.tickLower | type == "number")
    and ($p.tickUpper | type == "number")
    and ($p.tickLower < $p.tickUpper)
    and ($p.amount0Min | nonnegative)
    and ($p.amount1Min | nonnegative)
    and ($p.deadline | nonnegative)
    and ($p.sqrtPriceX96 | nonnegative);
  def exitparams($p):
    ($p.amount0Min | nonnegative)
    and ($p.amount1Min | nonnegative)
    and ($p.deadline | nonnegative);
  type == "object"
  and (.chainId | type == "number" and . > 0)
  and (.name | type == "string" and length > 0)
  and (.createdFromSafeAddress | address)
  and (.createdFromOwnerAddress | address)
  and (
    .operation | oneof([
      "initializeFromBootstrap",
      "depositToSpot",
      "sync",
      "redeem",
      "setOfficialProposal",
      "setProposalValidationConfig",
      "armEmergencyExit",
      "disarmEmergencyExit",
      "emergencyExitAllToBootstrapRecipient",
      "sweepIdleToBootstrapRecipient"
    ])
  )
  and (.manager | address)
  and (.proposalSource | address)
  and (.companyToken | address)
  and (.collateralToken | address)
  and (.companyAmount | nonnegative)
  and (.collateralAmount | nonnegative)
  and (.nativeValue | nonnegative)
  and (.shares | nonnegative)
  and (.recipient | address)
  and (.unwrapNative | type == "boolean")
  and (.proposalId | nonnegative)
  and (.proposal | address)
  and (.creator | address)
  and addparams(.spotAdd)
  and exitparams(.spotExit)
  and addparams(.yesAdd)
  and addparams(.noAdd)
  and exitparams(.yesExit)
  and exitparams(.noExit)
  and (.validation.enabled | type == "boolean")
  and (.validation.expectedProposalToken | address)
  and (.validation.expectedCollateralToken | address)
  and (.validation.conditionalTokens | address)
  and (.validation.trustedOracle | address)
  and (.validation.realitio | address)
  and (.validation.trustedArbitrator | address)
  and (.validation.maxOpeningDelay | nonnegative)
  and (.validation.minTimeout | nonnegative)
  and (.validation.maxTimeout | nonnegative)
  and (.validation.maxTimeout >= .validation.minTimeout)
  and (.validation.maxMinBond | nonnegative)
  and (.validation.requirePools | type == "boolean")
'

batch_strict_filter='
  def address: type == "string" and test("^0x[0-9a-fA-F]{40}$");
  def zero: "0x0000000000000000000000000000000000000000";
  def nzaddress: address and (ascii_downcase != zero);
  def positive: type == "number" and . > 0;
  def oneof($values): . as $value | $values | index($value) != null;
  def addstrict($p):
    ($p.tickLower < $p.tickUpper)
    and ($p.amount0Min | positive)
    and ($p.amount1Min | positive)
    and ($p.deadline | positive);
  def exitstrict($p):
    ($p.amount0Min | positive)
    and ($p.amount1Min | positive)
    and ($p.deadline | positive);
  def validationstrict:
    (.validation.enabled == true)
    and (.validation.expectedProposalToken | nzaddress)
    and (.validation.expectedCollateralToken | nzaddress)
    and (.validation.conditionalTokens | nzaddress)
    and (.validation.trustedOracle | nzaddress)
    and (.validation.realitio | nzaddress)
    and (.validation.trustedArbitrator | nzaddress)
    and (.validation.maxOpeningDelay > 0)
    and (.validation.minTimeout > 0)
    and (.validation.maxTimeout >= .validation.minTimeout)
    and (.validation.requirePools == true);
  def fundingstrict:
    (
      (.nativeValue | positive)
      and (.collateralAmount == 0)
    )
    or (
      (.nativeValue == 0)
      and (.collateralAmount | positive)
      and (.collateralToken | nzaddress)
    );
  .operation as $op
  | (.createdFromSafeAddress | nzaddress)
  and (.createdFromOwnerAddress | nzaddress)
  and (
    if ($op | oneof([
      "initializeFromBootstrap",
      "depositToSpot",
      "sync",
      "redeem",
      "armEmergencyExit",
      "disarmEmergencyExit",
      "emergencyExitAllToBootstrapRecipient",
      "sweepIdleToBootstrapRecipient"
    ]))
    then (.manager | nzaddress)
    else true
    end
  )
  and (
    if ($op | oneof(["setOfficialProposal", "setProposalValidationConfig"]))
    then (.proposalSource | nzaddress)
    else true
    end
  )
  and (
    if ($op | oneof(["initializeFromBootstrap", "depositToSpot"]))
    then
      (.companyToken | nzaddress)
      and (.companyAmount | positive)
      and fundingstrict
      and addstrict(.spotAdd)
    else true
    end
  )
  and (
    if $op == "sync"
    then
      addstrict(.spotAdd)
      and exitstrict(.spotExit)
      and addstrict(.yesAdd)
      and addstrict(.noAdd)
      and exitstrict(.yesExit)
      and exitstrict(.noExit)
    else true
    end
  )
  and (
    if $op == "redeem"
    then
      (.shares | positive)
      and (.recipient | nzaddress)
      and exitstrict(.spotExit)
      and exitstrict(.yesExit)
      and exitstrict(.noExit)
    else true
    end
  )
  and (
    if $op == "emergencyExitAllToBootstrapRecipient"
    then
      exitstrict(.spotExit)
      and exitstrict(.yesExit)
      and exitstrict(.noExit)
    else true
    end
  )
  and (
    if $op == "setOfficialProposal"
    then
      (.proposalId | positive)
      and (.proposal | nzaddress)
      and (.creator | nzaddress)
    else true
    end
  )
  and (
    if $op == "setProposalValidationConfig"
    then validationstrict
    else true
    end
  )
'

if [[ ${#DEPLOY_FILES[@]} -gt 0 ]]; then
  for file in "${DEPLOY_FILES[@]}"; do
    require_jq "$file" "$deploy_schema_filter" "deployment config schema is invalid"
    if [[ "$ALLOW_PLACEHOLDERS" == false ]]; then
      require_jq "$file" "$deploy_strict_filter" \
        "strict deployment config must use nonzero production addresses and enabled proposal validation"
    fi
    echo "deployment config validation passed: $file"
  done
fi

if [[ ${#BATCH_FILES[@]} -gt 0 ]]; then
  for file in "${BATCH_FILES[@]}"; do
    require_jq "$file" "$batch_schema_filter" "batch config schema is invalid"
    if [[ "$ALLOW_PLACEHOLDERS" == false ]]; then
      require_jq "$file" "$batch_strict_filter" \
        "strict batch config must use real targets, amounts, deadlines, and slippage minimums"
    fi
    echo "batch config validation passed: $file"
  done
fi
