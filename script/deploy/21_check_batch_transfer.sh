#!/usr/bin/env bash
set -euo pipefail

# Independent check (BatchTransfer module): read-only over config and chain state, repeatable. Loads
# its own check inputs instead of relying on a preloaded environment: network.params provides RPC and
# chain ID, batch-transfer.params carries the module parameters (none today, but the file is loaded
# so the step fails loudly if it disappears), and addresses.batch-transfer.params the address to
# verify.
# The address file's key set is asserted before any chain call: a renamed key would leave the
# variable silently empty and fail much later with an unhelpful message.
# Usage: script/deploy/21_check_batch_transfer.sh <network>

network="${1:?usage: script/deploy/21_check_batch_transfer.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$TOOLS_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params batch-transfer.params addresses.batch-transfer.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/batch-transfer.params" \
    "$NETWORK_DIR/addresses.batch-transfer.params"

address_file="$NETWORK_DIR/addresses.batch-transfer.params"
expected_keys="BATCH_TRANSFER_ADDRESS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch"
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
    echo "  actual:   $actual_keys"
    exit 1
fi

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/batch-transfer.params"
params_load "$NETWORK_DIR/addresses.batch-transfer.params"

# A missing, malformed or zero address must fail here: continuing would report "not deployed" and
# hide the real cause. The predicate matches 31_verify_batch_transfer.sh and 11_deploy_batch_transfer.sh.
if [[ ! "${BATCH_TRANSFER_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || [[ "${BATCH_TRANSFER_ADDRESS:-}" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: BATCH_TRANSFER_ADDRESS is missing or invalid in $address_file; run one_click_deploy_batch_transfer.sh first"
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

    if [ "$expected" = "$actual" ]; then
        echo "✓ $field_name = $actual"
        return 0
    fi
    echo "✗ $field_name"
    echo "    contract: $BATCH_TRANSFER_ADDRESS"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    return 1
}

echo "=== Verifying BatchTransfer on $network ==="
echo "  BATCH_TRANSFER_ADDRESS: $BATCH_TRANSFER_ADDRESS"

batch_transfer_code=$(cast code "$BATCH_TRANSFER_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null) || batch_transfer_code=""
if [[ ! "$batch_transfer_code" =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo "✗ BatchTransfer not deployed: $BATCH_TRANSFER_ADDRESS"
    FAILED=$((FAILED + 1))
else
    echo "✓ BatchTransfer deployed"
fi

# The gas budget per native transfer is the only deployment-time constant the contract exposes, and
# it is a hard-coded constant rather than a constructor argument: read it back so a source change
# that silently alters it cannot pass the check.
if [ "$FAILED" -eq 0 ]; then
    ACTUAL_GAS_LIMIT=$(cast call "$BATCH_TRANSFER_ADDRESS" "NATIVE_TRANSFER_GAS_LIMIT()(uint256)" \
        --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
    verify_value "NATIVE_TRANSFER_GAS_LIMIT" "50000" "$ACTUAL_GAS_LIMIT" || FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "✗ $FAILED verification(s) failed"
    exit 1
fi
echo "✓ BatchTransfer verified"
