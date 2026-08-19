#!/usr/bin/env bash
# Deploy ndp-ep-helm.
#
# Fetches the federation document before calling helm so that optional
# sub-charts (kafka-kraft, ndp-jupyterhub, rexec) can be enabled/disabled
# based on the federation configuration.

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
CONFIG_ID=""
CLUSTER_HOST=""
CLUSTER_PUBLIC_HOST=""
STORAGE_CLASS=""
INGRESS_CLASS=""
NDP_ENV="prod"
NAMESPACE="ndp-ep"
RELEASE_NAME=""

# --------------------------------------------------------------------------
# Parse flags
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-id)      CONFIG_ID="$2";             shift 2 ;;
    --host)           CLUSTER_HOST="$2";          shift 2 ;;
    --public-host)    CLUSTER_PUBLIC_HOST="$2";   shift 2 ;;
    --storage-class)  STORAGE_CLASS="$2";         shift 2 ;;
    --ingress-class)  INGRESS_CLASS="$2";         shift 2 ;;
    --env)            NDP_ENV="$2";               shift 2 ;;
    --namespace)      NAMESPACE="$2";             shift 2 ;;
    --release-name)   RELEASE_NAME="$2";          shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# Default the release name to the namespace so that parallel deployments
# (e.g. a "test" namespace alongside "prod") never share a Helm release
# name. This matters because some sub-charts (rexec-server-deployment-api)
# create cluster-scoped resources (ClusterRole/ClusterRoleBinding) whose
# names are derived from the release name only, not the namespace — two
# releases sharing a name would collide on those cluster-scoped objects.
[[ -z "$RELEASE_NAME" ]] && RELEASE_NAME="$NAMESPACE"

# --------------------------------------------------------------------------
# Validate mandatory flags
# --------------------------------------------------------------------------
MISSING=()
[[ -z "$CONFIG_ID"     ]] && MISSING+=("--config-id")
[[ -z "$CLUSTER_HOST"  ]] && MISSING+=("--host")
[[ -z "$STORAGE_CLASS" ]] && MISSING+=("--storage-class")
[[ -z "$INGRESS_CLASS" ]] && MISSING+=("--ingress-class")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: missing required flags: ${MISSING[*]}"
  echo ""
  echo "Usage: $0 --config-id <id> --host <host> --storage-class <class> --ingress-class <class> [--public-host <domain>] [--env test] [--namespace <ns>] [--release-name <name>]"
  exit 1
fi

# --------------------------------------------------------------------------
# Derive federation URL (mirrors _helpers.tpl logic)
# --------------------------------------------------------------------------
if [[ "$NDP_ENV" == "test" ]]; then
  FEDERATION_URL="https://test.federation.ndp.utah.edu"
else
  FEDERATION_URL="https://federation.ndp.utah.edu"
fi

# --------------------------------------------------------------------------
# Pre-fetch federation doc to determine optional sub-charts
# --------------------------------------------------------------------------
echo "==> Fetching federation config: ${FEDERATION_URL}/ep/${CONFIG_ID}"
DOC="$(curl -fsS "${FEDERATION_URL}/ep/${CONFIG_ID}")"

STREAMING="$(echo "$DOC" | jq -r '.streaming // false')"
JHUB="$(echo "$DOC"      | jq -r '.jhub      // false')"
REXEC="$(echo "$DOC"     | jq -r '.rexec     // false')"

KAFKA_ENABLED="false"
if [[ "$STREAMING" == "true" || "$STREAMING" == "True" ]]; then
  KAFKA_ENABLED="true"
fi

JHUB_ENABLED="false"
if [[ "$JHUB" == "true" || "$JHUB" == "True" ]]; then
  JHUB_ENABLED="true"
fi

REXEC_ENABLED="false"
if [[ "$REXEC" == "true" || "$REXEC" == "True" ]]; then
  REXEC_ENABLED="true"
fi

echo "==> streaming=${STREAMING}   -> kafka-kraft.enabled=${KAFKA_ENABLED}"
echo "==> jupyterhub=${JHUB}       -> ndp-jupyterhub.enabled=${JHUB_ENABLED}"
echo "==> rexec=${REXEC}           -> rexec-broker.enabled=${REXEC_ENABLED}, rexec-server-deployment-api.enabled=${REXEC_ENABLED}"

# --------------------------------------------------------------------------
# Add/update Helm repo
# --------------------------------------------------------------------------
helm repo add ndp-ep https://sci-ndp.github.io/ndp-ep-helm
helm repo update

# --------------------------------------------------------------------------
# Deploy
# --------------------------------------------------------------------------
helm upgrade --install "${RELEASE_NAME}" ndp-ep/ndp-ep-helm \
  -n "${NAMESPACE}" --create-namespace \
  --set global.env="${NDP_ENV}" \
  --set federation.configId="${CONFIG_ID}" \
  --set global.clusterHost="${CLUSTER_HOST}" \
  --set global.clusterPublicHost="${CLUSTER_PUBLIC_HOST}" \
  --set global.clusterStorageClass="${STORAGE_CLASS}" \
  --set global.clusterIngressClass="${INGRESS_CLASS}" \
  --set kafka-kraft.enabled="${KAFKA_ENABLED}" \
  --set ndp-jupyterhub.enabled="${JHUB_ENABLED}" \
  --set rexec-broker.enabled="${REXEC_ENABLED}" \
  --set rexec-server-deployment-api.enabled="${REXEC_ENABLED}"
