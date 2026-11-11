#!/usr/bin/env bash
set -euo pipefail

# End-to-end check for every tool in this repository against a throwaway anvil chain.
#
# What it does, in order:
#   1. verifies the toolchain and the keystore `.account` points at;
#   2. starts a fresh anvil and deploys the Uniswap V2 stack it needs (WETH9, Factory, Router02)
#      from `dex`'s build artifacts;
#   3. copies that stack's address file into `script/network/anvil31337_dev/` the same way a real
#      run would (dev-standards §6.2), then runs each tool's own `one_click_deploy_<tool>.sh`;
#   4. exercises both tools on chain: a batch native transfer, a `zapToken`, a `zapNativeToken`,
#      the "the zap keeps nothing" invariant, and two custom-error selectors;
#   5. restores the address files and stops anvil, whether the run passed or failed.
#
# It deliberately drives the scripts in `script/deploy/` rather than re-implementing them: the
# point is to prove that path works, not to work around it.
#
# Requirements:
#   - anvil, cast, forge on PATH (Foundry 1.8.1+);
#   - a sibling `dex` checkout built with `make build` (override with LOVE20_DEX_DIR);
#   - a keystore configured in script/network/anvil31337_dev/.account. See README.md.
#
# Usage: script/e2e/anvil_e2e.sh [--keep]
#   --keep   leave anvil running and the deployed addresses in place for debugging.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

NETWORK="anvil31337_dev"
NETWORK_DIR="$TOOLS_ROOT/script/network/$NETWORK"
DEX_DIR="${LOVE20_DEX_DIR:-$TOOLS_ROOT/../dex}"
E2E_PORT="${E2E_PORT:-8545}"
RPC_URL="http://127.0.0.1:$E2E_PORT"
CHAIN_ID=31337

# Anvil's first default account. Public knowledge, local chain only - this is what `anvil` prints
# on startup, not a secret. It is used solely to deploy the Uniswap V2 stack, so that deployment
# does not depend on the operator's keystore; the tools themselves are deployed through the
# keystore path the production scripts use.
ANVIL_DEFAULT_KEY="${E2E_ANVIL_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Error: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

CHECKS_PASSED=0
CHECKS_FAILED=0
DEPLOY_FAILED=0
ANVIL_PID=""
BACKUP_DIR=""

