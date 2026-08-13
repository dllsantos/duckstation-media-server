#!/usr/bin/env bash
# Prepare, validate, and optionally start this media-server stack.
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE="$PROJECT_DIR/.env.example"
PROFILE_FILE="$PROJECT_DIR/gluetun/pt134.nordvpn.com.udp_2.6.ovpn"
MEDIA_DIR="$PROJECT_DIR/media/drive"

MODE="vpn"
START=false
DOCTOR=false

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--vpn | --no-vpn] [--start] [--doctor]

Prepare this media-server project for a new server.

Options:
  --vpn       Use the default VPN setup (NordVPN/Gluetun). This is the default.
  --no-vpn    Run qBittorrent directly, using docker-compose.no-vpn.yml.
  --start     Validate the selected setup and start the containers.
  --doctor    Run checks only; do not create or change files.
  -h, --help  Show this help.

Examples:
  ./setup.sh                 # Create folders and a safe .env template
  ./setup.sh --no-vpn        # Prepare the direct-connection setup
  ./setup.sh --vpn --start   # Validate and start the default VPN setup
  ./setup.sh --no-vpn --doctor
EOF
}

log() { printf '%s\n' "$*"; }
ok() { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

for argument in "$@"; do
  case "$argument" in
    --vpn) MODE="vpn" ;;
    --no-vpn) MODE="no-vpn" ;;
    --start) START=true ;;
    --doctor) DOCTOR=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $argument (run ./setup.sh --help)" ;;
  esac
done

if "$DOCTOR" && "$START"; then
  die "Use either --doctor or --start, not both."
fi

compose=(docker compose)
if [[ "$MODE" == "no-vpn" ]]; then
  compose+=( -f docker-compose.yml -f docker-compose.no-vpn.yml )
fi

server_ip() {
  hostname -I 2>/dev/null | tr ' ' '\n' | awk '
    /^10\./ || /^192\.168\./ || /^172\.(1[6-9]|2[0-9]|3[0-1])\./ { print; exit }
  '
}

is_placeholder() {
  [[ -z "$1" || "$1" == your_* || "$1" == *YOUR-* ]]
}

env_value() {
  local key=$1
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Follow README section 1 first."
  docker compose version >/dev/null 2>&1 || die "Docker Compose is not available. Follow README section 1 first."
  ok "Docker and Docker Compose are available"
}

prepare_directories() {
  mkdir -p \
    "$PROJECT_DIR/gluetun/iptables" \
    "$PROJECT_DIR/jellyfin/config" "$PROJECT_DIR/jellyfin/cache" \
    "$PROJECT_DIR/qbittorrent/config" "$PROJECT_DIR/prowlarr/config" \
    "$PROJECT_DIR/sonarr/config" "$PROJECT_DIR/radarr/config" \
    "$PROJECT_DIR/bazarr/config" "$PROJECT_DIR/seerr/config" \
    "$PROJECT_DIR/heimdall/config" \
    "$MEDIA_DIR/torrents" "$MEDIA_DIR/media/movies" "$MEDIA_DIR/media/tv"
  ok "Project directories are ready"
}

prepare_env() {
  if [[ -f "$ENV_FILE" ]]; then
    ok ".env already exists; leaving it unchanged"
    return
  fi

  [[ -f "$ENV_EXAMPLE" ]] || die "Missing .env.example"
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  local uid gid timezone
  uid=$(id -u)
  gid=$(id -g)
  timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  timezone=${timezone:-UTC}
  sed -i \
    -e "s/^PUID=.*/PUID=$uid/" \
    -e "s/^PGID=.*/PGID=$gid/" \
    -e "s|^TZ=.*|TZ=$timezone|" \
    "$ENV_FILE"
  ok "Created .env with your PUID, PGID, and timezone"
  warn "Add NordVPN service credentials to .env before starting VPN mode."
}

check_drive() {
  if mountpoint -q "$MEDIA_DIR"; then
    ok "External media drive is mounted at $MEDIA_DIR"
  else
    warn "No separate drive is mounted at $MEDIA_DIR"
    warn "Follow README section 5 before downloading media."
    return 1
  fi
}

check_vpn_requirements() {
  local username password
  username=$(env_value NORDVPN_USERNAME)
  password=$(env_value NORDVPN_PASSWORD)

  [[ -f "$PROFILE_FILE" ]] || {
    warn "NordVPN/OpenVPN profile is missing: $PROFILE_FILE"
    return 1
  }
  if is_placeholder "$username" || is_placeholder "$password"; then
    warn "NordVPN service credentials in .env still need to be set"
    return 1
  fi
  ok "VPN profile and service credentials are present"
}

check_compose() {
  "${compose[@]}" --env-file "$ENV_FILE" config -q || return 1
  ok "Compose configuration is valid for $MODE mode"
}

show_details() {
  local ip
  ip=$(server_ip || true)
  log ""
  log "Server details"
  log "  Project directory: $PROJECT_DIR"
  log "  PUID / PGID:      $(id -u) / $(id -g)"
  log "  Server IP:        ${ip:-not detected; run hostname -I}"
  log "  Selected mode:    $MODE"
  if [[ -n "$ip" ]]; then
    log "  Jellyfin:         http://$ip:8096"
    log "  Heimdall:         http://$ip/"
  fi
}

run_doctor() {
  local failed=false
  log "Checking $MODE mode..."
  check_docker
  [[ -f "$ENV_FILE" ]] && ok ".env exists" || { warn ".env is missing; run ./setup.sh"; failed=true; }
  check_drive || failed=true
  if [[ "$MODE" == "vpn" ]]; then
    check_vpn_requirements || failed=true
  else
    ok "No-VPN mode selected; Gluetun is disabled"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    check_compose || { warn "Compose configuration is invalid"; failed=true; }
  fi
  show_details
  "$failed" && return 1
  return 0
}

main() {
  cd "$PROJECT_DIR"
  check_docker

  if "$DOCTOR"; then
    run_doctor
    return
  fi

  prepare_directories
  prepare_env
  show_details

  if ! "$START"; then
    log ""
    log "Preparation complete. Complete the manual steps in the README, then run:"
    log "  ./setup.sh --$MODE --start"
    return
  fi

  check_drive || die "The media drive must be mounted before starting the stack."
  if [[ "$MODE" == "vpn" ]]; then
    check_vpn_requirements || die "Complete README section 4 before starting VPN mode."
  fi
  check_compose || die "Fix the Compose configuration errors above and try again."
  "${compose[@]}" --env-file "$ENV_FILE" up -d
  log ""
  ok "Containers started. Run ./setup.sh --$MODE --doctor to check the setup."
}

main
