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

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
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

if [[ "$LATEST" == "true" ]]; then
  command -v curl >/dev/null || fail "curl is required for --latest."
  command -v grep >/dev/null || fail "grep is required for --latest."
  command -v sed >/dev/null || fail "sed is required for --latest."
  command -v sort >/dev/null || fail "sort is required for --latest."
  log "Detecting latest snapshot from $SNAPSHOT_INDEX_URL"
  SNAPSHOT_URL="$(
    curl -fsSL "$SNAPSHOT_INDEX_URL" \
    | grep -Eo 'https?://[^"'"'"' <>()]+/snapshots/casper/casper-test-[0-9]+\.tar\.lz4|/snapshots/casper/casper-test-[0-9]+\.tar\.lz4|casper-test-[0-9]+\.tar\.lz4' \
    | sed "s#^/snapshots#https://snapshot.kalia.network/snapshots#" \
    | sed "s#^casper-test-#https://snapshot.kalia.network/snapshots/casper/casper-test-#" \
    | sort -V \
    | tail -n 1
  )"
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

log "Installing required tools"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y aria2 lz4 jq curl ca-certificates tar grep sed coreutils

SNAPSHOT_FILE="${SNAPSHOT_URL##*/}"
SNAPSHOT_PATH="${DOWNLOAD_DIR}/${SNAPSHOT_FILE}"

cat <<EOF

Casper snapshot restore plan:
  Snapshot:       $SNAPSHOT_URL
  Archive path:   $SNAPSHOT_PATH
  Config:         $CONFIG_FILE
  RPC hash source:$RPC_URL
  Remove data:    $CASPER_DATA_DIR
  Keep keys:      $VALIDATOR_KEYS_DIR

EOF

if [[ "$YES" != "true" ]]; then
  read -r -p "Type RESTORE to stop services and replace Casper DB: " answer
  [[ "$answer" == "RESTORE" ]] || fail "Cancelled."
fi

log "Downloading snapshot"
aria2c --continue=true --max-connection-per-server=16 --split=16 --min-split-size=1M \
  --dir="$DOWNLOAD_DIR" --out="$SNAPSHOT_FILE" "$SNAPSHOT_URL"

[[ -s "$SNAPSHOT_PATH" ]] || fail "Snapshot download failed or file is empty: $SNAPSHOT_PATH"

log "Stopping Casper services"
systemctl stop casper-node-launcher casper-sidecar 2>/dev/null || true
sleep 2

log "Backing up config"
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.snapshot.$(date '+%Y%m%d-%H%M%S')"

log "Removing old Casper chain data"
rm -rf "$CASPER_DATA_DIR"

log "Extracting snapshot"
lz4 -d -c "$SNAPSHOT_PATH" | tar -x -C "$CASPER_BASE_DIR"

[[ -d "$CASPER_DATA_DIR" ]] || fail "Snapshot did not create expected directory: $CASPER_DATA_DIR"

log "Fixing ownership and permissions"
chown -R casper:casper "$CASPER_DATA_DIR"
if [[ -x /etc/casper/node_util.py ]]; then
  /etc/casper/node_util.py fix_permissions || true
fi

log "Fetching fresh trusted hash"
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

log "Updating trusted_hash in config.toml"
if grep -q '^trusted_hash = ' "$CONFIG_FILE"; then
  sed -i "s/^trusted_hash = .*/trusted_hash = '${BLOCK_HASH}'/" "$CONFIG_FILE"
else
  sed -i "1itrusted_hash = '${BLOCK_HASH}'" "$CONFIG_FILE"
fi

log "Starting Casper services"
systemctl start casper-node-launcher
systemctl start casper-sidecar 2>/dev/null || true
sleep 10

log "Service status"
systemctl --no-pager --full status casper-node-launcher | sed -n '1,18p' || true
systemctl is-active casper-sidecar 2>/dev/null || true

log "Node status"
if curl -fsS --max-time 5 http://127.0.0.1:8888/status >/tmp/casper-status.json; then
  jq -r '
    "reactor_state: \(.reactor_state)",
    "peers: \(.peers | length)",
    "height: \(.last_added_block_info.height // "unknown")",
    "uptime: \(.uptime // "unknown")"
  ' /tmp/casper-status.json
  echo "trusted_hash: $BLOCK_HASH"
else
  echo "Node API is not ready yet. Watch logs with:"
  echo "  /etc/casper/node_util.py watch"
fi

if [[ "$KEEP_ARCHIVE" != "true" ]]; then
  log "Removing downloaded archive"
  rm -f "$SNAPSHOT_PATH"
fi

log "Done"
echo "Follow sync:"
echo "  /etc/casper/node_util.py watch"