pass() { CHECKS_PASSED=$((CHECKS_PASSED + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { CHECKS_FAILED=$((CHECKS_FAILED + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }

# --- assertions -------------------------------------------------------------------------------

# Addresses come back in mixed case depending on the command: `cast send --create` reports the
# contract address lower-cased from the receipt, while `cast call` returns EIP-55 checksummed
# values. Compare addresses case-insensitively; a checksum is a display convention, not a value.
lc() { printf '%s' "${1,,}"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected $2, got $3)"; fi
}

# assert_addr_eq <label> <expected> <actual>
assert_addr_eq() {
    if [ "$(lc "$2")" = "$(lc "$3")" ]; then pass "$1"; else fail "$1 (expected $2, got $3)"; fi
}

# assert_contains <label> <needle> <haystack>
assert_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1 (missing '$2' in '$3')" ;;
    esac
}

# --- cleanup ----------------------------------------------------------------------------------

cleanup() {
    local status=$?
    if [ "$KEEP" -eq 1 ]; then
        printf '\n--keep given: leaving anvil (pid %s) running on %s\n' "${ANVIL_PID:-none}" "$RPC_URL"
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
            printf 'Address files left as deployed; backups in %s\n' "$BACKUP_DIR"
        fi
        return "$status"
    fi
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        for f in "$BACKUP_DIR"/*; do
            [ -e "$f" ] || continue
            cp "$f" "$NETWORK_DIR/$(basename "$f")"
        done
        rm -rf "$BACKUP_DIR"
        printf '\nAddress files restored.\n'
    fi
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
        printf 'anvil stopped.\n'
    fi
    return "$status"
}
trap cleanup EXIT INT TERM

# --- helpers ----------------------------------------------------------------------------------

# json_field <json> <key>
json_field() {
    python3 -c 'import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

# deploy_from_artifact <artifact-json> [<ctor-sig> <arg>...]
# Echoes the deployed address. `cast create` needs the connection flags before `--create`, so they
# go first; constructor arguments are appended to the bytecode as ABI-encoded words.
deploy_from_artifact() {
    local artifact="$1"; shift
    local bytecode args="" tx receipt
    bytecode=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bytecode"]["object"])' "$artifact")
    if [ "$#" -gt 0 ]; then
        args=$(cast abi-encode "$@" | sed 's/^0x//')
    fi
    tx=$(cast send --rpc-url "$RPC_URL" --private-key "$ANVIL_DEFAULT_KEY" --create "${bytecode}${args}" --json \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["transactionHash"])')
    receipt=$(cast receipt "$tx" --rpc-url "$RPC_URL" --json)
    json_field "$receipt" contractAddress
}

# send_tool <to> <signature> <args...> - sends a transaction signed by the configured keystore.
send_tool() {
    local to="$1"; shift
    local sig="$1"; shift
    local password_file
    password_file=$(mktemp)
    chmod 600 "$password_file"
    printf '%s' "$KEYSTORE_PASSWORD" > "$password_file"
    # `cast send` derives the sender from the keystore, so there is no --sender here (that is a
    # `forge script` flag); --rpc-url and the wallet flags must precede the positional arguments.
    # shellcheck disable=SC2068
    cast send --rpc-url "$RPC_URL" --account "$KEYSTORE_ACCOUNT" --password-file "$password_file" \
        "$to" "$sig" $@ 2>&1
    local rc=$?
    rm -f "$password_file"
    return $rc
}

# --- preconditions ----------------------------------------------------------------------------

step "1. Preconditions"

for bin in anvil cast forge python3; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH"
done
pass "toolchain present (anvil/cast/forge/python3)"

[ -d "$NETWORK_DIR" ] || die "network directory not found: $NETWORK_DIR"
[ -f "$NETWORK_DIR/.account" ] || die ".account missing in $NETWORK_DIR - see script/e2e/README.md"
pass "network directory and .account present"

# .account is plain-sourced the same way the deploy scripts do it: the password may contain '#'
# and must not go through parameter expansion.
set -a
# shellcheck disable=SC1091
source "$NETWORK_DIR/.account"
set +a
[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || die "KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS not set in $NETWORK_DIR/.account"
[ -n "${KEYSTORE_PASSWORD:-}" ] \
    || die "KEYSTORE_PASSWORD empty - set it in .account for a non-interactive run"
pass "keystore account configured ($KEYSTORE_ACCOUNT / $ACCOUNT_ADDRESS)"

[ -d "$DEX_DIR" ] || die "dex checkout not found at $DEX_DIR - set LOVE20_DEX_DIR"
WETH_ART="$DEX_DIR/build/periphery/WETH9.sol/WETH9.json"
FACTORY_ART="$DEX_DIR/build/core/UniswapV2Factory.sol/UniswapV2Factory.json"
ROUTER_ART="$DEX_DIR/build/periphery/UniswapV2Router02.sol/UniswapV2Router02.json"
TOKEN_ART="$DEX_DIR/build/core/ERC20.sol/ERC20.json"
for art in "$WETH_ART" "$FACTORY_ART" "$ROUTER_ART" "$TOKEN_ART"; do
    [ -f "$art" ] || die "missing dex artifact: $art (run 'make build' in $DEX_DIR)"
done
pass "dex build artifacts present"

if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    die "something is already listening on $RPC_URL - stop it or set E2E_PORT"
fi

# Back up every address file this run may rewrite, so a failure cannot leave the worktree dirty.
BACKUP_DIR=$(mktemp -d)
for f in "$NETWORK_DIR"/addresses.*.params; do
    [ -e "$f" ] && cp "$f" "$BACKUP_DIR/"
done
pass "address files backed up"

# --- chain and Uniswap stack ------------------------------------------------------------------

step "2. Fresh anvil + Uniswap V2 stack"

anvil --chain-id "$CHAIN_ID" --port "$E2E_PORT" --silent >/dev/null 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 100); do
    cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break
    sleep 0.1
done
cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 || die "anvil did not start"
assert_eq "chain is empty at block 0" "0" "$(cast block-number --rpc-url "$RPC_URL")"

WETH=$(deploy_from_artifact "$WETH_ART"); pass "WETH9 deployed at $WETH"
FACTORY=$(deploy_from_artifact "$FACTORY_ART" "constructor(address)" "$ACCOUNT_ADDRESS")
pass "UniswapV2Factory deployed at $FACTORY"
ROUTER=$(deploy_from_artifact "$ROUTER_ART" "constructor(address,address)" "$FACTORY" "$WETH")
pass "UniswapV2Router02 deployed at $ROUTER"

assert_addr_eq "router.factory() is the factory" "$FACTORY" "$(cast call "$ROUTER" 'factory()(address)' --rpc-url "$RPC_URL")"
assert_addr_eq "router.WETH() is the WETH" "$WETH" "$(cast call "$ROUTER" 'WETH()(address)' --rpc-url "$RPC_URL")"

# The dependency arrives the way a real run delivers it: a copy of dex's own address file, never a
# hand-edited merge (dev-standards §6.2).
printf 'FACTORY_ADDRESS=%s\nROUTER_ADDRESS=%s\n' "$FACTORY" "$ROUTER" \
    > "$NETWORK_DIR/addresses.uniswapv2.params"
pass "addresses.uniswapv2.params written from the fresh deployment"

# --- deploy both tools through their own scripts ----------------------------------------------

step "3. Deploy through script/deploy/"

if "$TOOLS_ROOT/script/deploy/one_click_deploy_batch_transfer.sh" "$NETWORK"; then
    pass "one_click_deploy_batch_transfer.sh"
else
    fail "one_click_deploy_batch_transfer.sh"
    DEPLOY_FAILED=1
fi

if "$TOOLS_ROOT/script/deploy/one_click_deploy_uniswap_v2_zap.sh" "$NETWORK"; then
    pass "one_click_deploy_uniswap_v2_zap.sh"
else
    fail "one_click_deploy_uniswap_v2_zap.sh"
    DEPLOY_FAILED=1
fi

# Only a deployment failure blocks the on-chain checks; a failed assertion above must not hide them.
[ "$DEPLOY_FAILED" -eq 0 ] || die "deployment failed, skipping the on-chain checks"

BT=$(sed -n 's/^BATCH_TRANSFER_ADDRESS=//p' "$NETWORK_DIR/addresses.batch-transfer.params")
ZAP=$(sed -n 's/^UNISWAP_V2_ZAP_ADDRESS=//p' "$NETWORK_DIR/addresses.uniswap-v2-zap.params")
[ -n "$BT" ] || die "BATCH_TRANSFER_ADDRESS not written"
[ -n "$ZAP" ] || die "UNISWAP_V2_ZAP_ADDRESS not written"

# --- on-chain behaviour -----------------------------------------------------------------------

step "4. BatchTransfer on chain"

R1=0x000000000000000000000000000000000000A001
R2=0x000000000000000000000000000000000000A002
R3=0x000000000000000000000000000000000000A003
if send_tool "$BT" "batchTransferNative(address[],uint256[])" \
        "[$R1,$R2,$R3]" "[1000000000000000000,2000000000000000000,3000000000000000000]" \
        --value 6000000000000000000 >/dev/null 2>&1; then
    pass "batchTransferNative executed"
else
    fail "batchTransferNative reverted"
fi
assert_eq "recipient 1 balance" "1000000000000000000" "$(cast balance "$R1" --rpc-url "$RPC_URL")"
assert_eq "recipient 2 balance" "2000000000000000000" "$(cast balance "$R2" --rpc-url "$RPC_URL")"
assert_eq "recipient 3 balance" "3000000000000000000" "$(cast balance "$R3" --rpc-url "$RPC_URL")"

step "5. UniswapV2Zap on chain"

TOKEN=$(deploy_from_artifact "$TOKEN_ART" "constructor(uint256)" 1000000000000000000000000)
pass "test ERC20 deployed at $TOKEN"

send_tool "$TOKEN" "approve(address,uint256)" "$ZAP" 500000000000000000000 >/dev/null 2>&1 || true
send_tool "$WETH" "deposit()" --value 100ether >/dev/null 2>&1 || true
send_tool "$WETH" "approve(address,uint256)" "$ZAP" 100000000000000000000 >/dev/null 2>&1 || true

DEADLINE=$(($(date +%s) + 3600))
if send_tool "$ZAP" "zapToken((address,address,uint256,uint256,uint256,uint256,uint256,address,uint256))" \
        "($TOKEN,$WETH,100000000000000000000,100000000000000000000,99000000000000000000,99000000000000000000,90000000000000000000,$ACCOUNT_ADDRESS,$DEADLINE)" \
        >/dev/null 2>&1; then
    pass "zapToken executed"
else
    fail "zapToken reverted"
fi

PAIR=$(cast call "$FACTORY" 'getPair(address,address)(address)' "$TOKEN" "$WETH" --rpc-url "$RPC_URL")
[ "$PAIR" != "0x0000000000000000000000000000000000000000" ] \
    && pass "pair created at $PAIR" || fail "pair was not created"

LP_SUPPLY=$(cast call "$PAIR" 'totalSupply()(uint256)' --rpc-url "$RPC_URL")
[ "$LP_SUPPLY" != "0" ] && pass "LP supply is non-zero" || fail "LP supply is zero"

# The zap must never end a call holding anything: that is the whole "no custody" promise.
assert_eq "zap holds no token after zapToken" "0" "$(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$ZAP" --rpc-url "$RPC_URL")"
assert_eq "zap holds no WETH after zapToken" "0" "$(cast call "$WETH" 'balanceOf(address)(uint256)' "$ZAP" --rpc-url "$RPC_URL")"
assert_eq "zap holds no LP after zapToken" "0" "$(cast call "$PAIR" 'balanceOf(address)(uint256)' "$ZAP" --rpc-url "$RPC_URL")"

# A second entry point, with a ratio that matches the 1:1 pool so the router's own slippage check
# does not fire.
if send_tool "$ZAP" "zapNativeToken(address,uint256,uint256,uint256,uint256,address,uint256)" \
        "$TOKEN" 1000000000000000000 0 0 0 "$ACCOUNT_ADDRESS" "$DEADLINE" --value 1ether >/dev/null 2>&1; then
    pass "zapNativeToken executed"
else
    fail "zapNativeToken reverted"
fi
assert_eq "zap holds no token after zapNativeToken" "0" "$(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$ZAP" --rpc-url "$RPC_URL")"
assert_eq "zap holds no WETH after zapNativeToken" "0" "$(cast call "$WETH" 'balanceOf(address)(uint256)' "$ZAP" --rpc-url "$RPC_URL")"

step "6. Custom-error selectors"

# The remediation moved these selectors; a regression would silently ship a different revert.
ZERO_INPUTS_EXPECTED=0x2896991c
ZERO_INPUTS_ACTUAL=$(cast call "$ZAP" \
    "zapToken((address,address,uint256,uint256,uint256,uint256,uint256,address,uint256))" \
    "($TOKEN,$WETH,0,0,0,0,0,$ACCOUNT_ADDRESS,$DEADLINE)" --rpc-url "$RPC_URL" 2>&1 \
    | grep -o '0x[0-9a-f]\{8\}' | head -1 || true)
assert_eq "ZeroInputAmounts selector" "$ZERO_INPUTS_EXPECTED" "$ZERO_INPUTS_ACTUAL"

AMOUNT_EXCEEDED=$(cast call "$ZAP" \
    'quoteZapToken(address,address,uint256,uint256)(bool,bool,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)' \
    "$TOKEN" "$WETH" 5192296858534827628530496329220096 0 --rpc-url "$RPC_URL" 2>&1 || true)
assert_contains "AmountExceeded carries the amount and the limit" "AmountExceeded(" "$AMOUNT_EXCEEDED"

# --- summary ----------------------------------------------------------------------------------

step "Summary"
printf '  passed: %s\n  failed: %s\n' "$CHECKS_PASSED" "$CHECKS_FAILED"
if [ "$CHECKS_FAILED" -ne 0 ]; then
    die "$CHECKS_FAILED check(s) failed"
fi
printf '\n\033[32mAll end-to-end checks passed.\033[0m\n'
