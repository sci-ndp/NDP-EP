#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# NDP-EP Setup Script (Federation -> Kafka -> CKAN)
# ==============================================

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- Defaults ----------
FEDERATION_PROD_URL="https://federation.ndp.utah.edu"
FEDERATION_TEST_URL="https://federation.ndp.utah.edu/test"
IDP_PROD_HOST="idp.nationaldataplatform.org"
IDP_TEST_HOST="idp-test.nationaldataplatform.org"

# prod by default
federation_env="prod"
federation_url="$FEDERATION_PROD_URL"
idp_host="$IDP_PROD_HOST"
config_id=""

# ---------- Logging ----------
print_step()    { echo -e "\n${GREEN}[STEP]${NC} $1"; }
print_info()    { echo -e "${YELLOW}[INFO]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

show_usage() {
  cat <<EOF
Usage:
  $0 --config_id <id> [--env prod|test] [--federation_url <url>]

Defaults:
  --env prod
  prod federation: $FEDERATION_PROD_URL
  test federation: $FEDERATION_TEST_URL

Examples:
  $0 --config_id 6966cbcf9713c07ef570f388
  $0 --config_id 6966cbcf9713c07ef570f388 --env test
  $0 --config_id 6966cbcf9713c07ef570f388 --federation_url https://custom.example.com
EOF
}

# ---------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config_id)       config_id="${2:-}"; shift 2 ;;
    --env)             federation_env="${2:-}"; shift 2 ;;
    --federation_url)  federation_url="${2:-}"; shift 2 ;;
    --help|-h)         show_usage; exit 0 ;;
    *) print_error "Unknown argument: $1"; show_usage; exit 1 ;;
  esac
done

if [[ -z "$config_id" ]]; then
  print_error "--config_id is required"
  show_usage
  exit 1
fi

# If federation_url wasn't explicitly provided, map from env
if [[ "$federation_url" == "$FEDERATION_PROD_URL" && "$federation_env" == "test" ]]; then
  federation_url="$FEDERATION_TEST_URL"
fi

case "$federation_env" in
  prod) idp_host="$IDP_PROD_HOST" ;;
  test) idp_host="$IDP_TEST_HOST" ;;
  *) print_error "--env must be 'prod' or 'test' (got: $federation_env)"; exit 1 ;;
esac

# =====================================================
# STEP 1 — Fetch config from Federation
# =====================================================
print_step "Checking dependencies needed for config fetch..."
command -v curl >/dev/null 2>&1 || { print_error "curl is required but not installed."; exit 1; }
command -v jq   >/dev/null 2>&1 || { print_error "jq is required but not installed."; exit 1; }
print_success "Dependencies look good (curl, jq)"

print_step "Fetching configuration from Federation..."
print_info "Env: $federation_env"
print_info "Federation URL: $federation_url"
print_info "Config ID: $config_id"

config_endpoint="${federation_url%/}/ep/${config_id}"
config_json="$(curl -fsS "$config_endpoint")" || {
  print_error "Failed to fetch config."
  print_error "Endpoint: $config_endpoint"
  exit 1
}

if [[ -z "$config_json" || "$config_json" == "null" ]]; then
  print_error "Federation returned empty/null config."
  print_error "Endpoint: $config_endpoint"
  exit 1
fi

if echo "$config_json" | jq -e '.error? // empty' >/dev/null 2>&1; then
  msg="$(echo "$config_json" | jq -r '.message // .error // "Unknown error"')"
  print_error "Federation API error: $msg"
  exit 1
fi

print_success "Configuration fetched"

# ---------- Parse values into variables ----------
print_step "Parsing configuration into variables..."

cfg_id="$(echo "$config_json" | jq -r '._id // empty')"
[[ -n "$cfg_id" ]] || { print_error "Config JSON missing _id"; exit 1; }

ckan_name="$(echo "$config_json" | jq -r '.ckan_name // "ckan_admin"')"
ckan_password="$(echo "$config_json" | jq -r '.ckan_password // "test1234"')"
client_id="$(echo "$config_json" | jq -r '.client_id // ""')"
client_secret="$(echo "$config_json" | jq -r '.client_secret // ""')"
realm_name="$(echo "$config_json" | jq -r '.realm_name // "NDP"')"
enable_staging="$(echo "$config_json" | jq -r '.enable_staging // false')"
poc="$(echo "$config_json" | jq -r '.poc // ""')"
organization="$(echo "$config_json" | jq -r '.organization // "My-Organization"')"
jhub="$(echo "$config_json" | jq -r '.jhub // false')"
streaming="$(echo "$config_json" | jq -r '.streaming // false')"
pre_ckan_url="$(echo "$config_json" | jq -r '.pre_ckan_url // ""')"
pre_ckan_key="$(echo "$config_json" | jq -r '.pre_ckan_key // ""')"
keycloak_secret="$(echo "$config_json" | jq -r '.keycloak_secret // ""')"
group_name="$(echo "$config_json" | jq -r '.group_name // ""')"
ep_name="$(echo "$config_json" | jq -r '.ep_name // "My-EP"')"
userid="$(echo "$config_json" | jq -r '.userid // ""')"
public="$(echo "$config_json" | jq -r '.public // true')"
jupyter_url="$(echo "$config_json" | jq -r '.jupyter_url // ""')"
received_at="$(echo "$config_json" | jq -r '.received_at // ""')"

