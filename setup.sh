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
CONFIGURE=false

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--vpn | --no-vpn] [--start] [--configure] [--doctor]

Prepare this media-server project for a new server.

Options:
  --vpn       Use the default VPN setup (NordVPN/Gluetun). This is the default.
  --no-vpn    Run qBittorrent directly, using docker-compose.no-vpn.yml.
  --start     Validate the selected setup and start the containers.
  --configure Apply safe Sonarr, Radarr, and Prowlarr defaults after startup.
  --doctor    Run checks only; do not create or change files.
  -h, --help  Show this help.

Examples:
  ./setup.sh                 # Create folders and a safe .env template
  ./setup.sh --no-vpn        # Prepare the direct-connection setup
  ./setup.sh --vpn --start   # Validate and start the default VPN setup
  ./setup.sh --vpn --configure
  ./setup.sh --vpn --start --configure
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
    --configure) CONFIGURE=true ;;
    --doctor) DOCTOR=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $argument (run ./setup.sh --help)" ;;
  esac
done

if "$DOCTOR" && { "$START" || "$CONFIGURE"; }; then
  die "Do not combine --doctor with --start or --configure."
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
    ok "Using the server's local disk for media at $MEDIA_DIR"
    warn "No separate drive is mounted there; media will use space on the server's system disk."
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
  check_drive
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

require_configure_tools() {
  command -v curl >/dev/null 2>&1 || die "curl is required for --configure."
  command -v jq >/dev/null 2>&1 || die "jq is required for --configure. Install it with: sudo apt install -y jq"
}

api_key() {
  local service=$1 file="$PROJECT_DIR/$1/config/config.xml"
  [[ -f "$file" ]] || die "$service has not created its config file yet. Start the stack and wait a moment."
  sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$file" | tail -n 1
}

wait_for_arr() {
  local service=$1 port=$2 key=$3 attempts=30
  while (( attempts > 0 )); do
    if curl --fail --silent --show-error --max-time 5 \
      -H "X-Api-Key: $key" "http://127.0.0.1:$port/api/v3/system/status" >/dev/null; then
      ok "$service is ready"
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 2
  done
  die "$service did not become ready. Run ./setup.sh --$MODE --doctor and inspect its logs."
}

wait_for_prowlarr() {
  local key=$1 attempts=30
  while (( attempts > 0 )); do
    if curl --fail --silent --show-error --max-time 5 \
      -H "X-Api-Key: $key" http://127.0.0.1:9696/api/v1/system/status >/dev/null; then
      ok "Prowlarr is ready"
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 2
  done
  die "Prowlarr did not become ready. Run ./setup.sh --$MODE --doctor and inspect its logs."
}

arr_request() {
  local port=$1 key=$2 method=$3 path=$4
  shift 4
  curl --fail --silent --show-error --max-time 20 \
    -H "X-Api-Key: $key" \
    -H "Content-Type: application/json" \
    -X "$method" "http://127.0.0.1:$port/api/v3$path" "$@"
}

ensure_root_folder() {
  local service=$1 port=$2 key=$3 path=$4 folders
  folders=$(arr_request "$port" "$key" GET /rootfolder)
  if jq -e --arg path "$path" 'any(.[]; .path == $path)' >/dev/null <<<"$folders"; then
    ok "$service root folder already exists: $path"
  else
    arr_request "$port" "$key" POST /rootfolder --data "$(jq -nc --arg path "$path" '{path: $path}')" >/dev/null
    ok "Added $service root folder: $path"
  fi
}

