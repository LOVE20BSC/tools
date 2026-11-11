#!/usr/bin/env bash
set -euo pipefail

# UniswapV2Zap module entrypoint: orchestration only. It sources no environment file itself - each
# step loads its own inputs, every step is invoked the same way (<step>.sh <network>), and steps
# never call each other nor depend on a preloaded environment.
# tools is a multi-tool repository, so every tool gets its own entrypoint
# (one_click_deploy_<tool>.sh) plus its own NN_*_<tool>.sh step scripts; the BatchTransfer files stay
# untouched. This entrypoint does not deploy the Router it wraps: that is `dex`'s module, and the
# dependency arrives as the copied addresses.uniswapv2.params (dev-standards §6.2). A future tool
# that needs the zap deployed first copies its address file, it does not call this entrypoint.
# Usage: script/deploy/one_click_deploy_uniswap_v2_zap.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Run from the project root.
cd "$TOOLS_ROOT"

network="${1:?usage: script/deploy/one_click_deploy_uniswap_v2_zap.sh <network>}"

NETWORK_DIR="$TOOLS_ROOT/script/network/$network"
if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# The keystore password is resolved once per run: reset first (never inherit a value left over in
# the caller's environment, which would silently reuse the previous run's password), then read the
# password line from .account; if neither exists, prompt once and export it so every deployment step
# reuses it. A step run on its own still resolves it as environment -> .account -> prompt. The
# entrypoint only reads the password line and never sources the config file.
export KEYSTORE_PASSWORD=""
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account"
    exit 1
fi
configured_password=$(grep -E '^KEYSTORE_PASSWORD=' "$NETWORK_DIR/.account" | tail -1 | cut -d= -f2- || true)
if [ -n "$configured_password" ]; then
    export KEYSTORE_PASSWORD="$configured_password"
fi
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for deployment:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
    export KEYSTORE_PASSWORD
fi

# Deployment and checking are separate steps: a failed check must not overwrite the previously saved
# address. Back it up first, drop the backup once the check passes, restore it on failure.
ADDRESS_FILE="$NETWORK_DIR/addresses.uniswap-v2-zap.params"
BACKUP_FILE="$(mktemp)"
RESTORE_TMP="$ADDRESS_FILE.restore.$$"
trap 'rm -f "$BACKUP_FILE" "$RESTORE_TMP"' EXIT
had_address_file=0
if [ -f "$ADDRESS_FILE" ]; then
    cp "$ADDRESS_FILE" "$BACKUP_FILE"
    had_address_file=1
fi

# Step 1: deploy the contract (loads its own deployment inputs). The address file is written only
# after every check passes, but an already broadcast contract cannot be rolled back: after a
# post-broadcast failure, recover the record from the log and the broadcast artifact that
# 12_deploy_uniswap_v2_zap.sh prints.
bash "$SCRIPT_DIR/12_deploy_uniswap_v2_zap.sh" "$network"

# Step 2: verify the deployment (loads its own check inputs, restores the saved address on failure).
if ! bash "$SCRIPT_DIR/22_check_uniswap_v2_zap.sh" "$network"; then
    echo "Error: post-deployment check failed."
    if [ -f "$ADDRESS_FILE" ]; then
        echo "New deployment address (may already be on chain):"
        sed 's/^/  /' "$ADDRESS_FILE"
    fi
    echo "  Broadcast artifact: $TOOLS_ROOT/broadcast/DeployUniswapV2Zap.s.sol/<chain-id>/run-latest.json"
    if [ "$had_address_file" = 1 ]; then
        if ! cp "$BACKUP_FILE" "$RESTORE_TMP"; then
            echo "Error: failed to stage the previous address; $ADDRESS_FILE still holds the new deployment." >&2
            exit 1
        fi
        mv "$RESTORE_TMP" "$ADDRESS_FILE"
        echo "The previously saved address was restored."
    else
        rm -f "$ADDRESS_FILE"
        echo "No previous address file existed; the new address file was removed."
    fi
    exit 1
fi

# Step 3: source verification (loads the address files itself). Skips itself when the chain has no
# source verification.
bash "$SCRIPT_DIR/32_verify_uniswap_v2_zap.sh" "$network"

echo "✓ Deployment completed: $network"
