#!/usr/bin/env bash
# Deploy scidx-helm.
#
# Fetches the federation document before calling helm so that optional
# sub-charts (kafka-kraft, ndp-jupyterhub) can be enabled/disabled based
# on the federation configuration.

set -euo pipefail

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
CONFIG_ID=""
CLUSTER_HOST=""
STORAGE_CLASS=""
INGRESS_CLASS=""
NDP_ENV="prod"
NAMESPACE="scidx"

# --------------------------------------------------------------------------
# Parse flags
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-id)      CONFIG_ID="$2";      shift 2 ;;
    --host)           CLUSTER_HOST="$2";   shift 2 ;;
    --storage-class)  STORAGE_CLASS="$2";  shift 2 ;;
    --ingress-class)  INGRESS_CLASS="$2";  shift 2 ;;
    --env)            NDP_ENV="$2";        shift 2 ;;
    --namespace)      NAMESPACE="$2";      shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

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
  echo "Usage: $0 --config-id <id> --host <host> --storage-class <class> --ingress-class <class> [--env test] [--namespace <ns>]"
  exit 1
fi

# --------------------------------------------------------------------------
# Derive federation URL (mirrors _helpers.tpl logic)
# --------------------------------------------------------------------------
if [[ "$NDP_ENV" == "test" ]]; then
  FEDERATION_URL="https://federation.ndp.utah.edu/test"
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

KAFKA_ENABLED="false"
if [[ "$STREAMING" == "true" || "$STREAMING" == "True" ]]; then
  KAFKA_ENABLED="true"
fi

JHUB_ENABLED="false"
if [[ "$JHUB" == "true" || "$JHUB" == "True" ]]; then
  JHUB_ENABLED="true"
fi

echo "==> streaming=${STREAMING}   -> kafka-kraft.enabled=${KAFKA_ENABLED}"
echo "==> jupyterhub=${JHUB}   -> ndp-jupyterhub.enabled=${JHUB_ENABLED}"

# --------------------------------------------------------------------------
# Add/update Helm repo
# --------------------------------------------------------------------------
helm repo add ndp-ep https://sci-ndp.github.io/ndp-ep-helm
helm repo update

# --------------------------------------------------------------------------
# Deploy
# --------------------------------------------------------------------------
helm upgrade --install scidx ndp-ep/ndp-ep-helm \
  -n "${NAMESPACE}" --create-namespace \
  --set global.env="${NDP_ENV}" \
  --set federation.configId="${CONFIG_ID}" \
  --set global.clusterHost="${CLUSTER_HOST}" \
  --set global.clusterStorageClass="${STORAGE_CLASS}" \
  --set global.clusterIngressClass="${INGRESS_CLASS}" \
  --set kafka-kraft.enabled="${KAFKA_ENABLED}" \
  --set ndp-jupyterhub.enabled="${JHUB_ENABLED}" 
