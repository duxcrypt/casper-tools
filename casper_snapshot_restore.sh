#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_URL="${SNAPSHOT_URL:-}"
LATEST="false"
PRINT_LATEST="false"
SNAPSHOT_INDEX_URL="${SNAPSHOT_INDEX_URL:-https://snapshot.kalia.network/}"
CASPER_VERSION="${CASPER_VERSION:-2_2_2}"
RPC_URL="${RPC_URL:-https://node.testnet.casper.network/rpc}"
YES="false"
KEEP_ARCHIVE="false"
SKIP_STORAGE_CHECK="false"
DOWNLOAD_DIR="${HOME}"
CASPER_DATA_DIR="/var/lib/casper/casper-node"
CASPER_BASE_DIR="/var/lib/casper"
VALIDATOR_KEYS_DIR="/etc/casper/validator_keys"
UNIT_FILES_DIR="${CASPER_DATA_DIR}/casper-test/unit_files"
SYNC_HANDLING="ttl"
IDLE_TOLERANCE="5 minutes"
MAX_ATTEMPTS=100
WATCH_SECONDS=300
WATCH_INTERVAL=30
DEFAULT_KNOWN_PEER="135.181.17.229:35000"
DEFAULT_PEER_SOURCE_URL="http://135.181.17.229:8888/status"
USE_DEFAULT_PEERS="true"
KNOWN_PEERS=()
PEER_SOURCE_URL=""
AUTO_PEERS=8
SNAPSHOT_HEIGHT=0
BLOCK_HEIGHT=""
TRUSTED_HASH_DEPTH=0
TRUSTED_HASH_HEIGHT=""
STALE_SNAPSHOT_WARN_BLOCKS=5000
TOTAL_STEPS=15
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
  --trusted-depth N Use a block N blocks behind RPC head for trusted_hash.
                    Default: 0, which uses the latest RPC head block.
  --trusted-height N
                    Use exact block height for trusted_hash.
  --known-peer HOST Add a known peer to config.toml, for example:
                    --known-peer 135.181.17.229:35000
                    Can be used multiple times.
  --peer-source URL Read extra peers from a Casper /status endpoint, for example:
                    --peer-source http://135.181.17.229:8888/status
  --auto-peers N    Add first N peers from --peer-source. Default: 8.
  --no-default-peers
                    Do not add the bundled default peer/source.
  --watch-seconds N Watch initial node progress after start. Default: 300.
  --no-watch        Do not watch initial node progress after start.
  --keep-archive    Do not delete downloaded snapshot archive after restore.
  --skip-storage-check
                    Allow execution on Btrfs or loop-backed root storage.
                    Not recommended for Casper LMDB.
  --yes             Run without interactive confirmation.
  -h, --help        Show this help.

Environment alternatives:
  SNAPSHOT_URL=...
  SNAPSHOT_INDEX_URL=https://snapshot.kalia.network/
  CASPER_VERSION=2_2_2
  RPC_URL=https://node.testnet.casper.network/rpc

Default peer behavior:
  The script automatically adds 135.181.17.229:35000 and imports up to
  8 peers from http://135.181.17.229:8888/status when reachable.
  Use --no-default-peers to disable this.

This script removes only /var/lib/casper/casper-node.
It does not remove /etc/casper/validator_keys.
It refuses Btrfs and loop-backed root storage by default because these
storage layers can make Casper LMDB stall on fsync.
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

check_storage_health() {
  command -v findmnt >/dev/null || fail "findmnt is required for the storage safety check."

  local root_source root_fstype
  root_source="$(findmnt -n -o SOURCE /)"
  root_fstype="$(findmnt -n -o FSTYPE /)"

  info "Root storage: ${root_source} (${root_fstype})"

  if [[ "$SKIP_STORAGE_CHECK" == "true" ]]; then
    warn "Storage safety check was explicitly skipped."
    return 0
  fi

  if [[ "$root_fstype" == "btrfs" || "$root_source" == /dev/loop* ]]; then
    fail "Unsafe Casper storage detected: ${root_source} (${root_fstype}).
Casper LMDB can stall on fsync when the container root uses Btrfs or a loop-backed pool.
Create or migrate the container to a direct ext4/LVM-backed LXD pool, then run this script again.
Use --skip-storage-check only when you understand and accept this risk."
  fi

  ok "Storage preflight passed"
}

