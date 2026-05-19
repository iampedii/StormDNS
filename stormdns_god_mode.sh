#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="${STORMDNS_ROOT:-${SCRIPT_DIR}}"
DOCKER_DIR="${STORMDNS_DOCKER_DIR:-}"
DOCKER_CONFIG_DIR=""
HOST_CONFIG="${STORMDNS_CONFIG:-}"
KEY_FILE="${STORMDNS_KEY_FILE:-}"
SERVER_BIN="${STORMDNS_SERVER_BIN:-}"
PROXY_BIN="${STORMDNS_PROXY_BIN:-}"
COMPOSE_FILE=""
DOCKERFILE=""
PROXY_UNIT="/etc/systemd/system/stormdns-proxy.service"
BACKUP_ROOT=""

NETWORK_NAME="stormdns_net"
SUBNET="172.30.0.0/24"
BACKEND_PREFIX="172.30.0"
BACKEND_START_OCTET=11
LISTEN_ADDR="0.0.0.0:53"
MAX_SESSIONS_PER_BACKEND=245
SESSION_TTL="120s"
BUSY_COOLDOWN="20s"
PROXY_TIMEOUT="4s"

INSTANCES=""
BUILD="yes"
RECREATE="yes"
NON_INTERACTIVE="no"
ASSUME_YES="no"

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Starts the StormDNS Docker backend cluster and the aware UDP proxy frontend.

Options:
  --instances N           Number of StormDNS backend containers.
  --root DIR              StormDNS install directory. Default: script directory.
  --docker-dir DIR        Docker project directory. Default: ROOT/stormdns-docker.
  --server-bin PATH       StormDNS server binary. Auto-detected by default.
  --proxy-bin PATH        StormDNS proxy binary. Auto-detected by default.
  --config PATH           Host server_config.toml. Default: ROOT/server_config.toml.
  --key PATH              Host encrypt_key.txt. Default: config ENCRYPTION_KEY_FILE.
  --listen ADDR           Proxy listen address. Default: ${LISTEN_ADDR}.
  --max-sessions N        Soft active sessions per backend. Default: ${MAX_SESSIONS_PER_BACKEND}.
  --session-ttl DURATION  Proxy session route TTL. Default: ${SESSION_TTL}.
  --busy-cooldown DUR     Backend cooldown after SESSION_BUSY. Default: ${BUSY_COOLDOWN}.
  --timeout DURATION      Backend response timeout. Default: ${PROXY_TIMEOUT}.
  --no-build              Do not rebuild the Docker image.
  --no-recreate           Do not force recreate containers.
  --non-interactive       Use defaults and fail instead of prompting.
  -y, --yes               Do not ask for final confirmation.
  -h, --help              Show this help.
EOF
}

log() {
  printf '[stormdns-god] %s\n' "$*"
}

die() {
  printf '[stormdns-god] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root: sudo $0"
}

require_file() {
  [[ -e "$1" ]] || die "missing required file: $1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

prompt_read() {
  local prompt="$1"
  local var_name="$2"
  local answer=""

  if [[ "${NON_INTERACTIVE}" == "yes" ]]; then
    printf -v "${var_name}" '%s' ""
    return
  fi

  if [[ -r /dev/tty ]]; then
    read -r -p "${prompt}" answer </dev/tty || true
  else
    read -r -p "${prompt}" answer || true
  fi
  printf -v "${var_name}" '%s' "${answer}"
}

ask_yes_no() {
  local prompt="$1"
  local default="$2"
  local answer

  if [[ "${NON_INTERACTIVE}" == "yes" ]]; then
    [[ "${default}" == "yes" ]]
    return
  fi

  while true; do
    if [[ "${default}" == "yes" ]]; then
      prompt_read "${prompt} [Y/n]: " answer
      answer="${answer:-y}"
    else
      prompt_read "${prompt} [y/N]: " answer
      answer="${answer:-n}"
    fi

    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer yes or no.\n' ;;
    esac
  done
}

docker_compose() {
  docker compose "$@"
}

backup_file() {
  local path="$1"
  local backup_dir="$2"
  if [[ -e "${path}" ]]; then
    mkdir -p "${backup_dir}"
    cp -a "${path}" "${backup_dir}/"
  fi
}

ask_instances() {
  local current default answer
  current="$(docker ps --format '{{.Names}}' 2>/dev/null | awk '/^stormdns-[0-9]+$/ { n++ } END { print n+0 }')"
  if [[ "${current}" -gt 0 ]]; then
    default="${current}"
  else
    default="8"
  fi

  if [[ "${NON_INTERACTIVE}" == "yes" ]]; then
    printf '%s\n' "${default}"
    return
  fi

  while true; do
    prompt_read "How many total StormDNS containers should run? [${default}]: " answer
    answer="${answer:-$default}"
    if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= 200 )); then
      printf '%s\n' "${answer}"
      return
    fi
    printf 'Please enter a number from 1 to 200.\n'
  done
}