KEYCLOAK_BASE_URL="https://${idp_host}"
KEYCLOAK_REALM="${realm_name}"

print_success "Variables loaded"

echo ""
echo -e "${BLUE}Fetched Config Summary:${NC}"
echo "  _id:            $cfg_id"
echo "  organization:   $organization"
echo "  ep_name:        $ep_name"
echo "  poc:            ${poc:-"(not set)"}"
echo "  enable_staging: $enable_staging"
echo "  public:         $public"
echo "  group_name:     ${group_name:-"(not set)"}"
echo "  jhub:           $jhub"
echo "  streaming:      $streaming"
echo "  pre_ckan_url:   ${pre_ckan_url:-"(not set)"}"
echo "  received_at:    ${received_at:-"(not set)"}"
echo ""
echo -e "${BLUE}Auth / Keycloak:${NC}"
echo "  idp_host:       $idp_host"
echo "  base_url:       $KEYCLOAK_BASE_URL"
echo "  realm:          $KEYCLOAK_REALM"
echo "  client_id:      ${client_id:-"(not set)"}"
echo "  client_secret:  $([[ -n "$client_secret" ]] && echo "(set)" || echo "(not set)")"
echo "  keycloak_secret:$([[ -n "$keycloak_secret" ]] && echo "(set)" || echo "(not set)")"
echo ""
echo -e "${BLUE}CKAN creds:${NC}"
echo "  ckan_name:      $ckan_name"
echo "  ckan_password:  $([[ -n "$ckan_password" ]] && echo "(set)" || echo "(not set)")"
print_success "Step 1 complete (config fetched + parsed)"

# =====================================================
# STEP 2 — Machine IP + Dependencies (docker, compose, git)
# =====================================================
print_step "Detecting machine IP..."
machine_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$machine_ip" ]]; then
  machine_ip="$(ip route get 1 2>/dev/null | awk '{print $7; exit}')"
fi
[[ -n "$machine_ip" ]] || { print_error "Could not determine machine IP automatically."; exit 1; }
print_success "Machine IP detected: $machine_ip"

print_step "Checking required packages..."
need_install=()

check_cmd () { command -v "$1" >/dev/null 2>&1 || need_install+=("$2"); }
check_cmd curl curl
check_cmd jq jq
check_cmd git git

if ! command -v docker >/dev/null 2>&1; then
  print_info "Docker not found — installing"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" || true
  print_success "Docker installed"
fi

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE_CMD="docker-compose"
else
  print_error "Docker Compose not found. Please install docker compose plugin."
  exit 1
fi
print_info "Compose command: $DOCKER_COMPOSE_CMD"

