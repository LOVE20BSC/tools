#!/usr/bin/env bash
set -euo pipefail

# Step 3 (UniswapV2Zap module): source verification. Self-contained: loads network.params,
# verifier.params, the copied dex Router record and the address file written by the last
# deployment, without relying on the entrypoint to refresh addresses.
# The step returns success when the chain is listed in VERIFY_SKIP_CHAIN_IDS.
# The zap's constructor takes one address, so --constructor-args must carry the ABI-encoded Router:
# a zap verified without it (or with another Router) would publish source that does not reproduce
# the deployed bytecode.
# Usage: script/deploy/32_verify_uniswap_v2_zap.sh <network>

network="${1:?usage: script/deploy/32_verify_uniswap_v2_zap.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$TOOLS_ROOT/script/network/$network"
VERIFIER_PARAMS="$TOOLS_ROOT/script/network/verifier.params"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.uniswapv2.params addresses.uniswap-v2-zap.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done
if [ ! -f "$VERIFIER_PARAMS" ]; then
    echo "Error: Missing required configuration: $VERIFIER_PARAMS"
    exit 1
fi

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$VERIFIER_PARAMS" \
    "$NETWORK_DIR/addresses.uniswapv2.params" "$NETWORK_DIR/addresses.uniswap-v2-zap.params"

params_load "$NETWORK_DIR/network.params"
params_load "$VERIFIER_PARAMS"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/addresses.uniswap-v2-zap.params"

cd "$TOOLS_ROOT"

# The opt-out list is mandatory as a key but may be empty: "verify every chain" is a legal answer.
params_require_keys "$VERIFIER_PARAMS" VERIFY_SKIP_CHAIN_IDS || exit 1

# Verification is attempted by default: only the chains listed here skip it, so a new production
# chain fails loudly instead of passing unverified.
skip_chains=",${VERIFY_SKIP_CHAIN_IDS:-},"
if [ -n "${CHAIN_ID:-}" ] && [[ "$skip_chains" == *",$CHAIN_ID,"* ]]; then
    echo "Skip: source verification is disabled for chain $CHAIN_ID in $VERIFIER_PARAMS"
    exit 0
fi

# The endpoint is a mandatory key: an empty URL would be passed straight to forge.
params_require_values "$VERIFIER_PARAMS" ETHERSCAN_VERIFIER_URL || exit 1

if [[ ! "${UNISWAP_V2_ZAP_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || [[ "${UNISWAP_V2_ZAP_ADDRESS:-}" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: UNISWAP_V2_ZAP_ADDRESS is missing or invalid in $NETWORK_DIR/addresses.uniswap-v2-zap.params"
    exit 1
fi
if [[ ! "${ROUTER_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || [[ "${ROUTER_ADDRESS:-}" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: ROUTER_ADDRESS is missing or invalid in $NETWORK_DIR/addresses.uniswapv2.params"
    exit 1
fi
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

# The constructor is `constructor(address routerAddress)`, so the single argument is ABI-encoded as
# one left-padded 32-byte word. `cast abi-encode` produces exactly that and fails loudly on a
# malformed address, which keeps the encoding out of hand-written concatenation.
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$ROUTER_ADDRESS")

forge verify-contract "$UNISWAP_V2_ZAP_ADDRESS" "src/UniswapV2Zap.sol:UniswapV2Zap" \
    --chain "$CHAIN_ID" --verifier etherscan --verifier-url "$ETHERSCAN_VERIFIER_URL" \
    --constructor-args "$CONSTRUCTOR_ARGS" --watch
echo "✓ Source verification succeeded for UniswapV2Zap"