set_toml_string() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = \"${value}\"|" "${file}"
  else
    printf '%s = "%s"\n' "${key}" "${value}" >> "${file}"
  fi
}

set_toml_number() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
  else
    printf '%s = %s\n' "${key}" "${value}" >> "${file}"
  fi
}

set_toml_array_strings() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
  else
    printf '%s = %s\n' "${key}" "${value}" >> "${file}"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

domain_array_literal() {
  local raw="$1"
  local item out
  local -a items=()
  out=""
  IFS=',' read -r -a items <<< "${raw}"
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    [[ -n "${item}" ]] || continue
    [[ "${item}" =~ ^[A-Za-z0-9*._-]+$ ]] || die "invalid domain: ${item}"
    if [[ -n "${out}" ]]; then
      out+=", "
    fi
    out+="\"${item}\""
  done
  [[ -n "${out}" ]] || die "at least one domain is required"
  printf '[%s]\n' "${out}"
}

config_value() {
  local file="$1"
  local key="$2"
  sed -n -E "s|^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]+)\"?.*|\\1|p" "${file}" | tail -n1 | xargs || true
}

config_dir() {
  dirname "${HOST_CONFIG}"
}

resolve_key_file() {
  local configured
  if [[ -n "${KEY_FILE}" ]]; then
    printf '%s\n' "${KEY_FILE}"
    return
  fi

  configured="$(config_value "${HOST_CONFIG}" "ENCRYPTION_KEY_FILE")"
  configured="${configured:-encrypt_key.txt}"
  if [[ "${configured}" == /* ]]; then
    printf '%s\n' "${configured}"
  else
    printf '%s/%s\n' "$(config_dir)" "${configured}"
  fi
}

required_key_length() {
  local method="$1"
  case "${method}" in
    3) printf '16\n' ;;
    4) printf '24\n' ;;
    *) printf '32\n' ;;
  esac
}

generate_key() {
  local length="$1"
  local bytes
  bytes=$(((length + 1) / 2))
  od -An -N "${bytes}" -tx1 /dev/urandom | tr -d ' \n' | cut -c1-"${length}"
}

ensure_key_file() {
  local method required existing answer generated key_dir
  method="$(config_value "${HOST_CONFIG}" "DATA_ENCRYPTION_METHOD")"
  method="${method:-1}"
  required="$(required_key_length "${method}")"
  KEY_FILE="$(resolve_key_file)"
  key_dir="$(dirname "${KEY_FILE}")"
  mkdir -p "${key_dir}"

  if [[ -f "${KEY_FILE}" ]]; then
    existing="$(tr -d '[:space:]' < "${KEY_FILE}")"
    if [[ "${#existing}" -eq "${required}" ]]; then
      chmod 600 "${KEY_FILE}" || true
      return
    fi
    log "Existing key has length ${#existing}; expected ${required} for DATA_ENCRYPTION_METHOD=${method}"
    if ! ask_yes_no "Replace ${KEY_FILE} with a new generated key?" "no"; then
      die "valid encryption key is required"
    fi
  elif ! ask_yes_no "Generate encryption key at ${KEY_FILE}?" "yes"; then
    while true; do
      prompt_read "Enter encryption key (${required} characters): " answer
      answer="$(trim "${answer}")"
      if [[ "${#answer}" -eq "${required}" ]]; then
        printf '%s' "${answer}" > "${KEY_FILE}"
        chmod 600 "${KEY_FILE}"
        return
      fi
      printf 'Key must be exactly %s characters.\n' "${required}"
    done
  fi

  require_command od
  generated="$(generate_key "${required}")"
  printf '%s' "${generated}" > "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
}

ensure_config() {
  local domains literal
  if [[ ! -f "${HOST_CONFIG}" && -f "${ROOT_DIR}/server_config.toml.simple" ]]; then
    cp -a "${ROOT_DIR}/server_config.toml.simple" "${HOST_CONFIG}"
    log "Created ${HOST_CONFIG} from server_config.toml.simple"
  fi
  require_file "${HOST_CONFIG}"

  if grep -Eq '^[[:space:]]*DOMAIN[[:space:]]*=.*v\.domain\.com|^[[:space:]]*DOMAIN[[:space:]]*=[[:space:]]*\[[[:space:]]*\]' "${HOST_CONFIG}"; then
    if [[ "${NON_INTERACTIVE}" == "yes" ]]; then
      die "DOMAIN must be configured in ${HOST_CONFIG}"
    fi
    while true; do
      prompt_read "Enter tunnel domain(s), comma-separated (example: v.example.com): " domains
      domains="$(trim "${domains}")"
      [[ -n "${domains}" ]] || continue
      literal="$(domain_array_literal "${domains}")"
      set_toml_array_strings "${HOST_CONFIG}" "DOMAIN" "${literal}"
      break
    done
  fi

  ensure_key_file
}

first_existing_binary() {
  local candidate
  for candidate in "$@"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

detect_server_bin() {
  local candidates=()
  shopt -s nullglob
  candidates+=("${ROOT_DIR}/stormdns-server")
  candidates+=("${ROOT_DIR}"/StormDNS_Server_Linux*_v*)
  candidates+=("${ROOT_DIR}"/StormDNS_Server_Linux*)
  candidates+=("${ROOT_DIR}"/StormDNS_Server_*)
  shopt -u nullglob
  first_existing_binary "${candidates[@]}"
}

detect_proxy_bin() {
  local candidates=()
  shopt -s nullglob
  candidates+=("${ROOT_DIR}/stormdns-proxy")
  candidates+=("${ROOT_DIR}"/StormDNS_Proxy_Linux*_v*)
  candidates+=("${ROOT_DIR}"/StormDNS_Proxy_Linux*)
  candidates+=("${ROOT_DIR}"/StormDNS_Proxy_*)
  shopt -u nullglob
  first_existing_binary "${candidates[@]}"
}

install_runtime_binary() {
  local src="$1"
  local dst="$2"
  local tmp
  require_file "${src}"
  mkdir -p "$(dirname "${dst}")"
  if [[ "$(readlink -f "${src}")" != "$(readlink -f "${dst}" 2>/dev/null || true)" ]]; then
    tmp="${dst}.tmp.$$"
    cp -f "${src}" "${tmp}"
    chmod 755 "${tmp}"
    mv -f "${tmp}" "${dst}"
  else
    chmod 755 "${dst}"
  fi
}

resolve_binaries() {
  if [[ -z "${SERVER_BIN}" ]]; then
    SERVER_BIN="$(detect_server_bin || true)"
  fi
  if [[ -z "${PROXY_BIN}" ]]; then
    PROXY_BIN="$(detect_proxy_bin || true)"
  fi
  [[ -n "${SERVER_BIN}" ]] || die "StormDNS server binary not found; pass --server-bin"
  [[ -n "${PROXY_BIN}" ]] || die "StormDNS proxy binary not found; pass --proxy-bin"

  install_runtime_binary "${SERVER_BIN}" "${ROOT_DIR}/stormdns-server"
  install_runtime_binary "${PROXY_BIN}" "${ROOT_DIR}/stormdns-proxy"
  SERVER_BIN="${ROOT_DIR}/stormdns-server"
  PROXY_BIN="${ROOT_DIR}/stormdns-proxy"
}

prepare_docker_files() {
  mkdir -p "${DOCKER_CONFIG_DIR}"
  cp -a "${SERVER_BIN}" "${DOCKER_DIR}/stormdns-server"
  cp -a "${HOST_CONFIG}" "${DOCKER_CONFIG_DIR}/server_config.toml"
  cp -a "${KEY_FILE}" "${DOCKER_CONFIG_DIR}/encrypt_key.txt"
  chmod +x "${DOCKER_DIR}/stormdns-server"
  chmod 600 "${DOCKER_CONFIG_DIR}/encrypt_key.txt"

  set_toml_string "${DOCKER_CONFIG_DIR}/server_config.toml" "UDP_HOST" "0.0.0.0"
  set_toml_number "${DOCKER_CONFIG_DIR}/server_config.toml" "UDP_PORT" "53"
  set_toml_string "${DOCKER_CONFIG_DIR}/server_config.toml" "ENCRYPTION_KEY_FILE" "/config/encrypt_key.txt"

  cat > "${DOCKERFILE}" <<'EOF'
FROM debian:bookworm-slim

WORKDIR /app

COPY stormdns-server /app/stormdns-server
COPY config/server_config.toml /config/server_config.toml
COPY config/encrypt_key.txt /config/encrypt_key.txt

ENTRYPOINT ["/app/stormdns-server"]
CMD ["-config", "/config/server_config.toml"]
EOF
}

write_compose() {
  local instances="$1"
  local i ip

  {
    cat <<EOF
x-stormdns-common: &stormdns-common
  build: .
  restart: unless-stopped
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  healthcheck:
    test: ["CMD-SHELL", "grep -qi ':0035 ' /proc/net/udp /proc/net/udp6 || exit 1"]
    interval: 10s
    timeout: 3s
    retries: 3
    start_period: 10s

services:
EOF
    for ((i = 1; i <= instances; i++)); do
      ip="${BACKEND_PREFIX}.$((BACKEND_START_OCTET + i - 1))"
      cat <<EOF
  stormdns-${i}:
    <<: *stormdns-common
    container_name: stormdns-${i}
    networks:
      ${NETWORK_NAME}:
        ipv4_address: ${ip}

EOF
    done
    cat <<EOF
networks:
  ${NETWORK_NAME}:
    driver: bridge
    ipam:
      config:
        - subnet: ${SUBNET}
EOF
  } > "${COMPOSE_FILE}"
}

backend_list() {
  local instances="$1"
  local i ip list
  list=""
  for ((i = 1; i <= instances; i++)); do
    ip="${BACKEND_PREFIX}.$((BACKEND_START_OCTET + i - 1))"
    if [[ -n "${list}" ]]; then
      list+=","
    fi
    list+="${ip}:53"
  done
  printf '%s\n' "${list}"
}

stop_unit_hard() {
  local unit="$1"
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    log "Stopping ${unit}"
    systemctl stop "${unit}" >/dev/null 2>&1 || true
    for _ in {1..10}; do
      systemctl is-active --quiet "${unit}" || return 0
      sleep 1
    done
    log "${unit} did not stop cleanly; killing main process"
    systemctl kill --kill-who=main -s SIGKILL "${unit}" >/dev/null 2>&1 || true
    sleep 1
  fi
}

disable_legacy_services() {
  if systemctl list-unit-files --all 2>/dev/null | grep -q '^stormdns\.service'; then
    log "Stopping/disabling legacy stormdns.service"
    systemctl stop stormdns >/dev/null 2>&1 || true
    systemctl disable stormdns >/dev/null 2>&1 || true
    systemctl reset-failed stormdns >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files --all 2>/dev/null | grep -q '^stormdns-ipvs\.service'; then
    log "Stopping/disabling old stormdns-ipvs.service"
    systemctl stop stormdns-ipvs >/dev/null 2>&1 || true
    systemctl disable stormdns-ipvs >/dev/null 2>&1 || true
    systemctl reset-failed stormdns-ipvs >/dev/null 2>&1 || true
  fi

  if command -v ipvsadm >/dev/null 2>&1; then
    ipvsadm -C >/dev/null 2>&1 || true
  fi
}

write_proxy_unit() {
  local backends="$1"
  cat > "${PROXY_UNIT}" <<EOF
[Unit]
Description=StormDNS aware UDP frontend
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${ROOT_DIR}
ExecStart=${PROXY_BIN} -config ${HOST_CONFIG} -listen ${LISTEN_ADDR} -backends ${backends} -max-sessions ${MAX_SESSIONS_PER_BACKEND} -session-ttl ${SESSION_TTL} -busy-cooldown ${BUSY_COOLDOWN} -timeout ${PROXY_TIMEOUT}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

start_stack() {
  local build="$1"
  local recreate="$2"
  local args
  local container

  args=(up -d)
  if [[ "${build}" == "yes" ]]; then
    args+=(--build)
  fi
  if [[ "${recreate}" == "yes" ]]; then
    args+=(--force-recreate --remove-orphans)
  else
    args+=(--remove-orphans)
  fi

  log "Starting Docker containers"
  (cd "${DOCKER_DIR}" && docker_compose "${args[@]}")

  log "Ensuring Docker restart policy"
  for container in $(seq 1 "${INSTANCES}"); do
    docker update --restart unless-stopped "stormdns-${container}" >/dev/null
  done
}

show_status() {
  log "Container status"
  (cd "${DOCKER_DIR}" && docker_compose ps)

  log "Proxy status"
  systemctl --no-pager --full status stormdns-proxy.service | sed -n '1,14p' || true

  log "UDP listeners on port 53"
  ss -lunp | awk 'NR == 1 || /:53[[:space:]]/'
}

confirm_summary() {
  if [[ "${ASSUME_YES}" == "yes" || "${NON_INTERACTIVE}" == "yes" ]]; then
    return
  fi

  cat <<EOF

StormDNS god-mode plan:
  Install directory: ${ROOT_DIR}
  Docker project:    ${DOCKER_DIR}
  Host config:       ${HOST_CONFIG}
  Host key:          ${KEY_FILE}
  Server binary:     ${SERVER_BIN}
  Proxy binary:      ${PROXY_BIN}
  Containers:        ${INSTANCES}
  Listen address:    ${LISTEN_ADDR}

EOF
  ask_yes_no "Proceed with cluster rebuild/start?" "yes" || die "aborted"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instances)
      INSTANCES="${2:-}"
      shift 2
      ;;
    --instances=*)
      INSTANCES="${1#*=}"
      shift
      ;;
    --root)
      ROOT_DIR="${2:-}"
      shift 2
      ;;
    --root=*)
      ROOT_DIR="${1#*=}"
      shift
      ;;
    --docker-dir)
      DOCKER_DIR="${2:-}"
      shift 2
      ;;
    --docker-dir=*)
      DOCKER_DIR="${1#*=}"
      shift
      ;;
    --server-bin)
      SERVER_BIN="${2:-}"
      shift 2
      ;;
    --server-bin=*)
      SERVER_BIN="${1#*=}"
      shift
      ;;
    --proxy-bin)
      PROXY_BIN="${2:-}"
      shift 2
      ;;
    --proxy-bin=*)
      PROXY_BIN="${1#*=}"
      shift
      ;;
    --config)
      HOST_CONFIG="${2:-}"
      shift 2
      ;;
    --config=*)
      HOST_CONFIG="${1#*=}"
      shift
      ;;
    --key)
      KEY_FILE="${2:-}"
      shift 2
      ;;
    --key=*)
      KEY_FILE="${1#*=}"
      shift
      ;;
    --listen)
      LISTEN_ADDR="${2:-}"
      shift 2
      ;;
    --listen=*)
      LISTEN_ADDR="${1#*=}"
      shift
      ;;
    --max-sessions)
      MAX_SESSIONS_PER_BACKEND="${2:-}"
      shift 2
      ;;
    --max-sessions=*)
      MAX_SESSIONS_PER_BACKEND="${1#*=}"
      shift
      ;;
    --session-ttl)
      SESSION_TTL="${2:-}"
      shift 2
      ;;
    --session-ttl=*)
      SESSION_TTL="${1#*=}"
      shift
      ;;
    --busy-cooldown)
      BUSY_COOLDOWN="${2:-}"
      shift 2
      ;;
    --busy-cooldown=*)
      BUSY_COOLDOWN="${1#*=}"
      shift
      ;;
    --timeout)
      PROXY_TIMEOUT="${2:-}"
      shift 2
      ;;
    --timeout=*)
      PROXY_TIMEOUT="${1#*=}"
      shift
      ;;
    --no-build)
      BUILD="no"
      shift
      ;;
    --no-recreate)
      RECREATE="no"
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE="yes"
      shift
      ;;
    -y|--yes)
      ASSUME_YES="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

ROOT_DIR="$(cd "${ROOT_DIR}" && pwd -P)"
DOCKER_DIR="${DOCKER_DIR:-${ROOT_DIR}/stormdns-docker}"
DOCKER_CONFIG_DIR="${DOCKER_DIR}/config"
HOST_CONFIG="${HOST_CONFIG:-${ROOT_DIR}/server_config.toml}"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
DOCKERFILE="${DOCKER_DIR}/Dockerfile"
BACKUP_ROOT="${ROOT_DIR}/stormdns-backups"

require_root
require_command docker
docker compose version >/dev/null 2>&1 || die "docker compose plugin is missing"
require_command systemctl
require_command ss
require_command sed
require_command awk

ensure_config
resolve_binaries

if [[ -z "${INSTANCES}" ]]; then
  INSTANCES="$(ask_instances)"
fi

if ! [[ "${INSTANCES}" =~ ^[0-9]+$ ]] || (( INSTANCES < 1 || INSTANCES > 200 )); then
  die "--instances must be a number from 1 to 200"
fi

if ! [[ "${MAX_SESSIONS_PER_BACKEND}" =~ ^[0-9]+$ ]] || (( MAX_SESSIONS_PER_BACKEND < 1 )); then
  die "--max-sessions must be a positive number"
fi

confirm_summary

BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%d%H%M%S)-god-mode"
log "Creating backup in ${BACKUP_DIR}"
backup_file "${COMPOSE_FILE}" "${BACKUP_DIR}"
backup_file "${DOCKERFILE}" "${BACKUP_DIR}"
backup_file "${DOCKER_CONFIG_DIR}/server_config.toml" "${BACKUP_DIR}"
backup_file "${PROXY_UNIT}" "${BACKUP_DIR}"

log "Preparing Docker project for ${INSTANCES} instances"
prepare_docker_files
write_compose "${INSTANCES}"

BACKENDS="$(backend_list "${INSTANCES}")"
log "Backend list: ${BACKENDS}"

disable_legacy_services
stop_unit_hard stormdns-proxy.service
write_proxy_unit "${BACKENDS}"

systemctl daemon-reload
systemctl enable docker.service >/dev/null 2>&1 || true
systemctl enable stormdns-proxy.service >/dev/null

start_stack "${BUILD}" "${RECREATE}"

log "Starting proxy"
systemctl restart stormdns-proxy.service

show_status

log "Done. Backup: ${BACKUP_DIR}"