show_plan() {
  printf '\n%sRestore plan%s\n' "$BOLD" "$RESET"
  line
  printf '  Snapshot       : %s\n' "$SNAPSHOT_URL"
  if [[ "${SNAPSHOT_HEIGHT:-0}" != "0" ]]; then
    printf '  Snapshot block : %s\n' "$SNAPSHOT_HEIGHT"
  fi
  printf '  Archive path   : %s\n' "$SNAPSHOT_PATH"
  printf '  Config         : %s\n' "$CONFIG_FILE"
  printf '  Trusted hash   : fresh hash from %s\n' "$RPC_URL"
  if [[ -n "$TRUSTED_HASH_HEIGHT" ]]; then
    printf '  Trusted height : %s\n' "$TRUSTED_HASH_HEIGHT"
  else
    if [[ "$TRUSTED_HASH_DEPTH" -gt 0 ]]; then
      printf '  Trusted depth  : %s block(s) behind RPC head\n' "$TRUSTED_HASH_DEPTH"
    else
      printf '  Trusted height : latest RPC head\n'
    fi
  fi
  if [[ "${#KNOWN_PEERS[@]}" -gt 0 ]]; then
    printf '  Extra peers    : %s\n' "${KNOWN_PEERS[*]}"
  fi
  if [[ -n "$PEER_SOURCE_URL" ]]; then
    printf '  Peer source    : %s\n' "$PEER_SOURCE_URL"
  fi
  if [[ "$WATCH_SECONDS" -gt 0 ]]; then
    printf '  Post-check     : %ss\n' "$WATCH_SECONDS"
  else
    printf '  Post-check     : disabled\n'
  fi
  printf '  Will remove    : %s\n' "$CASPER_DATA_DIR"
  printf '  Will keep      : %s\n' "$VALIDATOR_KEYS_DIR"
  printf '  Sync handling  : %s\n' "$SYNC_HANDLING"
  printf '  Idle tolerance : %s\n' "$IDLE_TOLERANCE"
  printf '  Max attempts   : %s\n' "$MAX_ATTEMPTS"
  printf '  Root storage   : %s (%s)\n' "$(findmnt -n -o SOURCE /)" "$(findmnt -n -o FSTYPE /)"
  line
}

add_known_peer() {
  local peer="$1"
  local existing
  [[ -n "$peer" ]] || return 0
  for existing in "${KNOWN_PEERS[@]}"; do
    [[ "$existing" == "$peer" ]] && return 0
  done
  KNOWN_PEERS+=("$peer")
}

import_known_peers_from_source() {
  [[ -n "$PEER_SOURCE_URL" ]] || return 0
  [[ "$AUTO_PEERS" -gt 0 ]] || return 0

  info "Reading up to ${AUTO_PEERS} peers from $PEER_SOURCE_URL"

  local imported=0
  local source_json
  local peer

  if ! source_json="$(curl -fsS --max-time 10 "$PEER_SOURCE_URL" 2>/dev/null)"; then
    warn "Peer source is not reachable. Continuing with configured known peers only."
    return 0
  fi

  while IFS= read -r peer; do
    [[ -n "$peer" ]] || continue
    add_known_peer "$peer"
    imported=$((imported + 1))
  done < <(printf '%s' "$source_json" | jq -r '.peers[]?.address // empty' | head -n "$AUTO_PEERS")

  if [[ "$imported" -gt 0 ]]; then
    ok "Imported ${imported} peer(s) from source"
  else
    warn "No peers were imported from peer source."
  fi
}

update_known_peers() {
  [[ "${#KNOWN_PEERS[@]}" -gt 0 ]] || return 0
  command -v python3 >/dev/null || fail "python3 is required to edit known_addresses safely."

  local known_peers_csv
  known_peers_csv="$(IFS=,; printf '%s' "${KNOWN_PEERS[*]}")"

  CONFIG_FILE="$CONFIG_FILE" KNOWN_PEERS_CSV="$known_peers_csv" python3 - <<'PY'
import os
import re
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
new_peers = [peer.strip() for peer in os.environ["KNOWN_PEERS_CSV"].split(",") if peer.strip()]
text = config_path.read_text()
lines = text.splitlines()

network_start = None
network_end = len(lines)
for index, line in enumerate(lines):
    if re.match(r"\s*\[network\]\s*$", line):
        network_start = index
        continue
    if network_start is not None and index > network_start and re.match(r"\s*\[[^\]]+\]\s*$", line):
        network_end = index
        break

if network_start is None:
    raise SystemExit("Could not find [network] section in config.toml")

updated = False
for index in range(network_start + 1, network_end):
    line = lines[index]
    if re.match(r"\s*#?\s*known_addresses\s*=", line):
        existing = re.findall(r"['\"]([^'\"]+)['\"]", line)
        merged = []
        for peer in new_peers + existing:
            if peer not in merged:
                merged.append(peer)
        indent = re.match(r"^(\s*)", line).group(1)
        lines[index] = f"{indent}known_addresses = [" + ",".join(f"'{peer}'" for peer in merged) + "]"
        updated = True
        break

if not updated:
    lines.insert(network_start + 1, "known_addresses = [" + ",".join(f"'{peer}'" for peer in new_peers) + "]")

config_path.write_text("\n".join(lines) + "\n")
PY

  ok "known_addresses updated: ${KNOWN_PEERS[*]}"
}

