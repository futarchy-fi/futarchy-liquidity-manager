#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if ! command -v jq >/dev/null 2>&1; then
  echo "limited preflight check failed: jq is required" >&2
  exit 1
fi

OUT_DIR="out/preflight-check"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

DEPLOY_CONFIG="$OUT_DIR/deploy.json"
DEPLOYMENT_OUTPUT="$OUT_DIR/deployment-output.json"
BATCH_CONFIG="$OUT_DIR/bootstrap.json"
BAD_BATCH_CONFIG="$OUT_DIR/bootstrap-bad-manager.json"
LOG_FILE="$OUT_DIR/no-proposal.log"
BAD_LINK_LOG_FILE="$OUT_DIR/bad-link.log"

jq '
  .owner = "0x1111111111111111111111111111111111111111"
  | .bootstrapRecipient = "0x2222222222222222222222222222222222222222"
  | .companyToken = "0x3333333333333333333333333333333333333333"
  | .officialProposer = "0x4444444444444444444444444444444444444444"
  | .deployDeadlineProxy = false
  | .validation.enabled = true
  | .validation.expectedProposalToken = "0x5555555555555555555555555555555555555555"
  | .validation.expectedCollateralToken = "0x6666666666666666666666666666666666666666"
  | .validation.trustedOracle = "0x7777777777777777777777777777777777777777"
  | .validation.realitio = "0x8888888888888888888888888888888888888888"
  | .validation.trustedArbitrator = "0x9999999999999999999999999999999999999999"
  | .validation.maxMinBond = 1
' config/gnosis.example.json > "$DEPLOY_CONFIG"

jq -n '
  {
    chainId: 100,
    owner: "0x1111111111111111111111111111111111111111",
    bootstrapRecipient: "0x2222222222222222222222222222222222222222",
    companyToken: "0x3333333333333333333333333333333333333333",
    wrappedNative: "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d",
    officialProposer: "0x4444444444444444444444444444444444444444",
    proposalSource: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    deadlineProxy: "0x0000000000000000000000000000000000000000",
    spotAdapter: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    conditionalAdapter: "0xcccccccccccccccccccccccccccccccccccccccc",
    manager: "0xdddddddddddddddddddddddddddddddddddddddd"
  }
' > "$DEPLOYMENT_OUTPUT"

jq '
  .createdFromSafeAddress = "0x2222222222222222222222222222222222222222"
  | .createdFromOwnerAddress = "0x1111111111111111111111111111111111111111"
  | .manager = "0xdddddddddddddddddddddddddddddddddddddddd"
  | .proposalSource = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  | .companyToken = "0x3333333333333333333333333333333333333333"
  | .companyAmount = 1000
  | .nativeValue = 1000
  | .recipient = "0x6666666666666666666666666666666666666666"
  | .proposal = "0x7777777777777777777777777777777777777777"
  | .creator = "0x8888888888888888888888888888888888888888"
  | .spotAdd.amount0Min = 1
  | .spotAdd.amount1Min = 1
  | .spotAdd.deadline = 1999999999
  | .validation.enabled = true
  | .validation.expectedProposalToken = "0x9999999999999999999999999999999999999999"
  | .validation.expectedCollateralToken = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  | .validation.trustedOracle = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  | .validation.realitio = "0xcccccccccccccccccccccccccccccccccccccccc"
  | .validation.trustedArbitrator = "0xdddddddddddddddddddddddddddddddddddddddd"
  | .validation.maxMinBond = 1
' config/batches/bootstrap.example.json > "$BATCH_CONFIG"

jq '.manager = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  "$BATCH_CONFIG" > "$BAD_BATCH_CONFIG"

FLM_BATCH_TEMPLATE_CHECK_OUT="$OUT_DIR/generated" \
  bash tools/preflight-limited-deploy.sh \
    --deploy "$DEPLOY_CONFIG" \
    --deployment-output "$DEPLOYMENT_OUTPUT" \
    --batch "$BATCH_CONFIG"

if bash tools/check-deployment-artifacts.sh \
  --deploy "$DEPLOY_CONFIG" \
  --deployment-output "$DEPLOYMENT_OUTPUT" \
  --batch "$BAD_BATCH_CONFIG" >"$BAD_LINK_LOG_FILE" 2>&1; then
  echo "limited preflight check failed: deployment link check passed with bad manager" >&2
  exit 1
fi

grep -q 'manager mismatch' "$BAD_LINK_LOG_FILE"

if FLM_BATCH_TEMPLATE_CHECK_OUT="$OUT_DIR/generated-no-proposal" \
  bash tools/preflight-limited-deploy.sh \
    --deploy "$DEPLOY_CONFIG" \
    --deployment-output "$DEPLOYMENT_OUTPUT" \
    --batch "$BATCH_CONFIG" \
    --run-fork-tests >"$LOG_FILE" 2>&1; then
  echo "limited preflight check failed: fork preflight passed without final proposal" >&2
  exit 1
fi

grep -q -- '--run-fork-tests requires --proposal <nonzero address> or a setOfficialProposal batch' \
  "$LOG_FILE"

echo "limited preflight check passed"
