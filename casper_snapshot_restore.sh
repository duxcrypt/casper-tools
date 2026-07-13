#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_URL=""
LATEST="false"
PRINT_LATEST="false"
SNAPSHOT_INDEX_URL="https://snapshot.kalia.network/"
CASPER_VERSION="2_2_2"
RPC_URL="https://node.testnet.casper.network/rpc"
YES="false"
KEEP_ARCHIVE="false"
DOWNLOAD_DIR="${HOME}"
CASPER_DATA_DIR="/var/lib/casper/casper-node"
CASPER_BASE_DIR="/var/lib/casper"
VALIDATOR_KEYS_DIR="/etc/casper/validator_keys"
TOTAL_STEPS=10
CURRENT_STEP=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[36m')"
  RED="$(printf '\033[31m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""
  DIM=""
  GREEN=""
  YELLOW=""
  BLUE=""
  RED=""
  RESET=""
fi

usage() {
  cat <<'EOF'
Casper testnet snapshot restore script.

Usage:
  sudo bash casper_snapshot_restore.sh --url SNAPSHOT_URL --yes
  sudo bash casper_snapshot_restore.sh --latest --yes
  bash casper_snapshot_restore.sh --print-latest

Options:
  --url URL          Snapshot archive URL, for example:
                    https://snapshot.kalia.network/snapshots/casper/casper-test-8484221.tar.lz4
  --latest          Auto-detect the newest casper-test snapshot from snapshot.kalia.network.
  --print-latest    Print the newest detected snapshot URL and exit.
  --index-url URL   Page/API used by --latest. Default: https://snapshot.kalia.network/
  --version VERSION Casper config version folder. Default: 2_2_2
  --rpc URL         RPC endpoint for fresh trusted hash.
                    Default: https://node.testnet.casper.network/rpc
  --keep-archive    Do not delete downloaded snapshot archive after restore.
  --yes             Run without interactive confirmation.
  -h, --help        Show this help.

Environment alternatives:
  SNAPSHOT_URL=...
  SNAPSHOT_INDEX_URL=https://snapshot.kalia.network/
  CASPER_VERSION=2_2_2
  RPC_URL=https://node.testnet.casper.network/rpc

This script removes only /var/lib/casper/casper-node.
It does not remove /etc/casper/validator_keys.
EOF
}

line() {
  printf '%s\n' '------------------------------------------------------------'
}

banner() {
  printf '\n%sCasper Testnet Snapshot Restore%s\n' "$BOLD" "$RESET"
  line
  printf 'This script replaces only the Casper chain database.\n'
  printf 'Validator keys are checked and kept in place.\n'
}

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf '\n%s[%02d/%02d]%s %s%s%s\n' "$BLUE" "$CURRENT_STEP" "$TOTAL_STEPS" "$RESET" "$BOLD" "$*" "$RESET"
}

info() {
  printf '  %s-%s %s\n' "$DIM" "$RESET" "$*"
}

ok() {
  printf '  %sOK%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
  printf '  %sWARN%s %s\n' "$YELLOW" "$RESET" "$*"
}

fail() {
  printf '\n%sERROR%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

show_plan() {
  printf '\n%sRestore plan%s\n' "$BOLD" "$RESET"
  line
  printf '  Snapshot       : %s\n' "$SNAPSHOT_URL"
  printf '  Archive path   : %s\n' "$SNAPSHOT_PATH"
  printf '  Config         : %s\n' "$CONFIG_FILE"
  printf '  Trusted hash   : fresh hash from %s\n' "$RPC_URL"
  printf '  Will remove    : %s\n' "$CASPER_DATA_DIR"
  printf '  Will keep      : %s\n' "$VALIDATOR_KEYS_DIR"
  line
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      SNAPSHOT_URL="${2:-}"
      shift 2
      ;;
    --latest)
      LATEST="true"
      shift
      ;;
    --print-latest)
      PRINT_LATEST="true"
      LATEST="true"
      shift
      ;;
    --index-url)
      SNAPSHOT_INDEX_URL="${2:-}"
      shift 2
      ;;
    --version)
      CASPER_VERSION="${2:-}"
      shift 2
      ;;
    --rpc)
      RPC_URL="${2:-}"
      shift 2
      ;;
    --keep-archive)
      KEEP_ARCHIVE="true"
      shift
      ;;
    --yes|-y)
      YES="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