update_trusted_hash() {
  command -v python3 >/dev/null || fail "python3 is required to edit trusted_hash safely."

  CONFIG_FILE="$CONFIG_FILE" BLOCK_HASH="$BLOCK_HASH" python3 - <<'PY'
import os
import re
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
block_hash = os.environ["BLOCK_HASH"]
lines = config_path.read_text().splitlines()

node_start = None
node_end = len(lines)
for index, line in enumerate(lines):
    if re.match(r"\s*\[node\]\s*$", line):
        node_start = index
        continue
    if node_start is not None and index > node_start and re.match(r"\s*\[[^\]]+\]\s*$", line):
        node_end = index
        break

if node_start is None:
    raise SystemExit("Could not find [node] section in config.toml")

replacement = f"trusted_hash = '{block_hash}'"
for index in range(node_start + 1, node_end):
    if re.match(r"\s*#?\s*trusted_hash\s*=", lines[index]):
        indent = re.match(r"^(\s*)", lines[index]).group(1)
        lines[index] = indent + replacement
        break
else:
    lines.insert(node_start + 1, replacement)

config_path.write_text("\n".join(lines) + "\n")
PY

  ok "trusted_hash updated: $BLOCK_HASH"
}

update_node_sync_settings() {
  command -v python3 >/dev/null || fail "python3 is required to edit node sync settings safely."

  CONFIG_FILE="$CONFIG_FILE" \
  SYNC_HANDLING="$SYNC_HANDLING" \
  IDLE_TOLERANCE="$IDLE_TOLERANCE" \
  MAX_ATTEMPTS="$MAX_ATTEMPTS" \
  python3 - <<'PY'
import os
import re
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
lines = config_path.read_text().splitlines()

node_start = None
node_end = len(lines)
for index, line in enumerate(lines):
    if re.match(r"\s*\[node\]\s*$", line):
        node_start = index
        continue
    if node_start is not None and index > node_start and re.match(r"\s*\[[^\]]+\]\s*$", line):
        node_end = index
        break

if node_start is None:
    raise SystemExit("Could not find [node] section in config.toml")

settings = {
    "sync_handling": f"'{os.environ['SYNC_HANDLING']}'",
    "idle_tolerance": f"'{os.environ['IDLE_TOLERANCE']}'",
    "max_attempts": os.environ["MAX_ATTEMPTS"],
}

for key, value in settings.items():
    replacement = f"{key} = {value}"
    for index in range(node_start + 1, node_end):
        if re.match(rf"\s*#?\s*{re.escape(key)}\s*=", lines[index]):
            indent = re.match(r"^(\s*)", lines[index]).group(1)
            lines[index] = indent + replacement
            break
    else:
        lines.insert(node_start + 1, replacement)
        node_end += 1

config_path.write_text("\n".join(lines) + "\n")
PY

  ok "Node sync settings updated: ${SYNC_HANDLING}, ${IDLE_TOLERANCE}, ${MAX_ATTEMPTS} attempts"
}

