#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="${STORMDNS_ROOT:-}"
SOURCE_DIR="${STORMDNS_SOURCE_DIR:-}"
DOCKER_DIR="${STORMDNS_DOCKER_DIR:-}"
DOCKER_CONFIG_DIR=""
HOST_CONFIG="${STORMDNS_CONFIG:-}"
KEY_FILE="${STORMDNS_KEY_FILE:-}"
SERVER_BIN="${STORMDNS_SERVER_BIN:-}"
PROXY_BIN="${STORMDNS_PROXY_BIN:-}"
COMPOSE_FILE=""
DOCKERFILE=""
WARP_EGRESS_SCRIPT=""
PROXY_UNIT="/etc/systemd/system/stormdns-proxy.service"
WARP_EGRESS_UNIT="/etc/systemd/system/stormdns-warp-egress.service"
SYSCTL_FILE="/etc/sysctl.d/99-stormdns.conf"
LIMITS_FILE="/etc/security/limits.d/99-stormdns.conf"
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
BINARY_BUILD="yes"
RECREATE="yes"
NON_INTERACTIVE="no"
CONFIRM="no"
WARP_EGRESS="yes"
REGENERATE_KEY="no"

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Starts the StormDNS Docker backend cluster and the aware UDP proxy frontend.

Options:
  --instances N           Number of StormDNS backend containers.
  --root DIR              StormDNS install directory. Default: script directory.
  --docker-dir DIR        Docker project directory. Default: ROOT/stormdns-docker.
  --source-dir DIR        Go source tree. Auto-detected by default.
  --server-bin PATH       StormDNS server binary. Used when source build is disabled/unavailable.
  --proxy-bin PATH        StormDNS proxy binary. Used when source build is disabled/unavailable.
  --config PATH           Host server_config.toml. Default: ROOT/server_config.toml.
  --key PATH              Host encrypt_key.txt. Default: config ENCRYPTION_KEY_FILE.
  --listen ADDR           Proxy listen address. Default: ${LISTEN_ADDR}.
  --max-sessions N        Soft active sessions per backend. Default: ${MAX_SESSIONS_PER_BACKEND}.
  --session-ttl DURATION  Proxy session route TTL. Default: ${SESSION_TTL}.
  --busy-cooldown DUR     Backend cooldown after SESSION_BUSY. Default: ${BUSY_COOLDOWN}.
  --timeout DURATION      Backend response timeout. Default: ${PROXY_TIMEOUT}.
  --no-source-build       Do not build stormdns-server/proxy from local Go source.
  --no-build              Do not rebuild the Docker image.
  --no-recreate           Do not force recreate containers.
  --no-warp-egress        Do not install/restart WARP egress routing helper.
  --regenerate-key        Replace an invalid existing encryption key without prompting.
  --confirm               Ask for confirmation before changing files/services.
  --non-interactive       Use defaults and fail instead of prompting.
  -y, --yes               Accepted for compatibility; god mode does not confirm by default.
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

package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt\n'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf\n'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum\n'
  else
    return 1
  fi
}

refresh_package_index() {
  local pm="$1"
  case "${pm}" in
    apt)
      if [[ "${APT_UPDATED:-no}" != "yes" ]]; then
        log "Updating apt package index"
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
        APT_UPDATED="yes"
      fi
      ;;
  esac
}

install_package() {
  local pm="$1"
  local package="$2"
  case "${pm}" in
    apt)
      refresh_package_index "${pm}"
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${package}" >/dev/null
      ;;
    dnf)
      dnf -y install "${package}" >/dev/null
      ;;
    yum)
      yum -y install "${package}" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

install_first_available_package() {
  local label="$1"
  shift
  local pm package
  pm="$(package_manager)" || die "no supported package manager found to install ${label}"

  for package in "$@"; do
    log "Installing ${label}: ${package}"
    if install_package "${pm}" "${package}"; then
      return 0
    fi
    log "Package ${package} was not installable; trying next option"
  done

  die "failed to install ${label}; tried: $*"
}

has_docker_compose() {
  docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    return
  fi

  install_first_available_package "Go" golang-go golang
  require_command go
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    install_first_available_package "Docker" docker.io docker-ce moby-engine docker
  fi
  require_command docker

  if ! has_docker_compose; then
    install_first_available_package "Docker Compose" docker-compose-v2 docker-compose-plugin docker-compose
  fi
  has_docker_compose || die "Docker Compose is missing after install"

  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --all 2>/dev/null | grep -q '^docker\.service'; then
    log "Enabling and starting docker.service"
    systemctl enable --now docker.service >/dev/null 2>&1 || true
  fi
}

