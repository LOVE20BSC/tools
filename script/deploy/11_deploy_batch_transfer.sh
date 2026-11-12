#!/usr/bin/env bash
set -euo pipefail

# Step 1 (BatchTransfer module): deploy the contract. Self-contained: loads and validates every
# file it needs, without relying on a preloaded caller environment.
# BatchTransfer has no constructor parameters and no init entry, so there is no module parameter to
# read; batch-transfer.params exists only to keep every module the same shape under
# script/network/<network>/, and is loaded so a parameter added later needs no new file.
# Deployment-time static checks (chain ID, code presence, code hash against the local build) happen
# inside DeployBatchTransfer.s.sol; this step only orchestrates files, chain, account and password.
# Addresses are written to addresses.batch-transfer.params for 21_check_batch_transfer.sh and
# 31_verify_batch_transfer.sh.
# Usage: script/deploy/11_deploy_batch_transfer.sh <network>

network="${1:?usage: script/deploy/11_deploy_batch_transfer.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$TOOLS_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# An abnormal previous exit may leave a hidden address temp file behind; only this module's temp
# pattern is removed, never the real address file.
rm -f "$NETWORK_DIR/.addresses.batch-transfer.params."*

# Required configuration. .account provides the keystore account and password and is mandatory
# (local chains also sign through the keystore, never --unlocked).
for config in network.params batch-transfer.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/batch-transfer.params"

env_password="${KEYSTORE_PASSWORD:-}"
params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/batch-transfer.params"
# .account is plain-sourced: the password may contain "#" and must not go through parameter expansion.
set -a
source "$NETWORK_DIR/.account"
set +a

# An empty KEYSTORE_PASSWORD line in .account must not clear a password exported by the entrypoint
# (that would prompt a second time).
[ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

# Verify the actual chain; being able to reach the RPC is not enough.
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

# Keystore password: no prompt when already set (non-interactive use), otherwise read via the macOS
# dialog.
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
fi

echo "=== Deploying BatchTransfer to $network ==="
echo "  RPC_URL: $RPC_URL"
echo "  CHAIN_ID: $CHAIN_ID"
echo "  BatchTransfer has no constructor parameters"

# Prepare the deployment log and the password file. Once broadcast, any later validation failure
# means "the contract is on chain but the address was not recorded": the log and the artifact path
# must survive for manual recovery; a pre-broadcast failure only removes this run's temp files and
# never claims anything reached the chain. The password goes to forge through a temp file because
# --password would put the plaintext into the process arguments, readable by every local user. The
# trap is installed before the password is written, so a failing chmod/printf leaks nothing.
DEPLOY_LOG=$(mktemp)
PASSWORD_FILE=$(mktemp)
ADDRESS_TMP="$NETWORK_DIR/.addresses.batch-transfer.params.$$"
DEPLOY_SAVED=0
DEPLOY_ATTEMPTED=0
trap 'rm -f "$ADDRESS_TMP" "$PASSWORD_FILE"
if [ "$DEPLOY_SAVED" = 1 ] || [ "$DEPLOY_ATTEMPTED" = 0 ]; then
    rm -f "$DEPLOY_LOG"
else
    echo "  Address was not saved; the contract may already be on chain." >&2
    echo "  Deployment log: $DEPLOY_LOG" >&2
    echo "  Broadcast artifact: $TOOLS_ROOT/broadcast/DeployBatchTransfer.s.sol/${CHAIN_ID:-unknown}/run-latest.json" >&2
fi' EXIT
chmod 600 "$PASSWORD_FILE"
printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

# Build the forge script command: keystore signing (same on local chains, never --unlocked).
FORGE_CMD=(forge script script/deploy/DeployBatchTransfer.s.sol:DeployBatchTransfer --sig "run()" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" --password-file "$PASSWORD_FILE" --broadcast --slow -vvv)

# Run the deployment.
cd "$TOOLS_ROOT"
DEPLOY_START_EPOCH_SECONDS=$(date +%s)
DEPLOY_ATTEMPTED=1
if ! { "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; }; then
    echo "Error: Deployment failed."
    exit 1
fi
# The password is only needed for this forge call; delete it right after broadcast to shorten the
# exposure window.
rm -f "$PASSWORD_FILE"

# Extract the address from the deployment output (_logDeploymentSummary in DeployBatchTransfer.s.sol).
# A non-matching grep would silently abort the pipeline under set -e, so the lookup tolerates failure
# and a missing entry is reported explicitly.
BATCH_TRANSFER_ADDRESS=$(grep "BATCH_TRANSFER_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
if [[ ! "$BATCH_TRANSFER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || [[ "$BATCH_TRANSFER_ADDRESS" = 0x0000000000000000000000000000000000000000 ]]; then
    echo "Error: Missing or invalid BATCH_TRANSFER_ADDRESS in the deployment log"
    exit 1
fi

# The artifact must come from this run: a stale file would let a failed deployment look successful.
BROADCAST_FILE="$TOOLS_ROOT/broadcast/DeployBatchTransfer.s.sol/$CHAIN_ID/run-latest.json"
if [ ! -f "$BROADCAST_FILE" ]; then
    echo "Error: Missing broadcast artifact: $BROADCAST_FILE"
    exit 1
fi
BROADCAST_TIMESTAMP_MS=$(sed -nE 's/.*"timestamp":[[:space:]]*([0-9]+).*/\1/p' "$BROADCAST_FILE" | tail -1)
if [ -z "$BROADCAST_TIMESTAMP_MS" ] || [ "$BROADCAST_TIMESTAMP_MS" -lt "$((DEPLOY_START_EPOCH_SECONDS * 1000))" ]; then
    echo "Error: Broadcast artifact was not updated by this deployment: $BROADCAST_FILE"
    exit 1
fi

# Write the address file only after every check passed: a temp file in the same directory plus mv
# keeps the previous record intact when anything fails before this point.
printf 'BATCH_TRANSFER_ADDRESS=%s\n' "$BATCH_TRANSFER_ADDRESS" > "$ADDRESS_TMP"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.batch-transfer.params"

DEPLOY_SAVED=1
echo "✓ BatchTransfer: $BATCH_TRANSFER_ADDRESS"
echo "✓ Deployment completed and address saved"
