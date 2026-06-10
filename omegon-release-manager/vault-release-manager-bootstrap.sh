#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-}" == "1" || "${-}" == *x* ]]; then
  echo "Refusing to run with shell tracing enabled; Vault admin token must never be logged." >&2
  exit 2
fi

: "${KUBECONFIG:=$HOME/.kube/brutus.yaml}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_SERVICE="${VAULT_SERVICE:-svc/vault}"
RELEASE_NAMESPACE="${RELEASE_NAMESPACE:-omegon-agents}"
RELEASE_DEPLOY="${RELEASE_DEPLOY:-release-manager}"
VAULT_LOCAL_ADDR="${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_ROLE="${VAULT_ROLE:-omegon-agents}"
VAULT_POLICY="${VAULT_POLICY:-omegon-release-manager}"
AUTH_PATH="${AUTH_PATH:-community/omegon-release-manager/auth-json}"
CONNECTORS_PATH="${CONNECTORS_PATH:-community/omegon-release-manager/connectors}"
MODEL="${MODEL:-ollama-cloud:gpt-oss:120b-cloud}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 10
  }
}

need kubectl
need vault
need jq

cleanup() {
  if [[ -n "${VAULT_PF_PID:-}" ]]; then
    kill "$VAULT_PF_PID" >/dev/null 2>&1 || true
  fi
  unset VAULT_TOKEN VAULT_ADMIN_TOKEN OLLAMA_API_KEY AUTH_JSON
}
trap cleanup EXIT

read -rsp "Vault admin/root token: " VAULT_ADMIN_TOKEN
echo
if [[ -z "$VAULT_ADMIN_TOKEN" ]]; then
  echo "Empty Vault token refused." >&2
  exit 3
fi

read -rsp "OLLAMA_API_KEY: " OLLAMA_API_KEY
echo
if [[ -z "$OLLAMA_API_KEY" ]]; then
  echo "Empty Ollama API key refused." >&2
  exit 4
fi

export VAULT_TOKEN="$VAULT_ADMIN_TOKEN"
unset VAULT_ADMIN_TOKEN

kubectl -n "$VAULT_NAMESPACE" port-forward "$VAULT_SERVICE" 8200:8200 >/tmp/vault-release-manager-bootstrap-pf.log 2>&1 &
VAULT_PF_PID=$!
sleep 2
export VAULT_ADDR="$VAULT_LOCAL_ADDR"

echo "Checking Vault status..."
vault status >/dev/null

echo "Writing release-manager Vault policy ${VAULT_POLICY}..."
vault policy write "$VAULT_POLICY" - <<HCL
path "${VAULT_KV_MOUNT}/data/${AUTH_PATH}" {
  capabilities = ["read"]
}

path "${VAULT_KV_MOUNT}/data/${CONNECTORS_PATH}" {
  capabilities = ["read"]
}

path "${VAULT_KV_MOUNT}/metadata/community/omegon-release-manager/*" {
  capabilities = ["read", "list"]
}
HCL

echo "Writing Kubernetes auth role ${VAULT_ROLE}..."
vault write "auth/kubernetes/role/${VAULT_ROLE}" \
  bound_service_account_names=omegon-agents,release-manager \
  bound_service_account_namespaces="$RELEASE_NAMESPACE" \
  policies="$VAULT_POLICY" \
  ttl=24h >/dev/null

AUTH_JSON="$(jq -n --arg key "$OLLAMA_API_KEY" '{
  "ollama-cloud": {
    "type": "api-key",
    "access": $key,
    "refresh": "",
    "expires": 18446744073709551615
  }
}')"
unset OLLAMA_API_KEY

echo "Writing Ollama Cloud provider auth to Vault KV ${VAULT_KV_MOUNT}/${AUTH_PATH}..."
vault kv put "${VAULT_KV_MOUNT}/${AUTH_PATH}" auth_json="$AUTH_JSON" >/dev/null
unset AUTH_JSON

echo "Ensuring release-manager VaultStaticSecrets use ${VAULT_ROLE} VaultAuth..."
kubectl -n "$RELEASE_NAMESPACE" patch vaultstaticsecret release-manager-auth-json \
  --type=merge -p '{"spec":{"vaultAuthRef":"omegon-agents-vault-auth"}}' >/dev/null
kubectl -n "$RELEASE_NAMESPACE" patch vaultstaticsecret release-manager-public-connectors \
  --type=merge -p '{"spec":{"vaultAuthRef":"omegon-agents-vault-auth"}}' >/dev/null

stamp="$(date +%s)"
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-auth-json \
  "styrene.sh/refresh=$stamp" --overwrite >/dev/null
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-public-connectors \
  "styrene.sh/refresh=$stamp" --overwrite >/dev/null

echo "Switching release-manager model to ${MODEL}..."
kubectl -n "$RELEASE_NAMESPACE" patch omegonagent release-manager \
  --type=merge -p "{\"spec\":{\"model\":\"${MODEL}\"}}" >/dev/null

echo "Waiting for VSO reconciliation..."
sleep "${VSO_WAIT_SECONDS:-15}"
kubectl -n "$RELEASE_NAMESPACE" get vaultstaticsecret release-manager-auth-json release-manager-public-connectors
kubectl -n "$RELEASE_NAMESPACE" get secret release-manager-auth-json release-manager-public-connectors

echo "Restarting ${RELEASE_NAMESPACE}/deploy/${RELEASE_DEPLOY}..."
kubectl -n "$RELEASE_NAMESPACE" rollout restart "deploy/${RELEASE_DEPLOY}" >/dev/null
kubectl -n "$RELEASE_NAMESPACE" rollout status "deploy/${RELEASE_DEPLOY}" --timeout="${ROLLOUT_TIMEOUT:-180s}"

echo "Release-manager pods:"
kubectl -n "$RELEASE_NAMESPACE" get pods -l styrene.sh/agent=release-manager -o wide

echo "Done. Provider auth was written through Vault/VSO; no token material was persisted by this script."