check_config_health() {
  command -v python3 >/dev/null || fail "python3 is required to check config.toml safely."

  CONFIG_FILE="$CONFIG_FILE" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE"])
lines = config_path.read_text().splitlines()

cleaned = []
misplaced_trusted_hash_lines = []
seen_section = False
for line_number, line in enumerate(lines, 1):
    if re.match(r"\s*\[[^\]]+\]\s*$", line):
        seen_section = True
    if not seen_section and re.match(r"\s*trusted_hash\s*=", line):
        misplaced_trusted_hash_lines.append(line_number)
        continue
    cleaned.append(line)

if misplaced_trusted_hash_lines:
    config_path.write_text("\n".join(cleaned) + "\n")
    lines = cleaned
    print(
        "Removed misplaced top-level trusted_hash line(s): "
        + ", ".join(str(item) for item in misplaced_trusted_hash_lines)
    )

sections = set()
for line in lines:
    match = re.match(r"\s*\[([^\]]+)\]\s*$", line)
    if match:
        sections.add(match.group(1))

missing_sections = [section for section in ("node", "network") if section not in sections]
if missing_sections:
    raise SystemExit(
        "config.toml is missing required section(s): "
        + ", ".join(f"[{section}]" for section in missing_sections)
    )

invalid_lines = []
bracket_balance = 0
for line_number, line in enumerate(lines, 1):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue

    if bracket_balance > 0:
        bracket_balance += stripped.count("[") - stripped.count("]")
        continue

    if re.match(r"\[[^\]]+\]$", stripped):
        continue

    if re.match(r"[A-Za-z0-9_.-]+\s*=", stripped):
        value = stripped.split("=", 1)[1]
        bracket_balance += value.count("[") - value.count("]")
        continue

    invalid_lines.append((line_number, stripped))
    if len(invalid_lines) >= 5:
        break

if invalid_lines:
    message = [
        "config.toml looks corrupted. Some comment/prose lines are not prefixed with '#'.",
        "Restore a clean Casper config.toml before running snapshot restore.",
        "First suspicious line(s):",
    ]
    message.extend(f"  line {number}: {text}" for number, text in invalid_lines)
    raise SystemExit("\n".join(message))
PY

  ok "Config health check passed"
}

watch_initial_progress() {
  [[ "$WATCH_SECONDS" -gt 0 ]] || return 0

  step "Watch initial sync"
  info "Checking local node API every ${WATCH_INTERVAL}s for up to ${WATCH_SECONDS}s"

  local end_time start_height height state peers restarts initial_restarts status_json saw_progress
  end_time=$((SECONDS + WATCH_SECONDS))
  start_height=""
  saw_progress=0
  initial_restarts="$(systemctl show casper-node-launcher -p NRestarts --value 2>/dev/null || echo 0)"

  while [[ "$SECONDS" -lt "$end_time" ]]; do
    if status_json="$(curl -fsS --max-time 5 http://127.0.0.1:8888/status 2>/dev/null)"; then
      state="$(printf '%s' "$status_json" | jq -r '.reactor_state // "unknown"')"
      height="$(printf '%s' "$status_json" | jq -r '.last_added_block_info.height // "unknown"')"
      peers="$(printf '%s' "$status_json" | jq -r '(.peers // []) | length')"
      restarts="$(systemctl show casper-node-launcher -p NRestarts --value 2>/dev/null || echo 0)"

      printf '  - state=%s height=%s peers=%s restarts=%s\n' "$state" "$height" "$peers" "$restarts"

      if [[ "$height" =~ ^[0-9]+$ ]]; then
        if [[ -z "$start_height" ]]; then
          start_height="$height"
        elif [[ "$height" -gt "$start_height" ]]; then
          saw_progress=1
        fi
      fi

      if [[ "$restarts" != "$initial_restarts" ]]; then
        warn "casper-node-launcher restarted during post-check."
        initial_restarts="$restarts"
      fi

      if [[ "$state" == "Validate" ]]; then
        ok "Node is validating."
        return 0
      fi

      if [[ "$state" == "KeepUp" && "$peers" =~ ^[0-9]+$ && "$peers" -gt 0 ]]; then
        ok "Node is keeping up with peers."
        return 0
      fi

      if [[ "$state" == "CatchUp" && "$saw_progress" -eq 1 ]]; then
        ok "Node is catching up and height is moving."
        return 0
      fi
    else
      warn "Node API is not ready yet."
    fi

    sleep "$WATCH_INTERVAL"
  done

  if [[ "$saw_progress" -eq 1 ]]; then
    ok "Node made progress during post-check."
  else
    warn "No clear progress during post-check. If it stays in CatchUp, try a newer snapshot or add --known-peer."
  fi
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
    --trusted-depth)
      TRUSTED_HASH_DEPTH="${2:-}"
      [[ -n "$TRUSTED_HASH_DEPTH" ]] || fail "--trusted-depth needs a number."
      shift 2
      ;;
    --trusted-height)
      TRUSTED_HASH_HEIGHT="${2:-}"
      [[ -n "$TRUSTED_HASH_HEIGHT" ]] || fail "--trusted-height needs a block height."
      shift 2
      ;;
    --known-peer)
      [[ -n "${2:-}" ]] || fail "--known-peer needs HOST, for example 135.181.17.229:35000"
      add_known_peer "$2"
      shift 2
      ;;
    --peer-source)
      PEER_SOURCE_URL="${2:-}"
      [[ -n "$PEER_SOURCE_URL" ]] || fail "--peer-source needs a URL, for example http://135.181.17.229:8888/status"
      shift 2
      ;;
    --auto-peers)
      AUTO_PEERS="${2:-}"
      [[ -n "$AUTO_PEERS" ]] || fail "--auto-peers needs a number."
      shift 2
      ;;
    --no-default-peers)
      USE_DEFAULT_PEERS="false"
      shift
      ;;
    --watch-seconds)
      WATCH_SECONDS="${2:-}"
      shift 2
      ;;
    --no-watch)
      WATCH_SECONDS=0
      shift
      ;;
    --keep-archive)
      KEEP_ARCHIVE="true"
      shift
      ;;
    --skip-storage-check)
      SKIP_STORAGE_CHECK="true"
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