ensure_runtime_tools() {
  ensure_docker
  if [[ "${BINARY_BUILD}" == "yes" && -n "${SOURCE_DIR}" ]]; then
    ensure_go
  fi
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
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
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
  local method required existing generated key_dir
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
    [[ "${REGENERATE_KEY}" == "yes" ]] || die "valid encryption key is required; fix ${KEY_FILE} or rerun with --regenerate-key"
  fi

  require_command od
  generated="$(generate_key "${required}")"
  printf '%s' "${generated}" > "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
  log "Generated encryption key at ${KEY_FILE}"
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
      log "Configured DOMAIN = ${literal}"
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

detect_install_root() {
  if [[ -n "${ROOT_DIR}" ]]; then
    printf '%s\n' "${ROOT_DIR}"
    return
  fi

  if [[ -f "${SCRIPT_DIR}/go.mod" && -f "$(dirname "${SCRIPT_DIR}")/server_config.toml" ]]; then
    dirname "${SCRIPT_DIR}"
    return
  fi

  printf '%s\n' "${SCRIPT_DIR}"
}

source_tree_ready() {
  local dir="$1"
  [[ -n "${dir}" ]] || return 1
  [[ -f "${dir}/go.mod" && -f "${dir}/cmd/server/main.go" && -f "${dir}/cmd/stormdns-proxy/main.go" ]]
}

detect_source_dir() {
  local candidate
  if [[ -n "${SOURCE_DIR}" ]]; then
    source_tree_ready "${SOURCE_DIR}" || die "source tree is incomplete: ${SOURCE_DIR}"
    printf '%s\n' "${SOURCE_DIR}"
    return
  fi

  for candidate in "${ROOT_DIR}/StormDNS" "${SCRIPT_DIR}" "/root/StormDNS"; do
    if source_tree_ready "${candidate}"; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
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
  candidates+=("${SCRIPT_DIR}/stormdns-proxy")
  candidates+=("${SCRIPT_DIR}"/StormDNS_Proxy_Linux*_v*)
  candidates+=("/root/stormdns-proxy")
  candidates+=("/usr/local/bin/stormdns-proxy")
  shopt -u nullglob
  first_existing_binary "${candidates[@]}"
}

build_binaries_from_source() {
  local source_dir="$1"
  local build_dir
  if ! source_tree_ready "${source_dir}"; then
    return 1
  fi
  require_command go
  build_dir="$(mktemp -d /tmp/stormdns-god-build.XXXXXX)"
  log "Building stormdns-server and stormdns-proxy from source: ${source_dir}"
  (
    cd "${source_dir}"
    GOCACHE="${GOCACHE:-/tmp/stormdns-gocache}" GOTMPDIR="${GOTMPDIR:-/tmp}" go build -o "${build_dir}/stormdns-server" ./cmd/server
    GOCACHE="${GOCACHE:-/tmp/stormdns-gocache}" GOTMPDIR="${GOTMPDIR:-/tmp}" go build -o "${build_dir}/stormdns-proxy" ./cmd/stormdns-proxy
  )
  install_runtime_binary "${build_dir}/stormdns-server" "${ROOT_DIR}/stormdns-server"
  install_runtime_binary "${build_dir}/stormdns-proxy" "${ROOT_DIR}/stormdns-proxy"
  rm -rf "${build_dir}"
  SERVER_BIN="${ROOT_DIR}/stormdns-server"
  PROXY_BIN="${ROOT_DIR}/stormdns-proxy"
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
  if [[ "${BINARY_BUILD}" == "yes" && -n "${SOURCE_DIR}" ]]; then
    if build_binaries_from_source "${SOURCE_DIR}"; then
      return
    fi
  fi

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

systemd_unit_exists() {
  local unit="$1"
  systemctl list-unit-files --all "${unit}" 2>/dev/null | awk '{print $1}' | grep -Fxq "${unit}"
}

detect_docker_systemd_unit() {
  local unit
  for unit in docker.service snap.docker.dockerd.service podman.service containerd.service; do
    if systemd_unit_exists "${unit}"; then
      printf '%s\n' "${unit}"
      return 0
    fi
  done
  return 1
}

write_proxy_unit() {
  local backends="$1"
  local docker_unit after_line requires_line
  docker_unit="$(detect_docker_systemd_unit || true)"
  after_line="After=network.target"
  requires_line=""
  if [[ -n "${docker_unit}" ]]; then
    after_line="After=network.target ${docker_unit}"
    requires_line="Requires=${docker_unit}"
  else
    log "No Docker systemd unit found; writing proxy unit without a Docker service dependency"
  fi

  cat > "${PROXY_UNIT}" <<EOF
[Unit]
Description=StormDNS aware UDP frontend
${after_line}
${requires_line}

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

write_warp_egress_script() {
  cat > "${WARP_EGRESS_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DOCKER_SUBNET="${STORMDNS_DOCKER_SUBNET:-172.30.0.0/24}"
WARP_IFACE="${STORMDNS_WARP_IFACE:-}"
ROUTE_TABLE="${STORMDNS_WARP_TABLE:-53053}"
RULE_PRIORITY="${STORMDNS_WARP_RULE_PRIORITY:-10530}"
STRICT="${STORMDNS_WARP_STRICT:-0}"
STATE_FILE="${STORMDNS_WARP_STATE:-/run/stormdns-warp-egress.env}"

log() {
  printf '[stormdns-warp-egress] %s\n' "$*"
}

die() {
  printf '[stormdns-warp-egress] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

maybe_noop() {
  local reason="$1"
  if [[ "${STRICT}" == "1" ]]; then
    die "${reason}"
  fi
  log "${reason}; no-op"
  exit 0
}

iface_exists() {
  [[ -n "$1" ]] && ip link show dev "$1" >/dev/null 2>&1
}

detect_warp_iface() {
  local candidate name
  if [[ -n "${WARP_IFACE}" ]]; then
    iface_exists "${WARP_IFACE}" && printf '%s\n' "${WARP_IFACE}"
    return
  fi

  for candidate in warp0 wgcf CloudflareWARP cloudflare-warp wg0; do
    if iface_exists "${candidate}"; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  while IFS= read -r name; do
    case "${name,,}" in
      *warp*|wgcf*)
        if iface_exists "${name}"; then
          printf '%s\n' "${name}"
          return
        fi
        ;;
    esac
  done < <(ip -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }')
}

detect_docker_bridge() {
  ip -o route show "${DOCKER_SUBNET}" 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

iptables_ensure_append() {
  local table="$1"
  local chain="$2"
  shift 2
  if ! iptables -t "${table}" -C "${chain}" "$@" >/dev/null 2>&1; then
    iptables -t "${table}" -A "${chain}" "$@"
  fi
}

iptables_ensure_insert_first() {
  local table="$1"
  local chain="$2"
  shift 2
  if ! iptables -t "${table}" -C "${chain}" "$@" >/dev/null 2>&1; then
    iptables -t "${table}" -I "${chain}" 1 "$@"
  fi
}

iptables_delete_all() {
  local table="$1"
  local chain="$2"
  shift 2
  while iptables -t "${table}" -C "${chain}" "$@" >/dev/null 2>&1; do
    iptables -t "${table}" -D "${chain}" "$@" || break
  done
}

apply_routes() {
  local warp_iface docker_bridge
  warp_iface="$(detect_warp_iface || true)"
  [[ -n "${warp_iface}" ]] || maybe_noop "no WARP interface found"

  docker_bridge="$(detect_docker_bridge || true)"
  [[ -n "${docker_bridge}" ]] || maybe_noop "no route found for Docker subnet ${DOCKER_SUBNET}"

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  ip route replace "${DOCKER_SUBNET}" dev "${docker_bridge}" scope link table "${ROUTE_TABLE}"
  ip route replace default dev "${warp_iface}" table "${ROUTE_TABLE}"

  if ! ip rule show | grep -Eq "from ${DOCKER_SUBNET//./\\.} .* lookup ${ROUTE_TABLE}\$"; then
    ip rule add priority "${RULE_PRIORITY}" from "${DOCKER_SUBNET}" lookup "${ROUTE_TABLE}"
  fi

  iptables_ensure_insert_first raw PREROUTING -s "${DOCKER_SUBNET}" -p udp --dport 53 -m comment --comment stormdns-warp-egress -j RETURN
  iptables_ensure_append nat POSTROUTING -s "${DOCKER_SUBNET}" -o "${warp_iface}" -m comment --comment stormdns-warp-egress -j MASQUERADE
  iptables_ensure_append filter FORWARD -s "${DOCKER_SUBNET}" -o "${warp_iface}" -m comment --comment stormdns-warp-egress -j ACCEPT
  iptables_ensure_append filter FORWARD -d "${DOCKER_SUBNET}" -i "${warp_iface}" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment stormdns-warp-egress -j ACCEPT

  mkdir -p "$(dirname "${STATE_FILE}")"
  {
    printf 'DOCKER_SUBNET=%q\n' "${DOCKER_SUBNET}"
    printf 'WARP_IFACE=%q\n' "${warp_iface}"
    printf 'DOCKER_BRIDGE=%q\n' "${docker_bridge}"
    printf 'ROUTE_TABLE=%q\n' "${ROUTE_TABLE}"
    printf 'RULE_PRIORITY=%q\n' "${RULE_PRIORITY}"
  } > "${STATE_FILE}"

  log "enabled Docker subnet ${DOCKER_SUBNET} egress via ${warp_iface} table=${ROUTE_TABLE} bridge=${docker_bridge}"
}

clear_routes() {
  local warp_iface="${WARP_IFACE}"
  local subnet="${DOCKER_SUBNET}"
  local table="${ROUTE_TABLE}"
  local priority="${RULE_PRIORITY}"

  if [[ -r "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    warp_iface="${WARP_IFACE:-${warp_iface}}"
    subnet="${DOCKER_SUBNET:-${subnet}}"
    table="${ROUTE_TABLE:-${table}}"
    priority="${RULE_PRIORITY:-${priority}}"
  fi

  iptables_delete_all raw PREROUTING -s "${subnet}" -p udp --dport 53 -m comment --comment stormdns-warp-egress -j RETURN

  if [[ -n "${warp_iface}" ]]; then
    iptables_delete_all nat POSTROUTING -s "${subnet}" -o "${warp_iface}" -m comment --comment stormdns-warp-egress -j MASQUERADE
    iptables_delete_all filter FORWARD -s "${subnet}" -o "${warp_iface}" -m comment --comment stormdns-warp-egress -j ACCEPT
    iptables_delete_all filter FORWARD -d "${subnet}" -i "${warp_iface}" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment stormdns-warp-egress -j ACCEPT
  fi

  while ip rule show | grep -Eq "^[0-9]+:[[:space:]]+from ${subnet//./\\.} .* lookup ${table}\$"; do
    ip rule del priority "${priority}" from "${subnet}" lookup "${table}" >/dev/null 2>&1 || break
  done
  ip route flush table "${table}" >/dev/null 2>&1 || true
  rm -f "${STATE_FILE}"
  log "cleared Docker subnet ${subnet} WARP egress routing"
}

show_status() {
  log "interfaces matching WARP candidates:"
  ip -br link | awk 'tolower($1) ~ /warp|wgcf/ { print }' || true
  log "policy rules:"
  ip rule show | grep -E "from ${DOCKER_SUBNET//./\\.}|lookup ${ROUTE_TABLE}" || true
  log "table ${ROUTE_TABLE}:"
  ip route show table "${ROUTE_TABLE}" 2>/dev/null || true
  log "raw PREROUTING StormDNS exceptions:"
  iptables -t raw -S PREROUTING | grep -F "stormdns-warp-egress" || true
  log "nat POSTROUTING WARP MASQUERADE:"
  iptables -t nat -S POSTROUTING | grep -F "stormdns-warp-egress" || true
}

main() {
  local action="${1:-apply}"
  require_root
  require_command ip
  require_command iptables
  case "${action}" in
    apply)
      apply_routes
      ;;
    clear)
      clear_routes
      ;;
    status)
      show_status
      ;;
    *)
      die "usage: $0 [apply|clear|status]"
      ;;
  esac
}

main "$@"
EOF
  chmod 755 "${WARP_EGRESS_SCRIPT}"
}

write_warp_egress_unit() {
  local docker_unit after_line wants_line requires_line
  docker_unit="$(detect_docker_systemd_unit || true)"
  after_line="After=network-online.target warp-svc.service"
  wants_line="Wants=network-online.target"
  requires_line=""
  if [[ -n "${docker_unit}" ]]; then
    after_line="After=network-online.target ${docker_unit} warp-svc.service"
    requires_line="Requires=${docker_unit}"
  fi

  cat > "${WARP_EGRESS_UNIT}" <<EOF
[Unit]
Description=StormDNS Docker backend WARP egress routing
${after_line}
${wants_line}
${requires_line}
Before=stormdns-proxy.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=STORMDNS_DOCKER_SUBNET=${SUBNET}
Environment=STORMDNS_WARP_TABLE=53053
Environment=STORMDNS_WARP_RULE_PRIORITY=10530
Environment=STORMDNS_WARP_STRICT=0
ExecStart=${WARP_EGRESS_SCRIPT} apply
ExecStop=${WARP_EGRESS_SCRIPT} clear

[Install]
WantedBy=multi-user.target
EOF
}

apply_os_tuning() {
  cat > "${SYSCTL_FILE}" <<'EOF'
# StormDNS high-rate UDP tuning
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.core.optmem_max = 25165824
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.ipv4.udp_mem = 262144 524288 1048576
net.netfilter.nf_conntrack_max = 4194304
net.netfilter.nf_conntrack_udp_timeout = 10
net.netfilter.nf_conntrack_udp_timeout_stream = 30
net.ipv4.ip_local_port_range = 10240 65535
EOF

  cat > "${LIMITS_FILE}" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || log "Some sysctl values could not be applied on this kernel"
}

open_firewall_port_53() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
    ufw allow 53/udp >/dev/null 2>&1 || true
    ufw allow 53/tcp >/dev/null 2>&1 || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=53/udp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=53/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 53 -j ACCEPT || true
    iptables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 53 -j ACCEPT || true
  fi

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport 53 -j ACCEPT || true
    ip6tables -C INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 53 -j ACCEPT || true
  fi
}

check_port53_conflict() {
  local owner
  owner="$(ss -H -lunp 'sport = :53' 2>/dev/null || true)"
  [[ -z "${owner}" ]] && return 0
  if grep -q 'stormdns-proxy' <<< "${owner}"; then
    return 0
  fi
  printf '%s\n' "${owner}" >&2
  return 1
}

port53_owners() {
  ss -H -lunp 'sport = :53' 2>/dev/null | grep -v 'stormdns-proxy' || true
}

port53_pids() {
  port53_owners | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u
}

stop_socket_if_present() {
  local unit="$1"
  if systemctl list-unit-files --type=socket --all 2>/dev/null | awk '{print $1}' | grep -qx "${unit}"; then
    systemctl stop "${unit}" >/dev/null 2>&1 || true
    systemctl disable "${unit}" >/dev/null 2>&1 || true
  fi
}

stop_service_if_present() {
  local unit="$1"
  if systemctl list-unit-files --type=service --all 2>/dev/null | awk '{print $1}' | grep -qx "${unit}"; then
    systemctl stop "${unit}" >/dev/null 2>&1 || true
    systemctl disable "${unit}" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit}" >/dev/null 2>&1 || true
  fi
}

