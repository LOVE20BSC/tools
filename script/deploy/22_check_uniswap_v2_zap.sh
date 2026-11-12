#!/usr/bin/env bash
set -euo pipefail

# Independent check (UniswapV2Zap module): read-only over config and chain state, repeatable. Loads
# its own check inputs instead of relying on a preloaded environment: network.params provides RPC and
# chain ID, uniswap-v2-zap.params the module parameters, addresses.uniswapv2.params the copied
# cross-repository Router record, and addresses.uniswap-v2-zap.params the address to verify.
# The address files' key sets are asserted before any chain call: a renamed key would leave the
# variable silently empty and fail much later with an unhelpful message.
# The three bindings are re-derived from the Router rather than trusted: the zap caches factory and
# WETH at construction time, and a wrong Router produces a wrong-but-deployed zap that nothing else
# would notice (dev-standards §5.7: 2x re-checks, it never re-implements the deploy-time checks).
# Usage: script/deploy/22_check_uniswap_v2_zap.sh <network>

network="${1:?usage: script/deploy/22_check_uniswap_v2_zap.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$TOOLS_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params uniswap-v2-zap.params addresses.uniswapv2.params addresses.uniswap-v2-zap.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/uniswap-v2-zap.params" \
    "$NETWORK_DIR/addresses.uniswapv2.params" "$NETWORK_DIR/addresses.uniswap-v2-zap.params"

assert_key_set() {
    local address_file="$1"
    local expected_keys="$2"
    local actual_keys
    actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
    if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
        echo "Error: $address_file key set mismatch"
        echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
        echo "  actual:   $actual_keys"
        exit 1
    fi
}
assert_key_set "$NETWORK_DIR/addresses.uniswapv2.params" "FACTORY_ADDRESS ROUTER_ADDRESS"
assert_key_set "$NETWORK_DIR/addresses.uniswap-v2-zap.params" "UNISWAP_V2_ZAP_ADDRESS"

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/uniswap-v2-zap.params"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/addresses.uniswap-v2-zap.params"

# A missing, malformed or zero address must fail here: continuing would report "not deployed" and
# hide the real cause. The predicate matches 32_verify_uniswap_v2_zap.sh and 12_deploy_uniswap_v2_zap.sh.
if [[ ! "${UNISWAP_V2_ZAP_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || [[ "${UNISWAP_V2_ZAP_ADDRESS:-}" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: UNISWAP_V2_ZAP_ADDRESS is missing or invalid in $NETWORK_DIR/addresses.uniswap-v2-zap.params; run one_click_deploy_uniswap_v2_zap.sh first"
    exit 1
fi

ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

FAILED=0

# Helper: compare one on-chain value against the expected one. Addresses compare case-insensitively,
# integers are compared verbatim (cast prints a uint256 in decimal, with an optional [1eN] marker).
normalize_output() {
    local value="$1"
    value="${value%\"}"
    value="${value#\"}"
    value="${value% \[*\]}"
    echo "$value"
}

verify_value() {
    local field_name=$1
    local expected
    local actual
    expected=$(normalize_output "$2")
    actual=$(normalize_output "$3")

    if [[ "$expected" =~ ^0x[0-9a-fA-F]{40}$ && "$actual" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
        actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
    fi


    # A failed `cast call` falls back to the ERROR sentinel. Two failed reads compare equal to each
    # other, so verifying before rejecting the sentinel would let a run where both sides of the
    # comparison are unreadable report success -- which is the one case this check exists to catch.
    if [ "$expected" = "ERROR" ] || [ "$actual" = "ERROR" ]; then
        echo "✗ $field_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        echo "    cause: at least one side could not be read"
        return 1
    fi

    if [ "$expected" = "$actual" ]; then
        echo "✓ $field_name = $actual"
        return 0
    fi
    echo "✗ $field_name"
    echo "    contract: $UNISWAP_V2_ZAP_ADDRESS"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    return 1
}

echo "=== Verifying UniswapV2Zap on $network ==="
echo "  UNISWAP_V2_ZAP_ADDRESS: $UNISWAP_V2_ZAP_ADDRESS"
echo "  ROUTER_ADDRESS: $ROUTER_ADDRESS (from the copied dex address file)"

zap_code=$(cast code "$UNISWAP_V2_ZAP_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || zap_code=""
if [[ ! "$zap_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo "✗ UniswapV2Zap not deployed: $UNISWAP_V2_ZAP_ADDRESS"
    FAILED=$((FAILED + 1))
else
    echo "✓ UniswapV2Zap deployed"
fi

# The Router the zap binds is the one dex recorded: if dex was redeployed and the address file was
# copied without redeploying the zap, this is where it shows up.
if [ "$FAILED" -eq 0 ]; then
    ACTUAL_ROUTER=$(cast call "$UNISWAP_V2_ZAP_ADDRESS" "ROUTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "ROUTER()" "$ROUTER_ADDRESS" "$ACTUAL_ROUTER" || FAILED=$((FAILED + 1))
fi

# factory() and wrappedNativeToken() are cached at construction time; re-derive both from the Router
# on chain instead of comparing them with the same copied file, so a stale Router record or a zap
# deployed against a different Router both fail here.
if [ "$FAILED" -eq 0 ]; then
    ACTUAL_FACTORY=$(cast call "$UNISWAP_V2_ZAP_ADDRESS" "FACTORY()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    ROUTER_FACTORY=$(cast call "$ROUTER_ADDRESS" "factory()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "FACTORY()" "$ROUTER_FACTORY" "$ACTUAL_FACTORY" || FAILED=$((FAILED + 1))
    verify_value "factory() matches the copied dependency record" "$FACTORY_ADDRESS" "$ACTUAL_FACTORY" || FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -eq 0 ]; then
    ACTUAL_WETH=$(cast call "$UNISWAP_V2_ZAP_ADDRESS" "WRAPPED_NATIVE_TOKEN()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    ROUTER_WETH=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "WRAPPED_NATIVE_TOKEN()" "$ROUTER_WETH" "$ACTUAL_WETH" || FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "✗ $FAILED verification(s) failed"
    exit 1
fi
echo "✓ UniswapV2Zap verified"