SNAPSHOT_URL="${SNAPSHOT_URL:-${SNAPSHOT_URL:-}}"
SNAPSHOT_INDEX_URL="${SNAPSHOT_INDEX_URL:-https://snapshot.kalia.network/}"
CASPER_VERSION="${CASPER_VERSION:-2_2_2}"
RPC_URL="${RPC_URL:-https://node.testnet.casper.network/rpc}"
CONFIG_FILE="/etc/casper/${CASPER_VERSION}/config.toml"
STARTED_AT="$(date +%s)"

banner

if [[ "$LATEST" == "true" ]]; then
  command -v curl >/dev/null || fail "curl is required for --latest."
  command -v grep >/dev/null || fail "grep is required for --latest."
  command -v sed >/dev/null || fail "sed is required for --latest."
  command -v sort >/dev/null || fail "sort is required for --latest."
  step "Find latest snapshot"
  info "Reading $SNAPSHOT_INDEX_URL"
  SNAPSHOT_URL="$(
    curl -fsSL "$SNAPSHOT_INDEX_URL" \
    | grep -Eo 'https?://[^"'"'"' <>()]+/snapshots/casper/casper-test-[0-9]+\.tar\.lz4|/snapshots/casper/casper-test-[0-9]+\.tar\.lz4|casper-test-[0-9]+\.tar\.lz4' \
    | sed "s#^/snapshots#https://snapshot.kalia.network/snapshots#" \
    | sed "s#^casper-test-#https://snapshot.kalia.network/snapshots/casper/casper-test-#" \
    | sort -V \
    | tail -n 1
  )"
  [[ -n "$SNAPSHOT_URL" ]] || fail "Could not detect a snapshot from $SNAPSHOT_INDEX_URL"
  ok "Latest snapshot: $SNAPSHOT_URL"
fi

if [[ "$PRINT_LATEST" == "true" ]]; then
  [[ -n "$SNAPSHOT_URL" ]] || fail "--print-latest could not detect a snapshot."
  echo "$SNAPSHOT_URL"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || fail "Run as root or with sudo."
[[ -f "$CONFIG_FILE" ]] || fail "Config not found: $CONFIG_FILE"
[[ -d "$VALIDATOR_KEYS_DIR" ]] || fail "Validator keys directory not found: $VALIDATOR_KEYS_DIR"
[[ -f "$VALIDATOR_KEYS_DIR/secret_key.pem" ]] || fail "Missing validator secret key: $VALIDATOR_KEYS_DIR/secret_key.pem"
[[ -f "$VALIDATOR_KEYS_DIR/public_key.pem" ]] || fail "Missing validator public key: $VALIDATOR_KEYS_DIR/public_key.pem"
[[ -n "$SNAPSHOT_URL" ]] || fail "Missing --url SNAPSHOT_URL, or --latest could not detect a snapshot."

if [[ "$LATEST" != "true" ]]; then
  step "Use provided snapshot"
  ok "$SNAPSHOT_URL"
fi

step "Check node files"
ok "Config found: $CONFIG_FILE"
ok "Validator keys found: $VALIDATOR_KEYS_DIR"

step "Install required tools"
info "Installing aria2, lz4, jq, curl and tar if needed"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 lz4 jq curl ca-certificates tar grep sed coreutils
ok "Required tools are ready"

SNAPSHOT_FILE="${SNAPSHOT_URL##*/}"
SNAPSHOT_PATH="${DOWNLOAD_DIR}/${SNAPSHOT_FILE}"

show_plan

if [[ "$YES" != "true" ]]; then
  read -r -p "Type RESTORE to stop services and replace Casper DB: " answer
  [[ "$answer" == "RESTORE" ]] || fail "Cancelled."
fi

step "Download snapshot"
info "This can take a while on a fresh node"
aria2c --continue=true --max-connection-per-server=16 --split=16 --min-split-size=1M --summary-interval=10 \
  --dir="$DOWNLOAD_DIR" --out="$SNAPSHOT_FILE" "$SNAPSHOT_URL"