disable_systemd_resolved_stub() {
  if [[ -f /etc/systemd/resolved.conf ]]; then
    backup_file /etc/systemd/resolved.conf "${BACKUP_DIR}"
    if grep -q '^#\?DNSStubListener=' /etc/systemd/resolved.conf; then
      sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    else
      printf '\nDNSStubListener=no\n' >> /etc/systemd/resolved.conf
    fi
    if ! grep -q '^DNS=' /etc/systemd/resolved.conf; then
      printf 'DNS=1.1.1.1 8.8.8.8\n' >> /etc/systemd/resolved.conf
    fi
  fi

  systemctl restart systemd-resolved >/dev/null 2>&1 || true
  stop_socket_if_present systemd-resolved.socket
}

terminate_pid() {
  local pid="$1"
  local cmdline
  [[ -n "${pid}" ]] || return 0
  if ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi

  cmdline="$(ps -p "${pid}" -o cmd= 2>/dev/null || true)"
  if grep -qi 'stormdns-proxy' <<< "${cmdline}"; then
    return 0
  fi

  log "Stopping UDP/53 PID ${pid}: ${cmdline:-unknown}"
  kill "${pid}" 2>/dev/null || true
  for _ in 1 2 3; do
    sleep 1
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  done
  log "PID ${pid} did not stop; sending SIGKILL"
  kill -9 "${pid}" 2>/dev/null || true
}

