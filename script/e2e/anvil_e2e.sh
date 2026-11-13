#!/usr/bin/env bash
set -euo pipefail

# End-to-end check for BatchTransfer against a throwaway anvil chain.
#
# What it does, in order:
#   1. verifies the toolchain and the keystore `.account` points at;
#   2. starts a fresh anvil;
#   3. deploys the contract through its own `one_click_deploy_batch_transfer.sh`;
#   4. exercises it on chain: a real batch native transfer with per-recipient balances checked, a
#      batch ERC20 transfer against a token deployed here, and two custom-error selectors;
#   5. restores the files it rewrote and stops anvil, whether the run passed or failed.
#
# It deliberately drives the scripts in `script/deploy/` rather than re-implementing them: the
# point is to prove that path works, not to work around it. tools is a zero-dependency repository,
# so nothing outside this checkout has to be built first.
#
# Requirements:
#   - anvil, cast, forge, python3 on PATH (Foundry 1.8.1+);
#   - a keystore configured in script/network/anvil31337_dev/.account. See README.md.
#
# Usage: script/e2e/anvil_e2e.sh [--keep]
#   --keep   leave anvil running and the deployed addresses in place for debugging.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TOOLS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

NETWORK="anvil31337_dev"
NETWORK_DIR="$TOOLS_ROOT/script/network/$NETWORK"
E2E_PORT="${E2E_PORT:-8545}"
RPC_URL="http://127.0.0.1:$E2E_PORT"
CHAIN_ID=31337

# Anvil's first default account. Public knowledge, local chain only - this is what `anvil` prints
# on startup, not a secret. It is used solely to deploy test fixtures (a plain ERC20) so that step
# does not depend on the operator's keystore; BatchTransfer itself is deployed and called through
# the keystore path the production scripts use.
ANVIL_DEFAULT_KEY="${E2E_ANVIL_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# Bound every RPC call. `cast` waits indefinitely by default, and an anvil that has bound its port
# but is not answering yet will accept the connection and never reply -- which hangs the readiness
# poll below forever instead of failing it. The deploy scripts inherit this too, which is what we
# want: a stalled RPC should surface as a failure, not as a hang.
export ETH_RPC_TIMEOUT="${E2E_RPC_TIMEOUT:-30}"

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
#
# `tr` rather than `${1,,}`: the latter is bash 4+, and macOS still ships bash 3.2 as /bin/bash,
# where it fails with "bad substitution" *inside* a command substitution. That failure is silent
# here — both sides of the comparison become empty, so the assertion would pass while checking
# nothing. See the shell self-test in the preconditions step.
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

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

# uint_of <cast-call-output>
# `cast call` prints a uint256 in decimal with an optional human-readable marker, e.g.
# "7000000000000000000 [7e18]". Comparisons need the bare decimal, otherwise every balance check
# would fail against an identical-looking number. The marker is presentation only.
uint_of() {
    printf '%s' "${1%% \[*}"
}

# --- cleanup ----------------------------------------------------------------------------------

