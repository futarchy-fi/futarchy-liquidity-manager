#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if ! command -v jq >/dev/null 2>&1; then
  echo "limited preflight check failed: jq is required" >&2
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "limited preflight check failed: cast is required" >&2
  exit 1
fi

OUT_DIR="out/preflight-check"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

DEPLOY_CONFIG="$OUT_DIR/deploy.json"
SIMULATED_DEPLOY_CONFIG="$OUT_DIR/deploy-simulated.json"
DEPLOYMENT_OUTPUT="$OUT_DIR/deployment-output.json"
BATCH_CONFIG="$OUT_DIR/bootstrap.json"
BAD_BATCH_CONFIG="$OUT_DIR/bootstrap-bad-manager.json"
BAD_PAIR_CONFIG="$OUT_DIR/deploy-identical-base.json"
BAD_VALIDATION_CONFIG="$OUT_DIR/deploy-bad-validation-pair.json"
LOG_FILE="$OUT_DIR/no-proposal.log"
BAD_LINK_LOG_FILE="$OUT_DIR/bad-link.log"
BAD_PAIR_LOG_FILE="$OUT_DIR/identical-base.log"
BAD_VALIDATION_LOG_FILE="$OUT_DIR/bad-validation-pair.log"
EOA_COORDINATOR_LOG_FILE="$OUT_DIR/eoa-coordinator.log"

jq '
  .organization = "0x1010101010101010101010101010101010101010"
  | .factory = "0xfafafafafafafafafafafafafafafafafafafafa"
  | .owner = "0x1111111111111111111111111111111111111111"
  | .proposalManager = "0x1212121212121212121212121212121212121212"
  | .bootstrapRecipient = "0x2222222222222222222222222222222222222222"
  | .companyToken = "0x3333333333333333333333333333333333333333"
  | .officialProposer = "0x4444444444444444444444444444444444444444"
  | .poolStabilityGuard = "0x4545454545454545454545454545454545454545"
  | .deployDeadlineProxy = false
  | .validation.enabled = true
  | .validation.expectedProposalToken = "0x3333333333333333333333333333333333333333"
  | .validation.expectedCollateralToken = .wrappedNative
  | .validation.trustedOracle = "0x7777777777777777777777777777777777777777"
  | .validation.realitio = "0x8888888888888888888888888888888888888888"
  | .validation.trustedArbitrator = "0x9999999999999999999999999999999999999999"
  | .validation.minConditionalLifetime = 86400
  | .validation.maxMinBond = 1
' config/gnosis.example.json > "$DEPLOY_CONFIG"

DEPLOY_CONFIG_HASH="$(cast keccak "0x$(od -An -tx1 -v "$DEPLOY_CONFIG" | tr -d ' \n')")"

jq -n --arg configHash "$DEPLOY_CONFIG_HASH" '
  {
    chainId: 100,
    configHash: $configHash,
    organization: "0x1010101010101010101010101010101010101010",
    factory: "0xfafafafafafafafafafafafafafafafafafafafa",
    owner: "0x1111111111111111111111111111111111111111",
    proposalManager: "0x1212121212121212121212121212121212121212",
    bootstrapRecipient: "0x2222222222222222222222222222222222222222",
    companyToken: "0x3333333333333333333333333333333333333333",
    wrappedNative: "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d",
    officialProposer: "0x4444444444444444444444444444444444444444",
    poolStabilityGuard: "0x4545454545454545454545454545454545454545",
    proposalSource: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    deadlineProxy: "0x0000000000000000000000000000000000000000",
    spotAdapter: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    conditionalAdapter: "0xcccccccccccccccccccccccccccccccccccccccc",
    manager: "0xdddddddddddddddddddddddddddddddddddddddd",
    factoryCodeHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    proposalSourceCreationCodeHash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    adapterCreationCodeHash: "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    managerCreationCodeHash: "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    proposalSourceCodeHash: "0x1111111111111111111111111111111111111111111111111111111111111111",
    deadlineProxyCodeHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
    spotAdapterCodeHash: "0x2222222222222222222222222222222222222222222222222222222222222222",
    conditionalAdapterCodeHash: "0x3333333333333333333333333333333333333333333333333333333333333333",
    managerCodeHash: "0x4444444444444444444444444444444444444444444444444444444444444444"
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
  | .validation.enabled = true
  | .validation.expectedProposalToken = "0x9999999999999999999999999999999999999999"
  | .validation.expectedCollateralToken = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  | .validation.trustedOracle = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  | .validation.realitio = "0xcccccccccccccccccccccccccccccccccccccccc"
  | .validation.trustedArbitrator = "0xdddddddddddddddddddddddddddddddddddddddd"
  | .validation.minConditionalLifetime = 86400
  | .validation.maxMinBond = 1
' config/batches/bootstrap.example.json > "$BATCH_CONFIG"

jq '.manager = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  "$BATCH_CONFIG" > "$BAD_BATCH_CONFIG"

jq '
  .companyToken = .wrappedNative
  | .validation.expectedProposalToken = .wrappedNative
' "$DEPLOY_CONFIG" > "$BAD_PAIR_CONFIG"

jq '.validation.expectedProposalToken = "0x5555555555555555555555555555555555555555"' \
  "$DEPLOY_CONFIG" > "$BAD_VALIDATION_CONFIG"

if bash tools/validate-configs.sh --deploy "$BAD_PAIR_CONFIG" \
  >"$BAD_PAIR_LOG_FILE" 2>&1; then
  echo "limited preflight check failed: config accepted identical base tokens" >&2
  exit 1
fi

grep -q 'strict deployment config' "$BAD_PAIR_LOG_FILE"

if bash tools/validate-configs.sh --deploy "$BAD_VALIDATION_CONFIG" \
  >"$BAD_VALIDATION_LOG_FILE" 2>&1; then
  echo "limited preflight check failed: config accepted mismatched validation tokens" >&2
  exit 1
fi

grep -q 'strict deployment config' "$BAD_VALIDATION_LOG_FILE"

FLM_BATCH_TEMPLATE_CHECK_OUT="$OUT_DIR/generated" \
  bash tools/preflight-limited-deploy.sh \
    --deploy "$DEPLOY_CONFIG" \
    --deployment-output "$DEPLOYMENT_OUTPUT" \
    --batch "$BATCH_CONFIG"

jq '.factory = "0x0000000000000000000000000000000000000000"' \
  "$DEPLOY_CONFIG" > "$SIMULATED_DEPLOY_CONFIG"

if PRIVATE_KEY=1 \
  FLM_DEPLOY_CONFIG="$SIMULATED_DEPLOY_CONFIG" \
  FLM_DEPLOY_OUTPUT="$OUT_DIR/unused-deployment-output.json" \
  forge script script/DeployFutarchyLiquidityManager.s.sol --chain-id 100 \
    >"$EOA_COORDINATOR_LOG_FILE" 2>&1;
then
  echo "limited preflight check failed: deploy accepted an EOA lifecycle coordinator" >&2
  exit 1
fi

grep -Eq \
  'proposalManager must be a contract|call to non-contract address 0x1212121212121212121212121212121212121212' \
  "$EOA_COORDINATOR_LOG_FILE"

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