qbit_login() {
  local response
  response=$(curl --fail --silent --show-error --max-time 10 \
    --data-urlencode "username=$QBITTORRENT_USERNAME" \
    --data-urlencode "password=$QBITTORRENT_PASSWORD" \
    http://127.0.0.1:8080/api/v2/auth/login)
  [[ "$response" == "Ok." ]] || die "qBittorrent rejected the supplied Web UI username or password."
  ok "qBittorrent credentials were accepted"
}

ensure_qbittorrent_client() {
  local service=$1 port=$2 key=$3 category=$4 host schema payload clients
  if [[ "$MODE" == "vpn" ]]; then host="gluetun"; else host="qbittorrent"; fi
  clients=$(arr_request "$port" "$key" GET /downloadclient)
  if jq -e 'any(.[]; .implementation == "QBittorrent")' >/dev/null <<<"$clients"; then
    ok "$service already has a qBittorrent download client"
    return
  fi

  schema=$(arr_request "$port" "$key" GET /downloadclient/schema)
  payload=$(jq -c \
    --arg host "$host" --arg username "$QBITTORRENT_USERNAME" \
    --arg password "$QBITTORRENT_PASSWORD" --arg category "$category" '
      map(select(.implementation == "QBittorrent")) | .[0] |
      .enable = true | .name = "qBittorrent" |
      .fields |= map(
        if .name == "host" then .value = $host
        elif .name == "port" then .value = (if (.value | type) == "number" then 8080 else "8080" end)
        elif .name == "username" then .value = $username
        elif .name == "password" then .value = $password
        elif .name == "category" then .value = $category
        else . end
      )
    ' <<<"$schema")
  [[ -n "$payload" && "$payload" != "null" ]] || die "Could not find qBittorrent's configuration schema in $service."
  arr_request "$port" "$key" POST /downloadclient --data "$payload" >/dev/null
  ok "Added qBittorrent to $service"
}

prowlarr_request() {
  local key=$1 method=$2 path=$3
  shift 3
  curl --fail --silent --show-error --max-time 20 \
    -H "X-Api-Key: $key" \
    -H "Content-Type: application/json" \
    -X "$method" "http://127.0.0.1:9696/api/v1$path" "$@"
}

ensure_prowlarr_app() {
  local implementation=$1 base_url=$2 target_key=$3 key=$4 apps schema payload
  apps=$(prowlarr_request "$key" GET /applications)
  if jq -e --arg implementation "$implementation" 'any(.[]; .implementation == $implementation)' >/dev/null <<<"$apps"; then
    ok "Prowlarr is already connected to $implementation"
    return
  fi
  schema=$(prowlarr_request "$key" GET /applications/schema)
  payload=$(jq -c \
    --arg implementation "$implementation" --arg base_url "$base_url" --arg api_key "$target_key" '
      map(select(.implementation == $implementation)) | .[0] |
      .enable = true | .name = $implementation |
      .fields |= map(
        if .name == "baseUrl" then .value = $base_url
        elif .name == "apiKey" then .value = $api_key
        elif .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
        else . end
      )
    ' <<<"$schema")
  [[ -n "$payload" && "$payload" != "null" ]] || die "Could not find the $implementation schema in Prowlarr."
  prowlarr_request "$key" POST /applications --data "$payload" >/dev/null
  ok "Connected Prowlarr to $implementation"
}

configure_apps() {
  local sonarr_key radarr_key prowlarr_key username
  require_configure_tools
  check_drive
  sonarr_key=$(api_key sonarr)
  radarr_key=$(api_key radarr)
  prowlarr_key=$(api_key prowlarr)
  [[ -n "$sonarr_key" && -n "$radarr_key" && -n "$prowlarr_key" ]] || die "Could not read an application API key."
  wait_for_arr Sonarr 8989 "$sonarr_key"
  wait_for_arr Radarr 7878 "$radarr_key"
  wait_for_prowlarr "$prowlarr_key"

  read -r -p "qBittorrent Web UI username [admin]: " username
  QBITTORRENT_USERNAME=${username:-admin}
  read -r -s -p "qBittorrent Web UI password: " QBITTORRENT_PASSWORD
  printf '\n'
  [[ -n "$QBITTORRENT_PASSWORD" ]] || die "A qBittorrent password is required."
  qbit_login

  ensure_root_folder Sonarr 8989 "$sonarr_key" /data/media/tv
  ensure_qbittorrent_client Sonarr 8989 "$sonarr_key" tv
  ensure_root_folder Radarr 7878 "$radarr_key" /data/media/movies
  ensure_qbittorrent_client Radarr 7878 "$radarr_key" movies
  ensure_prowlarr_app Sonarr http://sonarr:8989 "$sonarr_key" "$prowlarr_key"
  ensure_prowlarr_app Radarr http://radarr:7878 "$radarr_key" "$prowlarr_key"

  log ""
  ok "Safe defaults were applied. Configure indexers, subtitles, Jellyfin, Seerr, and Heimdall in their web interfaces."
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

  if "$START"; then
    check_drive
    if [[ "$MODE" == "vpn" ]]; then
      check_vpn_requirements || die "Complete README section 4 before starting VPN mode."
    fi
    check_compose || die "Fix the Compose configuration errors above and try again."
    "${compose[@]}" --env-file "$ENV_FILE" up -d
    log ""
    ok "Containers started."
  fi

  if "$CONFIGURE"; then
    configure_apps
  fi

  if ! "$START" && ! "$CONFIGURE"; then
    log ""
    log "Preparation complete. Complete the manual steps in the README, then run:"
    log "  ./setup.sh --$MODE --start"
  fi
}

main
