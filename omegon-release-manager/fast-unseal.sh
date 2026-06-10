#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-}" == "1" || "${-}" == *x* ]]; then
  echo "Refusing to run with shell tracing enabled; unseal keys must never be logged." >&2
  exit 2
fi

: "${KUBECONFIG:=$HOME/.kube/brutus.yaml}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
RELEASE_NAMESPACE="${RELEASE_NAMESPACE:-omegon-agents}"
RELEASE_DEPLOY="${RELEASE_DEPLOY:-release-manager}"
REQUIRED_SHARES="${REQUIRED_SHARES:-3}"

vault_status() {
  kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- vault status
}

is_unsealed() {
  vault_status 2>/dev/null | awk '/Sealed/ {print $2}' | grep -q '^false$'
}

submit_unseal_key() {
  local key="$1"
  local response
  response="$(jq -n --arg key "$key" '{key: $key}' | \
    kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- \
      sh -c 'tmp="$(mktemp)"; cat > "$tmp"; vault write -format=json sys/unseal @"$tmp"; rm -f "$tmp"')"
  printf '%s\n' "$response" | jq -r '"sealed=" + (.sealed|tostring) + " progress=" + ((.progress // 0)|tostring) + "/" + ((.t // 0)|tostring)'
}

echo "Checking Vault status for ${VAULT_NAMESPACE}/${VAULT_POD}..."
vault_status || true

if is_unsealed; then
  echo "Vault already unsealed."
else
  echo "Vault is sealed. Enter ${REQUIRED_SHARES} unseal shares. Input is hidden and not stored."
  for i in $(seq 1 "$REQUIRED_SHARES"); do
    key=""
    read -rsp "Vault unseal key ${i}/${REQUIRED_SHARES}: " key
    echo
    if [[ -z "$key" ]]; then
      echo "Empty key refused." >&2
      unset key
      exit 3
    fi
    submit_unseal_key "$key"
    unset key
    if is_unsealed; then
      echo "Vault unsealed after ${i} share(s)."
      break
    fi
  done
fi

echo "Final Vault status:"
vault_status

if ! is_unsealed; then
  echo "Vault is still sealed; not refreshing VSO or restarting release-manager." >&2
  exit 4
fi

stamp="$(date +%s)"
echo "Triggering VSO refresh annotations..."
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-auth-json \
  "styrene.sh/refresh=$stamp" --overwrite || true
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-public-connectors \
  "styrene.sh/refresh=$stamp" --overwrite || true

echo "Waiting briefly for VSO reconciliation..."
sleep "${VSO_WAIT_SECONDS:-10}"

kubectl -n "$RELEASE_NAMESPACE" get vaultstaticsecret release-manager-auth-json release-manager-public-connectors || true
kubectl -n "$RELEASE_NAMESPACE" get secret release-manager-auth-json release-manager-public-connectors || true

echo "Restarting ${RELEASE_NAMESPACE}/deploy/${RELEASE_DEPLOY}..."
kubectl -n "$RELEASE_NAMESPACE" rollout restart "deploy/${RELEASE_DEPLOY}"
kubectl -n "$RELEASE_NAMESPACE" rollout status "deploy/${RELEASE_DEPLOY}" --timeout="${ROLLOUT_TIMEOUT:-180s}"

echo "Release-manager pods:"
kubectl -n "$RELEASE_NAMESPACE" get pods -l styrene.sh/agent=release-manager -o wide
