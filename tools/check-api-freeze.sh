#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

check_contract() {
  local name="$1"
  local contract="$2"
  local baseline="audit/api-freeze/${name}.method-identifiers.json"
  local generated="${TMP_DIR}/${name}.method-identifiers.json"

  forge inspect --json "$contract" methodIdentifiers > "$generated"
  if ! diff -u "$baseline" "$generated"; then
    echo "API freeze guard failed for ${name}" >&2
    echo "If this API change is intentional, review it and update ${baseline}." >&2
    exit 1
  fi
}

check_contract \
  "FutarchyLiquidityManager" \
  "src/core/FutarchyLiquidityManager.sol:FutarchyLiquidityManager"
check_contract \
  "FutarchyOfficialProposalSource" \
  "src/sources/FutarchyOfficialProposalSource.sol:FutarchyOfficialProposalSource"
check_contract \
  "DeadlineBoundedRealityProxy" \
  "src/oracles/DeadlineBoundedRealityProxy.sol:DeadlineBoundedRealityProxy"
check_contract \
  "AlgebraPoolStabilityGuard" \
  "src/oracles/AlgebraPoolStabilityGuard.sol:AlgebraPoolStabilityGuard"
check_contract \
  "SwaprAlgebraLiquidityAdapter" \
  "src/adapters/SwaprAlgebraLiquidityAdapter.sol:SwaprAlgebraLiquidityAdapter"
check_contract \
  "FutarchyLiquidityManagerFactory" \
  "src/factories/FutarchyLiquidityManagerFactory.sol:FutarchyLiquidityManagerFactory"
check_contract \
  "UniswapV3LiquidityAdapter" \
  "src/adapters/UniswapV3LiquidityAdapter.sol:UniswapV3LiquidityAdapter"
check_contract \
  "V4InitializationGate" \
  "src/adapters/V4InitializationGate.sol:V4InitializationGate"
check_contract \
  "UniV3PoolStabilityGuard" \
  "src/oracles/UniV3PoolStabilityGuard.sol:UniV3PoolStabilityGuard"
check_contract \
  "FutarchyConditionalRouter" \
  "src/routers/FutarchyConditionalRouter.sol:FutarchyConditionalRouter"

echo "API freeze guard passed"