if [[ ${#need_install[@]} -gt 0 ]]; then
  print_info "Installing missing packages: ${need_install[*]}"
  sudo apt-get update -y
  sudo apt-get install -y "${need_install[@]}"
fi

print_success "All dependencies satisfied"
 
# =====================================================
# STEP 2.5 — Script paths + persistent user info (REQUIRED)
# =====================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="${SCRIPT_DIR}/full-stack"
USER_INFO_FILE="${SCRIPT_DIR}/user_info.env"
info_file="${SCRIPT_DIR}/setup_info.txt"

mkdir -p "$STACK_ROOT"
touch "$info_file"
touch "$USER_INFO_FILE"
chmod 600 "$USER_INFO_FILE" "$info_file" 2>/dev/null || true

# If older runs created full-stack/full-stack, flatten it automatically
if [[ -d "${STACK_ROOT}/full-stack" ]]; then
  print_info "Fixing nested directory: ${STACK_ROOT}/full-stack -> ${STACK_ROOT}"
  shopt -s dotglob
  mv "${STACK_ROOT}/full-stack/"* "${STACK_ROOT}/" 2>/dev/null || true
  shopt -u dotglob
  rmdir "${STACK_ROOT}/full-stack" 2>/dev/null || true
fi

# Persist federation config snapshot (reproducible)
echo "$config_json" > "${SCRIPT_DIR}/federation_config.json"
chmod 600 "${SCRIPT_DIR}/federation_config.json" 2>/dev/null || true

write_kv() {
  local key="$1"
  local val="$2"
  touch "$USER_INFO_FILE"
  chmod 600 "$USER_INFO_FILE" 2>/dev/null || true
  grep -vE "^${key}=" "$USER_INFO_FILE" > "${USER_INFO_FILE}.tmp" 2>/dev/null || true
  mv "${USER_INFO_FILE}.tmp" "$USER_INFO_FILE"
  echo "${key}=\"${val}\"" >> "$USER_INFO_FILE"
}

read_kv() {
  local key="$1"
  [[ -f "$USER_INFO_FILE" ]] || { echo ""; return 0; }
  grep -E "^${key}=" "$USER_INFO_FILE" | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

# Save baseline metadata (so user can re-run with same inputs)
write_kv CONFIG_ID "$config_id"
write_kv FEDERATION_ENV "$federation_env"
write_kv FEDERATION_URL "$federation_url"
write_kv IDP_HOST "$idp_host"
write_kv MACHINE_IP "$machine_ip"
write_kv ORG "$organization"
write_kv EP_NAME "$ep_name"
write_kv PRE_CKAN_URL "$pre_ckan_url"
write_kv PRE_CKAN_API_KEY "$pre_ckan_key"

# ==========================================================
# STEP — Kafka (kafka-kraft) ✅ idempotent: skip if running
# ==========================================================
if [[ "$streaming" == "true" || "$streaming" == "True" ]]; then
  print_step "Setting up Kafka (kafka-kraft)"

  KAFKA_DIR="${STACK_ROOT}/kafka"
  KAFKA_REPO="https://github.com/sci-ndp/kafka-kraft"
  KAFKA_COMPOSE_FILE="${KAFKA_DIR}/docker-compose.generated.yml"
  KAFKA_ENV_FILE="${KAFKA_DIR}/.env"

  mkdir -p "$STACK_ROOT"
  cd "$STACK_ROOT"

  kafka_is_running() {
    docker ps --format '{{.Names}}' | grep -q '^kraft-broker$'
  }

  kafka_ui_localhost_bound() {
    docker ps --format '{{.Names}} {{.Ports}}' \
      | grep -qE '^kafka-ui .*127\.0\.0\.1:8080->8080/tcp'
  }

  kafka_patch_ui_localhost() {
    [[ -f "$KAFKA_COMPOSE_FILE" ]] || return 0
    if grep -q '"${UI_PORT:-8080}:8080"' "$KAFKA_COMPOSE_FILE"; then
      sed -i \
        's|^[[:space:]]*-[[:space:]]*"${UI_PORT:-8080}:8080"|      - "127.0.0.1:${UI_PORT:-8080}:8080"|' \
        "$KAFKA_COMPOSE_FILE"
    fi
  }

  kafka_ensure_ui_localhost() {
    kafka_patch_ui_localhost
    if [[ -f "$KAFKA_COMPOSE_FILE" ]] && kafka_is_running && ! kafka_ui_localhost_bound; then
      print_info "Kafka UI not localhost-bound — recreating kafka-ui only"
      docker compose -f "$KAFKA_COMPOSE_FILE" up -d --no-deps --force-recreate kafka-ui
    fi
  }

  if [[ ! -d "$KAFKA_DIR" ]]; then
    print_info "Cloning kafka-kraft repo..."
    git clone "$KAFKA_REPO" "$KAFKA_DIR"
  fi

  cd "$KAFKA_DIR"

  if kafka_is_running; then
    print_info "Kafka already running — skipping start"
    kafka_ensure_ui_localhost
  else
    if [[ -f "$KAFKA_COMPOSE_FILE" ]]; then
      print_info "Kafka exists but stopped — starting via generated compose"
      docker compose -f "$KAFKA_COMPOSE_FILE" up -d
    else
      print_info "First run — running kafka-start.sh"
      chmod +x ./kafka-start.sh ./kafka-stop.sh 2>/dev/null || true
      ./kafka-start.sh --generate-passwords -H "$machine_ip"
    fi
    kafka_ensure_ui_localhost
  fi

  print_info "Waiting for Kafka broker..."
  ready=false
  for _ in {1..60}; do
    # Health can show 'starting/unhealthy' even after server starts; also accept the log marker.
    if docker logs kraft-broker 2>/dev/null | grep -q "Kafka Server started"; then
      ready=true
      break
    fi
    sleep 2
  done

  if [[ "$ready" != "true" ]]; then
    print_error "Kafka broker did not become ready in time."
    docker logs --tail 120 kraft-broker || true
    exit 1
  fi

  print_success "Kafka broker ready"

  if [[ ! -f "$KAFKA_ENV_FILE" ]]; then
    print_error "Kafka .env not found at $KAFKA_ENV_FILE"
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$KAFKA_ENV_FILE"
  set +a

  if [[ -z "${KAFKA_CLIENT_USER:-}" || -z "${KAFKA_CLIENT_PASSWORD:-}" ]]; then
    print_error "Missing KAFKA_CLIENT_USER/KAFKA_CLIENT_PASSWORD in $KAFKA_ENV_FILE"
    exit 1
  fi
  if [[ -z "${SCRAM_CLIENT_USER:-}" || -z "${SCRAM_CLIENT_PASSWORD:-}" ]]; then
    print_error "Missing SCRAM_CLIENT_USER/SCRAM_CLIENT_PASSWORD in $KAFKA_ENV_FILE"
    exit 1
  fi

  KAFKA_BOOTSTRAP_PLAINTEXT="${machine_ip}:${EXTERNAL_PORT:-9092}"
  KAFKA_BOOTSTRAP_SSL="${machine_ip}:${SECURE_PORT:-9094}"
  KAFKA_UI_URL="http://localhost:${UI_PORT:-8080}"

  print_success "Kafka credentials loaded"
  print_info "Kafka UI: $KAFKA_UI_URL"
  print_info "Kafka (SASL_PLAINTEXT): $KAFKA_BOOTSTRAP_PLAINTEXT"
  print_info "Kafka (SASL_SSL): $KAFKA_BOOTSTRAP_SSL"

  # Persist non-secret endpoints + users; secrets remain in full-stack/kafka/.env
  write_kv KAFKA_UI_URL "$KAFKA_UI_URL"
  write_kv KAFKA_BOOTSTRAP_PLAINTEXT "$KAFKA_BOOTSTRAP_PLAINTEXT"
  write_kv KAFKA_BOOTSTRAP_SSL "$KAFKA_BOOTSTRAP_SSL"
  write_kv KAFKA_CLIENT_USER "${KAFKA_CLIENT_USER}"
  write_kv SCRAM_CLIENT_USER "${SCRAM_CLIENT_USER}"

  {
    echo ""
    echo "Kafka:"
    echo "  UI:              ${KAFKA_UI_URL}"
    echo "  Bootstrap PLAIN: ${KAFKA_BOOTSTRAP_PLAINTEXT}"
    echo "  Bootstrap SSL:   ${KAFKA_BOOTSTRAP_SSL}"
    echo "  Client user:     ${KAFKA_CLIENT_USER}  (password in full-stack/kafka/.env)"
    echo "  SCRAM user:      ${SCRAM_CLIENT_USER}  (password in full-stack/kafka/.env)"
  } >> "$info_file"

  print_info "Kafka status:"
  docker compose -f "$KAFKA_COMPOSE_FILE" ps || true

  cd "$STACK_ROOT"
  print_success "Kafka step complete"
else
  print_info "Streaming disabled — skipping Kafka setup"
fi


# ==========================================================
# STEP — CKAN (pop-ckan-docker) ✅ idempotent + persistent key
# ==========================================================
print_step "Setting up CKAN (local catalog)"

CKAN_DIR="${STACK_ROOT}/ckan"
CKAN_REPO="https://github.com/sci-ndp/pop-ckan-docker.git"
CKAN_ENV_FILE="${CKAN_DIR}/.env"

print_info "STACK_ROOT: $STACK_ROOT"
print_info "CKAN_DIR:   $CKAN_DIR"

# ---- user_info persistence (self-contained) ----
USER_INFO_FILE="${USER_INFO_FILE:-${STACK_ROOT}/user_info.env}"
touch "$USER_INFO_FILE"

kv_get() {
  local key="$1"
  grep -E "^${key}=" "$USER_INFO_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}
kv_set() {
  local key="$1"
  local val="$2"
  if grep -qE "^${key}=" "$USER_INFO_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$USER_INFO_FILE"
  else
    echo "${key}=${val}" >> "$USER_INFO_FILE"
  fi
}

# ---- helpers ----
ckan_container_id() {
  # Prefer compose service if directory exists
  if [[ -d "$CKAN_DIR" ]]; then
    (cd "$CKAN_DIR" && $DOCKER_COMPOSE_CMD ps -q ckan 2>/dev/null | head -n1) || true
    return 0
  fi
  # Fallback: any container with "ckan" in name
  docker ps --format '{{.ID}} {{.Names}}' | awk '/ckan/ {print $1; exit}'
}

ckan_is_ready() {
  local cid; cid="$(ckan_container_id)"
  [[ -n "$cid" ]] || return 1
  local health
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cid" 2>/dev/null || echo starting)"
  [[ "$health" == "healthy" || "$health" == "running" ]]
}

ckan_wait_ready() {
  local cid="$1"
  while true; do
    local health
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cid" 2>/dev/null || echo starting)"
    if [[ "$health" == "healthy" || "$health" == "running" ]]; then
      break
    fi
    echo "Waiting for CKAN to be ready... (status: $health)"
    sleep 5
  done
}

ckan_detect_ini() {
  docker exec "$1" bash -c '
    for p in /srv/app/ckan.ini /etc/ckan/ckan.ini /etc/ckan/default/ckan.ini; do
      [ -f "$p" ] && { echo "$p"; exit 0; }
    done
    exit 1
  '
}

ckan_generate_token() {
  docker exec "$1" bash -c "ckan -c '$2' user token add '$3' api_key_for_admin" \
    | tr -cd '\11\12\15\40-\176' \
    | grep -Eo 'eyJ[0-9a-zA-Z._-]{30,}' \
    | head -n1
}

# ---- decision ----
existing_local_ckan_key="$(kv_get LOCAL_CKAN_API_KEY)"
current_cid="$(ckan_container_id || true)"

print_info "Detected CKAN container id (if running): ${current_cid:-none}"
print_info "Existing LOCAL_CKAN_API_KEY in user_info.env: $([[ -n "$existing_local_ckan_key" ]] && echo yes || echo no)"
print_info "User info file: $USER_INFO_FILE"

if [[ -n "$existing_local_ckan_key" ]] && ckan_is_ready; then
  print_success "CKAN is running and LOCAL_CKAN_API_KEY already saved — skipping CKAN step."
  cd "$STACK_ROOT"
else
  print_info "Proceeding to install/start CKAN..."

  if [[ ! -d "$CKAN_DIR/.git" ]]; then
    print_info "Cloning CKAN repo..."
    git clone "$CKAN_REPO" "$CKAN_DIR"
  else
    print_info "CKAN repo already exists — skipping clone"
  fi

  cd "$CKAN_DIR"

  if [[ ! -f "$CKAN_ENV_FILE" ]]; then
    print_info "Creating CKAN .env from example"
    cp .env.example .env
  fi

  sed -i "s/^CKAN_SYSADMIN_NAME=.*/CKAN_SYSADMIN_NAME=${ckan_name}/" .env
  sed -i "s/^CKAN_SYSADMIN_PASSWORD=.*/CKAN_SYSADMIN_PASSWORD=${ckan_password}/" .env
  sed -i "s|^CKAN_SITE_URL=.*|CKAN_SITE_URL=https://${machine_ip}:8443|" .env
  print_success "CKAN .env configured"

  if ! ckan_is_ready; then
    print_info "Starting CKAN stack..."
    $DOCKER_COMPOSE_CMD up -d --build
  else
    print_info "CKAN already running — skipping startup"
  fi

  ckan_container="$(ckan_container_id || true)"
  if [[ -z "$ckan_container" ]]; then
    print_error "CKAN container not detected after startup."
    $DOCKER_COMPOSE_CMD ps || true
    exit 1
  fi

  ckan_wait_ready "$ckan_container"
  print_success "CKAN is ready"

  existing_local_ckan_key="$(kv_get LOCAL_CKAN_API_KEY)"
  if [[ -z "$existing_local_ckan_key" ]]; then
    print_info "Detecting ckan.ini inside container..."
    ckan_ini_path="$(ckan_detect_ini "$ckan_container")" || {
      print_error "Could not find ckan.ini inside container"
      exit 1
    }

    print_info "Generating LOCAL CKAN API key..."
    LOCAL_CKAN_API_KEY="$(ckan_generate_token "$ckan_container" "$ckan_ini_path" "$ckan_name")"

    if [[ -z "$LOCAL_CKAN_API_KEY" ]]; then
      print_error "Failed to extract CKAN API key. Full output below:"
      docker exec "$ckan_container" bash -c "ckan -c '$ckan_ini_path' user token add '$ckan_name' api_key_for_admin"
      exit 1
    fi

    kv_set LOCAL_CKAN_API_KEY "$LOCAL_CKAN_API_KEY"
    kv_set CKAN_LOCAL_URL "https://${machine_ip}:8443"
    kv_set CKAN_SYSADMIN_NAME "$ckan_name"

    {
      echo ""
      echo "CKAN (Local):"
      echo "  URL: https://${machine_ip}:8443"
      echo "  API Key (LOCAL): ${LOCAL_CKAN_API_KEY}"
    } >> "$info_file"

    print_success "LOCAL_CKAN_API_KEY saved to $USER_INFO_FILE"
  else
    print_success "LOCAL_CKAN_API_KEY already exists — skipping key generation"
  fi

  cd "$STACK_ROOT"
  print_success "CKAN step complete"
fi








# =====================================================
# summary
# =====================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Setup Complete (Kafka + CKAN)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Files saved at script level:${NC}"
echo "  - $USER_INFO_FILE"
echo "  - ${SCRIPT_DIR}/federation_config.json"
echo "  - $info_file"
echo ""
echo -e "${BLUE}Stack folder:${NC} $STACK_ROOT"
echo ""

# ==========================================================
# STEP — JupyterHub (sci-ndp/jhub) ✅ idempotent
# ==========================================================
if [[ "${jhub}" == "true" || "${jhub}" == "True" ]]; then
  print_step "Setting up JupyterHub (jhub)"

  JHUB_DIR="${STACK_ROOT}/jhub"
  JHUB_REPO="https://github.com/sci-ndp/jhub.git"
  JHUB_ENV_FILE="${JHUB_DIR}/.env"

  # -------------------------
  # Repo setup
  # -------------------------
  mkdir -p "$STACK_ROOT"
  cd "$STACK_ROOT"

  if [[ ! -d "$JHUB_DIR/.git" ]]; then
    print_info "Cloning JupyterHub repo into: $JHUB_DIR"
    git clone "$JHUB_REPO" "$JHUB_DIR"
  else
    print_info "JupyterHub repo already exists — skipping clone"
  fi

  cd "$JHUB_DIR"

  # -------------------------
  # Detect if already running (compose project containers)
  # -------------------------
  jhub_project_name() { basename "$JHUB_DIR"; }

  jhub_any_container_running() {
    local proj; proj="$(jhub_project_name)"
    docker ps --filter "label=com.docker.compose.project=${proj}" --format '{{.ID}}' | head -n1 | grep -q .
  }

  if jhub_any_container_running; then
    print_success "JupyterHub already running — skipping start"
    cd "$STACK_ROOT"
  else
    # -------------------------
    # Configure .env
    # -------------------------
    if [[ ! -f "$JHUB_ENV_FILE" ]]; then
      print_info "Creating JupyterHub .env from example"
      cp .env.example .env
    fi

    # Keycloak URLs (test/prod already set earlier in script via idp_host + realm_name)
    KEYCLOAK_REALM="${realm_name:-NDP}"
    KC_BASE="https://${idp_host}/realms/${KEYCLOAK_REALM}/protocol/openid-connect"
    AUTH_URL="${KC_BASE}/auth"
    TOKEN_URL="${KC_BASE}/token"
    USERINFO_URL="${KC_BASE}/userinfo"
    CALLBACK_URL="http://${machine_ip}:8002/hub/oauth_callback"
    LOGOUT_URL="${KC_BASE}/logout?redirect_uri=http://${machine_ip}:8002/hub/spawn"

    # Groups (from federation config)
    GROUPS_VAL=""
    if [[ -n "${group_name:-}" && "${group_name}" != "null" ]]; then
      if [[ "${group_name}" == /* ]]; then
        # Add both with and without leading slash for compatibility
        GROUPS_VAL="${group_name#"/"},${group_name}"
      else
        GROUPS_VAL="${group_name},/${group_name}"
      fi
    fi

    # Fixed endpoints per env (as you specified)
    if [[ "${federation_env}" == "test" ]]; then
      CKAN_API_URL="https://ndp-test.sdsc.edu/catalog/api/3/action/"
      WORKSPACE_API_URL="https://ndp-test.sdsc.edu/workspaces-api"
    else
      CKAN_API_URL="https://nationaldataplatform.org/catalog/api/3/action/"
      WORKSPACE_API_URL="https://nationaldataplatform.com/workspaces-api"
    fi

    # Apply replacements
    sed -i "s|^JUPYTERHUB_ADMIN=.*|JUPYTERHUB_ADMIN=${poc}|" .env
    sed -i "s|^JUPYTERHUB_KEYCLOAK_CLIENT_ID=.*|JUPYTERHUB_KEYCLOAK_CLIENT_ID=${client_id}|" .env
    sed -i "s|^JUPYTERHUB_KEYCLOAK_CLIENT_SECRET=.*|JUPYTERHUB_KEYCLOAK_CLIENT_SECRET=${client_secret}|" .env
    sed -i "s|^JUPYTERHUB_AUTHORIZE_URL=.*|JUPYTERHUB_AUTHORIZE_URL=${AUTH_URL}|" .env
    sed -i "s|^JUPYTERHUB_TOKEN_URL=.*|JUPYTERHUB_TOKEN_URL=${TOKEN_URL}|" .env
    sed -i "s|^JUPYTERHUB_USERDATA_URL=.*|JUPYTERHUB_USERDATA_URL=${USERINFO_URL}|" .env
    sed -i "s|^JUPYTERHUB_OAUTH_CALLBACK_URL=.*|JUPYTERHUB_OAUTH_CALLBACK_URL=${CALLBACK_URL}|" .env
    sed -i "s|^JUPYTERHUB_LOGOUT_REDIRECT_URL=.*|JUPYTERHUB_LOGOUT_REDIRECT_URL=${LOGOUT_URL}|" .env

    # Groups line
    if [[ -n "$GROUPS_VAL" ]]; then
      if grep -q '^JUPYTERHUB_GROUPS=' .env; then
        sed -i "s|^JUPYTERHUB_GROUPS=.*|JUPYTERHUB_GROUPS=${GROUPS_VAL}|" .env
      else
        echo "JUPYTERHUB_GROUPS=${GROUPS_VAL}" >> .env
      fi
    fi

    # CKAN + Workspaces URLs (fixed)
    if grep -q '^CKAN_API_URL=' .env; then
      sed -i "s|^CKAN_API_URL=.*|CKAN_API_URL=${CKAN_API_URL}|" .env
    else
      echo "CKAN_API_URL=${CKAN_API_URL}" >> .env
    fi

    if grep -q '^WORKSPACE_API_URL=' .env; then
      sed -i "s|^WORKSPACE_API_URL=.*|WORKSPACE_API_URL=${WORKSPACE_API_URL}|" .env
    else
      echo "WORKSPACE_API_URL=${WORKSPACE_API_URL}" >> .env
    fi

    print_success "JupyterHub .env configured"

    # -------------------------
    # Start JupyterHub
    # -------------------------
    print_info "Starting JupyterHub services..."
    $DOCKER_COMPOSE_CMD up -d --build

    print_info "JupyterHub status:"
    $DOCKER_COMPOSE_CMD ps || true

    # Persist summary info
    JUPYTERHUB_URL="http://${machine_ip}:8002"
    write_kv JUPYTERHUB_URL "$JUPYTERHUB_URL"
    write_kv JUPYTERHUB_ADMIN "${poc}"
    write_kv JUPYTERHUB_GROUPS "${GROUPS_VAL}"
    write_kv JUPYTERHUB_KEYCLOAK_REALM "${KEYCLOAK_REALM}"
    write_kv CKAN_API_URL "${CKAN_API_URL}"
    write_kv WORKSPACE_API_URL "${WORKSPACE_API_URL}"

    {
      echo ""
      echo "JupyterHub:"
      echo "  URL: ${JUPYTERHUB_URL}"
      echo "  Admin: ${poc}"
      echo "  Groups: ${GROUPS_VAL:-"(not set)"}"
      echo "  Keycloak Realm: ${KEYCLOAK_REALM}"
      echo "  CKAN API URL: ${CKAN_API_URL}"
      echo "  Workspaces API URL: ${WORKSPACE_API_URL}"
    } >> "$info_file"

    cd "$STACK_ROOT"
    print_success "JupyterHub step complete"
  fi

else
  print_info "JupyterHub disabled (jhub=false) — skipping JupyterHub setup"
fi

# ==========================================================
# STEP — EP API (national-data-platform/ep-api) — run last
# ==========================================================
print_step "Setting up EP API (ndp-ep-api)"

EP_API_DIR="${STACK_ROOT}/ep-api"
EP_API_REPO="https://github.com/national-data-platform/ep-api.git"
EP_API_ENV_FILE="${EP_API_DIR}/.env"
EP_API_PORT="${EP_API_PORT:-8001}"

mkdir -p "$STACK_ROOT"
cd "$STACK_ROOT"

if [[ ! -d "$EP_API_DIR/.git" ]]; then
  print_info "Cloning EP API repo..."
  git clone "$EP_API_REPO" "$EP_API_DIR"
else
  print_info "EP API repo already exists — skipping clone"
fi

cd "$EP_API_DIR"

# Keep compose port override idempotent (avoids clash with JupyterHub on 8002)
if ! grep -q 'EP_API_PORT' docker-compose.yml; then
  sed -i 's|"8002:8000"|"${EP_API_PORT:-8001}:8000"|' docker-compose.yml
fi

# Resolve CKAN + Pre-CKAN inputs
local_ckan_url="$(read_kv CKAN_LOCAL_URL)"
local_ckan_key="$(read_kv LOCAL_CKAN_API_KEY)"
[[ -n "$local_ckan_url" ]] || local_ckan_url="https://${machine_ip}:8443"

if [[ -z "$local_ckan_key" ]]; then
  print_error "LOCAL_CKAN_API_KEY not found in $USER_INFO_FILE; run CKAN step first."
  exit 1
fi

if [[ -n "$pre_ckan_url" && "$pre_ckan_url" != "null" && -n "$pre_ckan_key" && "$pre_ckan_key" != "null" ]]; then
  PRE_CKAN_ENABLED="True"
  PRE_CKAN_URL="$pre_ckan_url"
  PRE_CKAN_API_KEY="$pre_ckan_key"
else
  PRE_CKAN_ENABLED="False"
  PRE_CKAN_URL=""
  PRE_CKAN_API_KEY=""
fi

# Access control from federation groups
if [[ -n "$group_name" && "$group_name" != "null" ]]; then
  ENABLE_GROUP_BASED_ACCESS="True"
  GROUP_NAMES="$group_name"
else
  ENABLE_GROUP_BASED_ACCESS="False"
  GROUP_NAMES=""
fi

# Kafka connection (uses external listener on host IP)
if [[ "$streaming" == "true" || "$streaming" == "True" ]]; then
  KAFKA_CONNECTION="True"
  KAFKA_HOST="$machine_ip"
  KAFKA_PORT="${EXTERNAL_PORT:-9092}"
else
  KAFKA_CONNECTION="False"
  KAFKA_HOST=""
  KAFKA_PORT="9092"
fi

# JupyterLab integration (optional)
if [[ "$jhub" == "true" || "$jhub" == "True" ]]; then
  USE_JUPYTERLAB="True"
  JUPYTER_URL="${jupyter_url:-http://${machine_ip}:8002}"
else
  USE_JUPYTERLAB="False"
  JUPYTER_URL=""
fi

AUTH_API_URL="https://${idp_host}/temp/information"
EP_API_URL="http://${machine_ip}:${EP_API_PORT}"

cat > "$EP_API_ENV_FILE" <<EOF
# Generated by setup.sh — edit if you need overrides
ROOT_PATH=

ORGANIZATION="${organization}"
EP_NAME="${ep_name}"

METRICS_INTERVAL_SECONDS=3300

ENABLE_GROUP_BASED_ACCESS=${ENABLE_GROUP_BASED_ACCESS}
GROUP_NAMES=${GROUP_NAMES}

LOCAL_CATALOG_BACKEND=ckan
CKAN_LOCAL_ENABLED=True
CKAN_URL=${local_ckan_url}
CKAN_API_KEY=${local_ckan_key}
CKAN_VERIFY_SSL=False

MONGODB_CONNECTION_STRING=
MONGODB_DATABASE=

PRE_CKAN_ENABLED=${PRE_CKAN_ENABLED}
PRE_CKAN_URL=${PRE_CKAN_URL}
PRE_CKAN_API_KEY=${PRE_CKAN_API_KEY}
PRE_CKAN_VERIFY_SSL=True

KAFKA_CONNECTION=${KAFKA_CONNECTION}
KAFKA_HOST=${KAFKA_HOST}
KAFKA_PORT=${KAFKA_PORT}

TEST_TOKEN=
AUTH_API_URL=${AUTH_API_URL}

USE_JUPYTERLAB=${USE_JUPYTERLAB}
JUPYTER_URL=${JUPYTER_URL}

S3_ENABLED=False
S3_ENDPOINT=
S3_ACCESS_KEY=
S3_SECRET_KEY=
S3_SECURE=False
S3_REGION=

PELICAN_ENABLED=False
PELICAN_FEDERATION_URL=
PELICAN_DIRECT_READS=False
EOF

print_success "EP API .env written"

write_kv EP_API_URL "$EP_API_URL"
write_kv EP_API_PORT "$EP_API_PORT"

{
  echo ""
  echo "EP API:"
  echo "  URL: ${EP_API_URL}"
  echo "  ORGANIZATION: ${organization}"
  echo "  EP_NAME: ${ep_name}"
  echo "  CKAN local: ${local_ckan_url}"
  echo "  Pre-CKAN: ${PRE_CKAN_ENABLED} ${PRE_CKAN_URL}"
  echo "  Kafka: ${KAFKA_CONNECTION} ${KAFKA_HOST}:${KAFKA_PORT}"
} >> "$info_file"

print_info "Starting EP API (api service only)..."
$DOCKER_COMPOSE_CMD -f docker-compose.yml up -d api

print_info "EP API status:"
$DOCKER_COMPOSE_CMD -f docker-compose.yml ps api || true

cd "$STACK_ROOT"
print_success "EP API step complete"

# =====================================================
# summary
# =====================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Setup Complete (Kafka + CKAN + EP API${jhub:+ + JupyterHub})${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Files saved at script level:${NC}"
echo "  - $USER_INFO_FILE"
echo "  - ${SCRIPT_DIR}/federation_config.json"
echo "  - $info_file"
echo ""
echo -e "${BLUE}Key endpoints:${NC}"
echo "  - CKAN:   $(read_kv CKAN_LOCAL_URL)"
echo "  - EP API: $(read_kv EP_API_URL)"
if [[ "$jhub" == "true" || "$jhub" == "True" ]]; then
  echo "  - JupyterHub: $(read_kv JUPYTERHUB_URL)"
fi
echo "  - Kafka UI: $(read_kv KAFKA_UI_URL)"
echo ""
echo -e "${BLUE}Stack folder:${NC} $STACK_ROOT"
echo ""