[[ "$WATCH_SECONDS" =~ ^[0-9]+$ ]] || fail "--watch-seconds must be a number."
[[ "$AUTO_PEERS" =~ ^[0-9]+$ ]] || fail "--auto-peers must be a number."
[[ "$TRUSTED_HASH_DEPTH" =~ ^[0-9]+$ ]] || fail "--trusted-depth must be a number."
if [[ -n "$TRUSTED_HASH_HEIGHT" ]]; then
  [[ "$TRUSTED_HASH_HEIGHT" =~ ^[0-9]+$ ]] || fail "--trusted-height must be a number."
fi
if [[ "$USE_DEFAULT_PEERS" == "true" ]]; then
  add_known_peer "$DEFAULT_KNOWN_PEER"
  if [[ -z "$PEER_SOURCE_URL" ]]; then
    PEER_SOURCE_URL="$DEFAULT_PEER_SOURCE_URL"
  fi
fi
if [[ "$WATCH_SECONDS" -eq 0 ]]; then
  TOTAL_STEPS=14
fi

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
check_storage_health

step "Install required tools"
info "Installing aria2, lz4, jq, curl, python3 and tar if needed"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 lz4 jq curl ca-certificates tar grep sed coreutils python3
command -v casper-client >/dev/null || fail "casper-client is required. Install Casper node packages before running this restore script."
ok "Required tools are ready"

step "Check config health"
check_config_health
import_known_peers_from_source

SNAPSHOT_FILE="${SNAPSHOT_URL##*/}"
SNAPSHOT_PATH="${DOWNLOAD_DIR}/${SNAPSHOT_FILE}"
SNAPSHOT_HEIGHT="$(printf '%s\n' "$SNAPSHOT_FILE" | sed -n 's/^casper-test-\([0-9][0-9]*\)\.tar\.lz4$/\1/p')"
SNAPSHOT_HEIGHT="${SNAPSHOT_HEIGHT:-0}"

show_plan

if [[ "$YES" != "true" ]]; then
  read -r -p "Type RESTORE to stop services and replace Casper DB: " answer
  [[ "$answer" == "RESTORE" ]] || fail "Cancelled."
fi

step "Download snapshot"
info "Downloading quietly. Large snapshots can take a few minutes."
aria2c \
  --continue=true \
  --max-connection-per-server=16 \
  --split=16 \
  --min-split-size=1M \
  --summary-interval=0 \
  --console-log-level=warn \
  --show-console-readout=false \
  --download-result=hide \
  --dir="$DOWNLOAD_DIR" --out="$SNAPSHOT_FILE" "$SNAPSHOT_URL"

[[ -s "$SNAPSHOT_PATH" ]] || fail "Snapshot download failed or file is empty: $SNAPSHOT_PATH"
ok "Snapshot archive is ready: $SNAPSHOT_PATH"

step "Validate snapshot archive"
info "Testing the complete LZ4 stream and tar structure before changing the current database"
lz4 -d -c "$SNAPSHOT_PATH" | tar -t >/dev/null
ok "Snapshot archive integrity check passed"

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

step "Reset transient consensus cache"
mkdir -p "$UNIT_FILES_DIR"
find "$UNIT_FILES_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
ok "Transient unit_files cache reset: $UNIT_FILES_DIR"