release_port53_conflict() {
  local owners pid
  owners="$(port53_owners)"
  [[ -z "${owners}" ]] && return 0

  log "UDP/53 is already in use by:"
  printf '%s\n' "${owners}" >&2

  if [[ "${NON_INTERACTIVE}" == "yes" ]]; then
    die "UDP port 53 is already owned by another process"
  fi

  ask_yes_no "Stop/disable these UDP/53 owner(s) and continue?" "no" || die "UDP port 53 is already owned by another process"

  if grep -q 'systemd-resolve' <<< "${owners}"; then
    log "Disabling systemd-resolved DNS stub listener"
    disable_systemd_resolved_stub
  fi

  for unit in bind9.service named.service dnsmasq.service unbound.service pdns.service dnscrypt-proxy.service smartdns.service coredns.service; do
    stop_service_if_present "${unit}"
  done
  stop_socket_if_present dnsmasq.socket

  while IFS= read -r pid; do
    terminate_pid "${pid}"
  done < <(port53_pids)

  owners="$(port53_owners)"
  if [[ -n "${owners}" ]]; then
    printf '%s\n' "${owners}" >&2
    die "UDP port 53 is still owned by another process after cleanup"
  fi
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
  if [[ "${CONFIRM}" != "yes" || "${NON_INTERACTIVE}" == "yes" ]]; then
    return
  fi

  cat <<EOF

StormDNS god-mode plan:
  Install directory: ${ROOT_DIR}
  Source tree:       ${SOURCE_DIR:-not found}
  Docker project:    ${DOCKER_DIR}
  Host config:       ${HOST_CONFIG}
  Host key:          ${KEY_FILE}
  Server binary:     ${SERVER_BIN}
  Proxy binary:      ${PROXY_BIN}
  Containers:        ${INSTANCES}
  Listen address:    ${LISTEN_ADDR}
  WARP egress:       ${WARP_EGRESS}

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
    --source-dir)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --source-dir=*)
      SOURCE_DIR="${1#*=}"
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
    --no-source-build)
      BINARY_BUILD="no"
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
    --no-warp-egress)
      WARP_EGRESS="no"
      shift
      ;;
    --regenerate-key)
      REGENERATE_KEY="yes"
      shift
      ;;
    --confirm)
      CONFIRM="yes"
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE="yes"
      shift
      ;;
    -y|--yes)
      CONFIRM="no"
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