[[ -s "$SNAPSHOT_PATH" ]] || fail "Snapshot download failed or file is empty: $SNAPSHOT_PATH"
ok "Snapshot archive is ready: $SNAPSHOT_PATH"

step "Stop Casper services"
systemctl stop casper-node-launcher casper-sidecar 2>/dev/null || true
sleep 2
ok "Casper services stopped"

step "Back up config"
CONFIG_BACKUP="${CONFIG_FILE}.bak.snapshot.$(date '+%Y%m%d-%H%M%S')"
cp "$CONFIG_FILE" "$CONFIG_BACKUP"
ok "Config backup: $CONFIG_BACKUP"

step "Replace old chain database"
warn "Removing old data directory: $CASPER_DATA_DIR"
rm -rf "$CASPER_DATA_DIR"
ok "Old chain data removed"

step "Extract snapshot"
info "Writing snapshot into $CASPER_BASE_DIR"
lz4 -d -c "$SNAPSHOT_PATH" | tar -x -C "$CASPER_BASE_DIR"

[[ -d "$CASPER_DATA_DIR" ]] || fail "Snapshot did not create expected directory: $CASPER_DATA_DIR"
ok "Snapshot extracted"

step "Fix permissions"
chown -R casper:casper "$CASPER_DATA_DIR"
if [[ -x /etc/casper/node_util.py ]]; then
  /etc/casper/node_util.py fix_permissions || true
fi
ok "Permissions fixed"

step "Update trusted hash"
info "Fetching latest block hash from $RPC_URL"
BLOCK_HASH="$(
  casper-client get-block --node-address "$RPC_URL" \
  | jq -r '
      .result.block_with_signatures.block.Version2.hash //
      .result.block_with_signatures.block.Version1.hash //
      .result.block.hash //
      empty
    ' \
  | tr -d '\n'
)"

[[ -n "$BLOCK_HASH" && "$BLOCK_HASH" != "null" ]] || fail "Could not fetch trusted hash from $RPC_URL"

if grep -q '^trusted_hash = ' "$CONFIG_FILE"; then
  sed -i "s/^trusted_hash = .*/trusted_hash = '${BLOCK_HASH}'/" "$CONFIG_FILE"
else
  sed -i "1itrusted_hash = '${BLOCK_HASH}'" "$CONFIG_FILE"
fi
ok "trusted_hash updated: $BLOCK_HASH"

step "Start services and show status"
systemctl start casper-node-launcher
systemctl start casper-sidecar 2>/dev/null || true
sleep 10

LAUNCHER_STATUS="$(systemctl is-active casper-node-launcher 2>/dev/null || true)"
SIDECAR_STATUS="$(systemctl is-active casper-sidecar 2>/dev/null || true)"
printf '  casper-node-launcher : %s\n' "${LAUNCHER_STATUS:-unknown}"
printf '  casper-sidecar       : %s\n' "${SIDECAR_STATUS:-unknown}"

printf '\n%sNode status%s\n' "$BOLD" "$RESET"
line
if curl -fsS --max-time 5 http://127.0.0.1:8888/status >/tmp/casper-status.json; then
  jq -r '
    "reactor_state: \(.reactor_state)",
    "peers: \(.peers | length)",
    "height: \(.last_added_block_info.height // "unknown")",
    "uptime: \(.uptime // "unknown")"
  ' /tmp/casper-status.json
  echo "trusted_hash: $BLOCK_HASH"
else
  warn "Node API is not ready yet. This can be normal right after start."
fi

if [[ "$KEEP_ARCHIVE" != "true" ]]; then
  printf '\n%sCleanup%s\n' "$BOLD" "$RESET"
  line
  rm -f "$SNAPSHOT_PATH"
  ok "Removed downloaded archive"
else
  warn "Archive kept: $SNAPSHOT_PATH"
fi

FINISHED_AT="$(date +%s)"
DURATION=$((FINISHED_AT - STARTED_AT))
printf '\n%sDone%s\n' "$BOLD" "$RESET"
line
ok "Snapshot restore finished in ${DURATION}s"
echo "Follow sync:"
echo "  /etc/casper/node_util.py watch"
