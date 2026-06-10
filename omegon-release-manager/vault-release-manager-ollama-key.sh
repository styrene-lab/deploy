#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-}" == "1" || "${-}" == *x* ]]; then
  echo "Refusing to run with shell tracing enabled; API keys must never be logged." >&2
  exit 2
fi

: "${KUBECONFIG:=$HOME/.kube/brutus.yaml}"
VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_SERVICE="${VAULT_SERVICE:-svc/vault}"
RELEASE_NAMESPACE="${RELEASE_NAMESPACE:-omegon-agents}"
RELEASE_DEPLOY="${RELEASE_DEPLOY:-release-manager}"
VAULT_LOCAL_ADDR="${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
AUTH_PATH="${AUTH_PATH:-community/omegon-release-manager/auth-json}"
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
  unset OLLAMA_API_KEY AUTH_JSON
}
trap cleanup EXIT

read -rsp "OLLAMA_API_KEY: " OLLAMA_API_KEY
echo
if [[ -z "$OLLAMA_API_KEY" ]]; then
  echo "Empty Ollama API key refused." >&2
  exit 3
fi

unset VAULT_NAMESPACE
kubectl -n "$VAULT_K8S_NAMESPACE" port-forward "$VAULT_SERVICE" 8200:8200 >/tmp/vault-release-manager-ollama-key-pf.log 2>&1 &
VAULT_PF_PID=$!
sleep 2
export VAULT_ADDR="$VAULT_LOCAL_ADDR"

echo "Checking Vault token and status..."
vault token lookup >/dev/null
vault status >/dev/null

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

stamp="$(date +%s)"
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-auth-json \
  "styrene.sh/refresh=$stamp" --overwrite >/dev/null

echo "Switching release-manager model to ${MODEL}..."
kubectl -n "$RELEASE_NAMESPACE" patch omegonagent release-manager \
  --type=merge -p "{\"spec\":{\"model\":\"${MODEL}\"}}" >/dev/null

sleep "${VSO_WAIT_SECONDS:-10}"
kubectl -n "$RELEASE_NAMESPACE" get vaultstaticsecret release-manager-auth-json
kubectl -n "$RELEASE_NAMESPACE" get secret release-manager-auth-json

kubectl -n "$RELEASE_NAMESPACE" rollout restart "deploy/${RELEASE_DEPLOY}" >/dev/null
kubectl -n "$RELEASE_NAMESPACE" rollout status "deploy/${RELEASE_DEPLOY}" --timeout="${ROLLOUT_TIMEOUT:-180s}"

echo "Done. Ollama Cloud provider auth is in Vault and release-manager was restarted."