ROOT_DIR="$(detect_install_root)"
ROOT_DIR="$(cd "${ROOT_DIR}" && pwd -P)"
SOURCE_DIR="$(detect_source_dir || true)"
if [[ -n "${SOURCE_DIR}" ]]; then
  SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd -P)"
fi
DOCKER_DIR="${DOCKER_DIR:-${ROOT_DIR}/stormdns-docker}"
DOCKER_CONFIG_DIR="${DOCKER_DIR}/config"
HOST_CONFIG="${HOST_CONFIG:-${ROOT_DIR}/server_config.toml}"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
DOCKERFILE="${DOCKER_DIR}/Dockerfile"
WARP_EGRESS_SCRIPT="${ROOT_DIR}/stormdns-warp-egress.sh"
BACKUP_ROOT="${ROOT_DIR}/stormdns-backups"

require_root
ensure_runtime_tools
require_command systemctl
require_command ss
require_command sed
require_command awk
require_command sysctl

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
backup_file "${WARP_EGRESS_SCRIPT}" "${BACKUP_DIR}"
backup_file "${WARP_EGRESS_UNIT}" "${BACKUP_DIR}"
backup_file "${SYSCTL_FILE}" "${BACKUP_DIR}"
backup_file "${LIMITS_FILE}" "${BACKUP_DIR}"

log "Applying OS UDP tuning and opening port 53"
apply_os_tuning
open_firewall_port_53

log "Preparing Docker project for ${INSTANCES} instances"
prepare_docker_files
write_compose "${INSTANCES}"

BACKENDS="$(backend_list "${INSTANCES}")"
log "Backend list: ${BACKENDS}"

disable_legacy_services
stop_unit_hard stormdns-proxy.service
release_port53_conflict
write_proxy_unit "${BACKENDS}"
if [[ "${WARP_EGRESS}" == "yes" ]]; then
  write_warp_egress_script
  write_warp_egress_unit
fi

systemctl daemon-reload
systemctl enable docker.service >/dev/null 2>&1 || true
systemctl enable stormdns-proxy.service >/dev/null
if [[ "${WARP_EGRESS}" == "yes" ]]; then
  systemctl enable stormdns-warp-egress.service >/dev/null
fi

start_stack "${BUILD}" "${RECREATE}"

if [[ "${WARP_EGRESS}" == "yes" ]]; then
  log "Applying WARP egress routing if a WARP interface exists"
  systemctl restart stormdns-warp-egress.service || true
fi

log "Starting proxy"
systemctl restart stormdns-proxy.service

show_status

log "Done. Backup: ${BACKUP_DIR}"
