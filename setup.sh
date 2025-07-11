#!/bin/bash
set -e
cat <<'EOF'


  ███╗   ██╗██████╗ ██████╗       ███████╗██████╗ 
  ████╗  ██║██╔══██╗██╔══██╗      ██╔════╝██╔══██╗
  ██╔██╗ ██║██║  ██║██████╔╝█████╗█████╗  ██████╔╝
  ██║╚██╗██║██║  ██║██╔═══╝ ╚════╝██╔══╝  ██╔═══╝ 
  ██║ ╚████║██████╔╝██║           ███████╗██║     
  ╚═╝  ╚═══╝╚═════╝ ╚═╝           ╚══════╝╚═╝     
                                                  
EOF
# -----------------------------------------------------------------------------
# deploy.sh — full deploy script with optional `--config_id` support
#
# If you pass `--config_id <ID>`, the script will:
#   • curl https://federation.ndp.utah.edu/api/v1/pop/<ID>
#   • parse JSON with jq into these variables:
#       ckan_name, ckan_password, client_id, client_secret,
#       realm_name, keycloak_secret, pre_ckan_url, pre_ckan_key,
#       poc, organization, streaming, dxspaces, jhub
#
# If you don’t pass `--config_id`, you must supply those via flags:
#   --ckan_name, --ckan_password, --client_id, --client_secret,
#   --realm_name, --keycloak_secret, --pre_ckan_url, --pre_ckan_key,
#   --poc, --organization, --streaming, --enable_staging, --jhub
#
# **Change these jq keys** at the top of the fetch-block if your API uses
# different JSON field names.
# -----------------------------------------------------------------------------

# ----------- ARGUMENT PARSING -----------
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config_id)      config_id="$2";       shift;;
    --ckan_name)      ckan_name="$2";       shift;;
    --ckan_password)  ckan_password="$2";   shift;;
    --client_id)      client_id="$2";       shift;;
    --client_secret)  client_secret="$2";   shift;;
    --realm_name)     realm_name="$2";      shift;;
    --keycloak_secret) keycloak_secret="$2"; shift;;
    --pre_ckan_url)   pre_ckan_url="$2";    shift;;
    --pre_ckan_key)   pre_ckan_key="$2";    shift;;
    --poc)            poc="$2";             shift;;
    --organization)   organization="$2";     shift;;
    --streaming)      streaming="$2";        shift;;
    --enable_staging) dxspaces="$2";         shift;;
    --jhub)           jhub="$2";             shift;;
    *)
      echo "Unknown parameter passed: $1"
      exit 1
      ;;
  esac
  shift
done

# ----------- CONFIG_ID FETCH VS. MANUAL FLAGS -----------
if [[ -n "$config_id" ]]; then
  # Ensure jq is installed
  if ! command -v jq &>/dev/null; then
    echo "Error: this mode requires 'jq' (install with: sudo apt update && sudo apt install -y jq)"
    exit 1
  fi

  echo "Fetching configuration for ID: $config_id"
  config_json=$(curl -fsSL "https://federation.ndp.utah.edu/api/v1/pop/${config_id}")
  if [[ -z "$config_json" ]]; then
    echo "Error: no configuration returned for ID $config_id"
    exit 1
  fi

  # ─── PARSE JSON INTO VARIABLES ───────────────────────────────────────────────
  ckan_name     =$(jq -r '.ckan_name'       <<<"$config_json")
  ckan_password =$(jq -r '.ckan_password'   <<<"$config_json")
  client_id     =$(jq -r '.client_id'       <<<"$config_json")
  client_secret =$(jq -r '.client_secret'   <<<"$config_json")
  realm_name    =$(jq -r '.realm_name'      <<<"$config_json")
  keycloak_secret=$(jq -r '.keycloak_secret'<<<"$config_json")
  pre_ckan_url  =$(jq -r '.pre_ckan_url'    <<<"$config_json")
  pre_ckan_key  =$(jq -r '.pre_ckan_key'    <<<"$config_json")
  poc           =$(jq -r '.poc'             <<<"$config_json")
  organization  =$(jq -r '.organization'    <<<"$config_json")
  streaming     =$(jq -r '.streaming'       <<<"$config_json")
  dxspaces      =$(jq -r '.dxspaces'        <<<"$config_json")
  jhub          =$(jq -r '.jhub'            <<<"$config_json")
else
  # ─── VALIDATE REQUIRED FLAGS ─────────────────────────────────────────────────
  required_vars=(
    ckan_name ckan_password client_id client_secret
    realm_name keycloak_secret pre_ckan_url pre_ckan_key
    poc organization streaming dxspaces jhub
  )
  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      echo "Error: --${var} is required when not using --config_id"
      exit 1
    fi
  done