step "Fix permissions"
chown -R casper:casper "$CASPER_DATA_DIR"
if [[ -x /etc/casper/node_util.py ]]; then
  /etc/casper/node_util.py fix_permissions || true
fi
ok "Permissions fixed"

step "Update trusted hash"
info "Fetching RPC head from $RPC_URL"
HEAD_BLOCK_JSON="$(casper-client get-block --node-address "$RPC_URL")"
HEAD_BLOCK_HEIGHT="$(
  printf '%s' "$HEAD_BLOCK_JSON" \
  | jq -r '
      .result.block_with_signatures.block.Version2.header.height //
      .result.block_with_signatures.block.Version1.header.height //
      .result.block.header.height //
      empty
    ' \
  | tr -d '\n'
)"

[[ "$HEAD_BLOCK_HEIGHT" =~ ^[0-9]+$ ]] || fail "Could not fetch RPC head height from $RPC_URL"

if [[ -n "$TRUSTED_HASH_HEIGHT" ]]; then
  TARGET_BLOCK_HEIGHT="$TRUSTED_HASH_HEIGHT"
elif [[ "$TRUSTED_HASH_DEPTH" -gt 0 ]]; then
  TARGET_BLOCK_HEIGHT=$((HEAD_BLOCK_HEIGHT - TRUSTED_HASH_DEPTH))
  [[ "$TARGET_BLOCK_HEIGHT" -gt 0 ]] || fail "Trusted hash depth is too large for RPC head height."
  if [[ "$SNAPSHOT_HEIGHT" =~ ^[0-9]+$ && "$SNAPSHOT_HEIGHT" -gt 0 && "$HEAD_BLOCK_HEIGHT" -gt "$SNAPSHOT_HEIGHT" && "$TARGET_BLOCK_HEIGHT" -le "$SNAPSHOT_HEIGHT" ]]; then
    warn "Snapshot is newer than head-${TRUSTED_HASH_DEPTH}; using latest RPC head for trusted_hash instead."
    TARGET_BLOCK_HEIGHT="$HEAD_BLOCK_HEIGHT"
  fi
else
  TARGET_BLOCK_HEIGHT="$HEAD_BLOCK_HEIGHT"
fi

info "Fetching trusted block at height $TARGET_BLOCK_HEIGHT (RPC head: $HEAD_BLOCK_HEIGHT)"
BLOCK_JSON="$(casper-client get-block --node-address "$RPC_URL" --block-identifier "$TARGET_BLOCK_HEIGHT")"
BLOCK_HASH="$(
  printf '%s' "$BLOCK_JSON" \
  | jq -r '
      .result.block_with_signatures.block.Version2.hash //
      .result.block_with_signatures.block.Version1.hash //
      .result.block.hash //
      empty
    ' \
  | tr -d '\n'
)"
BLOCK_HEIGHT="$(
  printf '%s' "$BLOCK_JSON" \
  | jq -r '
      .result.block_with_signatures.block.Version2.header.height //
      .result.block_with_signatures.block.Version1.header.height //
      .result.block.header.height //
      empty
    ' \
  | tr -d '\n'
)"

[[ -n "$BLOCK_HASH" && "$BLOCK_HASH" != "null" ]] || fail "Could not fetch trusted hash from $RPC_URL"

if [[ "$SNAPSHOT_HEIGHT" =~ ^[0-9]+$ && "$BLOCK_HEIGHT" =~ ^[0-9]+$ && "$SNAPSHOT_HEIGHT" -gt 0 ]]; then
  SNAPSHOT_GAP=$((BLOCK_HEIGHT - SNAPSHOT_HEIGHT))
  if [[ "$SNAPSHOT_GAP" -lt 0 ]]; then
    warn "RPC height is lower than snapshot height. Check that both are Casper testnet."
  elif [[ "$SNAPSHOT_GAP" -gt "$STALE_SNAPSHOT_WARN_BLOCKS" ]]; then
    warn "Snapshot is ${SNAPSHOT_GAP} blocks behind RPC. CatchUp can take longer."
  else
    ok "Snapshot gap to RPC: ${SNAPSHOT_GAP} blocks"
  fi
fi

update_trusted_hash
update_known_peers
update_node_sync_settings

step "Start services and show status"
systemctl enable casper-node-launcher
systemctl enable casper-sidecar 2>/dev/null || true
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

watch_initial_progress

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