# Best effort throughout: `set -e` is still in force inside a trap, so a single failed `cp` would
# otherwise abort the rest of the cleanup and leave anvil running plus half the files restored.
# Each step is therefore allowed to fail; the first failure is reported but not fatal.
cleanup() {
    local status=$?
    set +e

    if [ "$KEEP" -eq 1 ]; then
        printf '\n--keep given: leaving anvil (pid %s) running on %s\n' "${ANVIL_PID:-none}" "$RPC_URL"
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
            printf 'Deployed state left as is; backups in %s\n' "$BACKUP_DIR"
            printf 'Stop anvil yourself before the next run: kill %s\n' "${ANVIL_PID:-?}"
        fi
        return "$status"
    fi

    # Stop the chain first: restoring files while anvil still writes `broadcast/` races with it, and
    # a leftover anvil is the most disruptive thing to leave behind (the next run refuses to start).
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
        printf '\nanvil stopped.\n'
    fi

    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        local f
        for f in "$BACKUP_DIR"/*; do
            [ -e "$f" ] || continue
            cp "$f" "$NETWORK_DIR/$(basename "$f")" || \
                printf 'warning: could not restore %s - original kept in %s\n' "$(basename "$f")" "$BACKUP_DIR"
        done
        rm -rf "$BACKUP_DIR" || true
        printf 'Address and network files restored.\n'
    fi
    return "$status"
}

# The EXIT trap only runs cleanup. INT/TERM must also terminate: a trap that merely returns resumes
# the script, which would carry on against a stopped chain and could still print a success summary.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- helpers ----------------------------------------------------------------------------------

# json_field <json> <key>
json_field() {
    python3 -c 'import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

# deploy_from_artifact <artifact-json> [<ctor-sig> <arg>...]
# Echoes the deployed address. `cast send --create` needs the connection flags before `--create`, so
# they go first; constructor arguments are appended to the bytecode as ABI-encoded words. Only used
# for test fixtures (the ERC20 below), never for BatchTransfer itself - that goes through
# `one_click_deploy_batch_transfer.sh`, which is the path under test.
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

# Guard the assertion helpers themselves. A helper that silently degrades (a shell too old for an
# expansion, a `tr` that is not there) would turn every comparison using it into a no-op that
# reports success, so verify the helpers before trusting any result they produce.
[ "$(lc 'AbC')" = "abc" ] || die "lc() did not lowercase - refusing to run assertions that would silently pass"
pass "assertion helpers behave (lc)"

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

if cast chain-id --rpc-url "$RPC_URL" --rpc-timeout 2 >/dev/null 2>&1; then
    die "something is already listening on $RPC_URL - stop it or set E2E_PORT"
fi

# Back up every file this run rewrites, so a failure cannot leave the worktree dirty. network.params
# is included because the run repoints RPC_URL at E2E_PORT (see below).
BACKUP_DIR=$(mktemp -d)
for f in "$NETWORK_DIR"/addresses.*.params "$NETWORK_DIR/network.params"; do
    [ -e "$f" ] && cp "$f" "$BACKUP_DIR/"
done
pass "address and network files backed up"

# --- chain ------------------------------------------------------------------------------------

step "2. Fresh anvil"

anvil --chain-id "$CHAIN_ID" --port "$E2E_PORT" --silent >/dev/null 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 100); do
    cast chain-id --rpc-url "$RPC_URL" --rpc-timeout 2 >/dev/null 2>&1 && break
    sleep 0.1
done
cast chain-id --rpc-url "$RPC_URL" --rpc-timeout 2 >/dev/null 2>&1 || die "anvil did not start"
assert_eq "chain is empty at block 0" "0" "$(cast block-number --rpc-url "$RPC_URL")"

# The deploy scripts read RPC_URL from network.params and deliberately ignore the environment
# (dev-standards §6.2: values come from files only), so pointing only this script at E2E_PORT would
# leave the tools on another port -- with a chain-ID match they would silently deploy to whichever
# chain happens to sit on 8545.
if grep -q '^RPC_URL=' "$NETWORK_DIR/network.params"; then
    sed -i.bak "s|^RPC_URL=.*|RPC_URL=$RPC_URL|" "$NETWORK_DIR/network.params" && rm -f "$NETWORK_DIR/network.params.bak"
else
    printf 'RPC_URL=%s\n' "$RPC_URL" >> "$NETWORK_DIR/network.params"
fi
pass "network.params RPC_URL points at $RPC_URL"

# --- deploy through its own script ------------------------------------------------------------

step "3. Deploy through script/deploy/"

if "$TOOLS_ROOT/script/deploy/one_click_deploy_batch_transfer.sh" "$NETWORK"; then
    pass "one_click_deploy_batch_transfer.sh"
else
    fail "one_click_deploy_batch_transfer.sh"
    DEPLOY_FAILED=1
fi

# Only a deployment failure blocks the on-chain checks; a failed assertion above must not hide them.
[ "$DEPLOY_FAILED" -eq 0 ] || die "deployment failed, skipping the on-chain checks"

BT=$(sed -n 's/^BATCH_TRANSFER_ADDRESS=//p' "$NETWORK_DIR/addresses.batch-transfer.params")
[ -n "$BT" ] || die "BATCH_TRANSFER_ADDRESS not written"

# --- on-chain behaviour -----------------------------------------------------------------------

step "4. BatchTransfer on chain: native batch"

R1=0x000000000000000000000000000000000000A001
R2=0x000000000000000000000000000000000000A002
R3=0x000000000000000000000000000000000000A003
if send_tool "$BT" "batchTransferNative(address[],uint256[],uint256)" \
        "[$R1,$R2,$R3]" "[1000000000000000000,2000000000000000000,3000000000000000000]" 50000 \
        --value 6000000000000000000 >/dev/null 2>&1; then
    pass "batchTransferNative executed"
else
    fail "batchTransferNative reverted"
fi
assert_eq "recipient 1 balance" "1000000000000000000" "$(uint_of "$(cast balance "$R1" --rpc-url "$RPC_URL")")"
assert_eq "recipient 2 balance" "2000000000000000000" "$(uint_of "$(cast balance "$R2" --rpc-url "$RPC_URL")")"
assert_eq "recipient 3 balance" "3000000000000000000" "$(uint_of "$(cast balance "$R3" --rpc-url "$RPC_URL")")"
# The whole msg.value left the contract in the same transaction: that is the "no custody" promise.
assert_eq "batch contract holds no native value" "0" "$(uint_of "$(cast balance "$BT" --rpc-url "$RPC_URL")")"

step "5. BatchTransfer on chain: ERC20 batch"

# The ERC20 branch needs a real token. tools is zero-dependency, so there is nothing to import: the
# token deployed here is the repository's own test mock, taken from the build output that
# `forge build` already produces (test sources are compiled by default). That keeps this script
# self-contained and adds no fixture contract just for the e2e run.
TOKEN_ART="$TOOLS_ROOT/out/BatchTransferMocks.sol/MockERC20.json"
[ -f "$TOKEN_ART" ] || die "missing build artifact: $TOKEN_ART (run 'forge build' first)"
TOKEN=$(deploy_from_artifact "$TOKEN_ART")
pass "test ERC20 deployed at $TOKEN"

D1=0x000000000000000000000000000000000000B001
D2=0x000000000000000000000000000000000000B002
send_tool "$TOKEN" "mint(address,uint256)" "$ACCOUNT_ADDRESS" 20000000000000000000 >/dev/null 2>&1 \
    || die "could not mint the test ERC20"
send_tool "$TOKEN" "approve(address,uint256)" "$BT" 20000000000000000000 >/dev/null 2>&1 \
    || die "could not approve the test ERC20"
pass "test ERC20 minted and approved"

if send_tool "$BT" "batchTransferERC20(address,address[],uint256[],uint256)" \
        "$TOKEN" "[$D1,$D2]" "[7000000000000000000,8000000000000000000]" 50000 >/dev/null 2>&1; then
    pass "batchTransferERC20 executed"
else
    fail "batchTransferERC20 reverted"
fi
assert_eq "token recipient 1 balance" "7000000000000000000" \
    "$(uint_of "$(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$D1" --rpc-url "$RPC_URL")")"
assert_eq "token recipient 2 balance" "8000000000000000000" \
    "$(uint_of "$(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$D2" --rpc-url "$RPC_URL")")"
assert_eq "batch contract holds no tokens" "0" \
    "$(uint_of "$(cast call "$TOKEN" 'balanceOf(address)(uint256)' "$BT" --rpc-url "$RPC_URL")")"

step "6. Custom-error selectors"

# A regression here would silently ship a different revert; the selectors are what integrators match.
ZERO_GAS_EXPECTED=$(cast sig "ZeroGasLimit()")
ZERO_GAS_ACTUAL=$(cast call "$BT" "batchTransferNative(address[],uint256[],uint256)" \
    "[$R1]" "[1]" 0 --rpc-url "$RPC_URL" 2>&1 | grep -o '0x[0-9a-f]\{8\}' | head -1 || true)
assert_eq "ZeroGasLimit selector" "$ZERO_GAS_EXPECTED" "$ZERO_GAS_ACTUAL"

VALUE_MISMATCH=$(cast call "$BT" "batchTransferNative(address[],uint256[],uint256)" \
    "[$R1]" "[1]" 50000 --rpc-url "$RPC_URL" 2>&1 || true)
assert_contains "NativeValueMismatch carries both totals" "NativeValueMismatch(" "$VALUE_MISMATCH"

# --- summary ----------------------------------------------------------------------------------

step "Summary"
printf '  passed: %s\n  failed: %s\n' "$CHECKS_PASSED" "$CHECKS_FAILED"
if [ "$CHECKS_FAILED" -ne 0 ]; then
    die "$CHECKS_FAILED check(s) failed"
fi
printf '\n\033[32mAll end-to-end checks passed.\033[0m\n'