fi

# ----------- NORMALIZE BOOLEAN FLAGS -----------
streaming=$(echo "$streaming" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
dxspaces=$(echo "$dxspaces" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
jhub=$(echo "$jhub" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')

for var in streaming dxspaces jhub; do
  if [[ "${!var}" != "True" && "${!var}" != "False" ]]; then
    echo "Error: --$var must be 'true' or 'false' (case-insensitive)"
    exit 1
  fi
done

machine_ip=$(hostname -I | awk '{print $1}')
info_file="user_info.txt"
swagger_title="NDP POP REST API"

# ----------- SAVE USER INFO -----------
{
  echo "CKAN_SYSADMIN_NAME: $ckan_name"
  echo "CKAN_SYSADMIN_PASSWORD: $ckan_password"
  echo "Keycloak CLIENT_ID: $client_id"
  echo "Keycloak CLIENT_SECRET: $client_secret"
  echo "Keycloak Realm: $realm_name"
  echo "Keycloak Secret: $keycloak_secret"
  echo "Pre-CKAN URL: $pre_ckan_url"
  echo "Pre-CKAN API Key: $pre_ckan_key"
  echo "Enable Staging: $dxspaces"
  echo "Enable Streaming: $streaming"
  echo "POC: $poc"
  echo "Organization: $organization"
  echo "JupyterHub Enabled: $jhub"
  echo "Machine IP: $machine_ip"
} > "$info_file"

# ----------- INSTALL REQUIRED PACKAGES -----------
install_packages() {
  for pkg in docker docker-compose git unzip python3 python3-venv jq; do
    # jq is needed if using --config_id
    if ! command -v "${pkg%%-*}" &>/dev/null; then
      echo "Installing $pkg..."
      sudo apt-get update
      sudo apt-get install -y "$pkg"
    fi
  done
}
install_packages

# ----------- DETECT DOCKER COMPOSE CMD -----------
if docker compose version &>/dev/null; then
  docker_compose_cmd="docker compose"
else
  docker_compose_cmd="docker-compose"
fi

# ----------- SCI-DX Kafka (if streaming is enabled) -----------
if [[ "$streaming" == "True" ]]; then
  git clone https://github.com/sci-ndp/sciDX-kafka.git
  cd sciDX-kafka
  echo "MACHINE_IP=${machine_ip}" > .env
  $docker_compose_cmd up -d --build
  cd ..
fi

# ----------- CKAN SETUP -----------
git clone https://github.com/sci-ndp/pop-ckan-docker.git ckan
cd ckan
cp .env.example .env
sed -i "s/^CKAN_SYSADMIN_NAME=.*/CKAN_SYSADMIN_NAME=${ckan_name}/" .env
sed -i "s/^CKAN_SYSADMIN_PASSWORD=.*/CKAN_SYSADMIN_PASSWORD=${ckan_password}/" .env
sed -i "s|^CKAN_SITE_URL=.*|CKAN_SITE_URL=http://${machine_ip}:8443|" .env
$docker_compose_cmd up -d --build
cd ..

ckan_container=$(docker ps --filter "expose=5000" --format "{{.ID}}" | head -n1)
if [ -z "$ckan_container" ]; then
  echo "❌ CKAN container not detected."
  exit 1
fi
while true; do
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$ckan_container")
  if [[ "$health" == "healthy" || "$health" == "running" ]]; then
    break
  fi
  echo "Waiting for CKAN to be ready... (status: $health)"
  sleep 5
done

ckan_ini_path="/srv/app/ckan.ini"
if docker exec "$ckan_container" test -f "$ckan_ini_path"; then
  docker exec "$ckan_container" \
    sed -i "s/ckan.auth.create_user_via_web = true/ckan.auth.create_user_via_web = false/" \
    "$ckan_ini_path"
else
  echo "❌ CKAN ini file not found."
  exit 1
fi

api_key=$(docker exec "$ckan_container" \
  ckan -c "$ckan_ini_path" user token add "$ckan_name" api_key_for_admin \
  | tail -n 1 | tr -d '\r')
docker restart "$ckan_container"

echo "CKAN URL: http://${machine_ip}:8443"   >> "$info_file"
echo "CKAN API Key: ${api_key}"             >> "$info_file"

# ----------- DSPACES (if enabled) -----------
if [[ "$dxspaces" == "True" ]]; then
  git clone https://github.com/sci-ndp/dspaces-api.git
  cd dspaces-api
  cp ./env_variables/env_swagger.example ./env_variables/.env_swagger
  cp ./env_variables/env_dspaces.example ./env_variables/.env_dspaces
  cp ./env_variables/env_api.example ./env_variables/.env_api
  cat ./env_variables/.env_dspaces ./env_variables/.env_api >> .env
  $docker_compose_cmd up -d
  cd ..
fi

# ----------- JUPYTERHUB SETUP (before POP) -----------
if [[ "$jhub" == "True" ]]; then
  echo "🔧 Setting up JupyterHub..."
  git clone https://github.com/sci-ndp/jhub.git
  cd jhub
  cp .env.example .env
  sed -i "s|^JUPYTERHUB_ADMIN=.*|JUPYTERHUB_ADMIN=${poc}|" .env
  sed -i "s|^JUPYTERHUB_KEYCLOAK_CLIENT_ID=.*|JUPYTERHUB_KEYCLOAK_CLIENT_ID=${client_id}|" .env
  sed -i "s|^JUPYTERHUB_KEYCLOAK_CLIENT_SECRET=.*|JUPYTERHUB_KEYCLOAK_CLIENT_SECRET=${client_secret}|" .env
  sed -i "s|^JUPYTERHUB_OAUTH_CALLBACK_URL=.*|JUPYTERHUB_OAUTH_CALLBACK_URL=http://${machine_ip}:8002/hub/oauth_callback|" .env
  sed -i "s|^JUPYTERHUB_LOGOUT_REDIRECT_URL=.*|JUPYTERHUB_LOGOUT_REDIRECT_URL=https://idp.nationaldataplatform.org/realms/NDP/protocol/openid-connect/logout?redirect_uri=http://${machine_ip}:8002/hub/spawn|" .env
  sed -i "s|^JUPYTERHUB_AUTHORIZE_URL=.*|JUPYTERHUB_AUTHORIZE_URL=https://idp.nationaldataplatform.org/realms/NDP/protocol/openid-connect/auth|" .env
  sed -i "s|^JUPYTERHUB_TOKEN_URL=.*|JUPYTERHUB_TOKEN_URL=https://idp.nationaldataplatform.org/realms/NDP/protocol/openid-connect/token|" .env
  sed -i "s|^JUPYTERHUB_USERDATA_URL=.*|JUPYTERHUB_USERDATA_URL=https://idp.nationaldataplatform.org/realms/NDP/protocol/openid-connect/userinfo|" .env
  $docker_compose_cmd up -d --build
  cd ..
fi

# ----------- POP API SETUP -----------
git clone https://github.com/sci-ndp/pop.git
cd pop
if [ -f "example.env" ]; then
  cp example.env .env
elif [ -f ".env.example" ]; then
  cp .env.example .env
else
  echo "❌ No env template found in pop directory."
  exit 1
fi

update_env() {
  sed -i "s|^$1=.*|$1=$2|" .env
}

update_env "CKAN_LOCAL_ENABLED"  "True"
update_env "CKAN_URL"            "http://${machine_ip}:8443"
update_env "CKAN_GLOBAL_URL"     "https://nationaldataplatform.org/catalog"
update_env "CKAN_API_KEY"        "${api_key}"
update_env "PRE_CKAN_ENABLED"    "True"
update_env "PRE_CKAN_URL"        "${pre_ckan_url}"
update_env "PRE_CKAN_API_KEY"    "${pre_ckan_key}"
update_env "KAFKA_CONNECTION"    "${streaming}"
update_env "KAFKA_HOST"          "${machine_ip}"
update_env "KAFKA_PORT"          "9092"
update_env "KEYCLOAK_URL"        "https://idp.nationaldataplatform.org"
update_env "REALM_NAME"          "${realm_name}"
update_env "CLIENT_ID"           "${client_id}"
update_env "CLIENT_SECRET"       "${client_secret}"
update_env "TEST_USERNAME"       "${ckan_name}"
update_env "TEST_PASSWORD"       "${ckan_password}"
update_env "SWAGGER_TITLE"       "${swagger_title}"
update_env "SWAGGER_DESCRIPTION" "NDP EndPoint API for data access @${organization}"
update_env "USE_JUPYTERLAB"      "${jhub}"
update_env "JUPYTER_URL"         "http://${machine_ip}:8002"
update_env "USE_DXSPACES"        "${dxspaces}"
if [[ "$dxspaces" == "True" ]]; then
  update_env "DXSPACES_URL"      "http://${machine_ip}:8001"
fi
update_env "POC"                 "${poc}"
update_env "ORGANIZATION"        "${organization}"
echo "SECRET=${keycloak_secret}" >> .env

$docker_compose_cmd up -d --build

echo -e "\n✅ NDP stack deployed successfully!"
cat "$info_file"
