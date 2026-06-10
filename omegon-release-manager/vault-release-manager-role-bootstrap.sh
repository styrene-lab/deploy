#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-}" == "1" || "${-}" == *x* ]]; then
  echo "Refusing to run with shell tracing enabled; Vault admin token must never be logged." >&2
  exit 2
fi

: "${KUBECONFIG:=$HOME/.kube/brutus.yaml}"
VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_SERVICE="${VAULT_SERVICE:-svc/vault}"
RELEASE_NAMESPACE="${RELEASE_NAMESPACE:-omegon-agents}"
VAULT_LOCAL_ADDR="${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
VAULT_ROLE="${VAULT_ROLE:-omegon-agents}"
VAULT_POLICY="${VAULT_POLICY:-omegon-release-manager}"
AUTH_PATH="${AUTH_PATH:-community/omegon-release-manager/auth-json}"
CONNECTORS_PATH="${CONNECTORS_PATH:-community/omegon-release-manager/connectors}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 10
  }
}

need kubectl
need vault

cleanup() {
  if [[ -n "${VAULT_PF_PID:-}" ]]; then
    kill "$VAULT_PF_PID" >/dev/null 2>&1 || true
  fi
  unset VAULT_TOKEN VAULT_ADMIN_TOKEN
}
trap cleanup EXIT

read -rsp "Vault admin/root token: " VAULT_ADMIN_TOKEN
echo
if [[ -z "$VAULT_ADMIN_TOKEN" ]]; then
  echo "Empty Vault token refused." >&2
  exit 3
fi

export VAULT_TOKEN="$VAULT_ADMIN_TOKEN"
unset VAULT_ADMIN_TOKEN
# VSO logs in without a Vault Enterprise namespace header. Force the same context
# so roles are written to the mount VSO actually uses.
unset VAULT_NAMESPACE

kubectl -n "$VAULT_K8S_NAMESPACE" port-forward "$VAULT_SERVICE" 8200:8200 >/tmp/vault-release-manager-role-bootstrap-pf.log 2>&1 &
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

echo "Ensuring VSO uses ${VAULT_ROLE} VaultAuth..."
kubectl -n "$RELEASE_NAMESPACE" patch vaultstaticsecret release-manager-auth-json \
  --type=merge -p '{"spec":{"vaultAuthRef":"omegon-agents-vault-auth"}}' >/dev/null
kubectl -n "$RELEASE_NAMESPACE" patch vaultstaticsecret release-manager-public-connectors \
  --type=merge -p '{"spec":{"vaultAuthRef":"omegon-agents-vault-auth"}}' >/dev/null

stamp="$(date +%s)"
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-auth-json \
  "styrene.sh/refresh=$stamp" --overwrite >/dev/null
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-public-connectors \
  "styrene.sh/refresh=$stamp" --overwrite >/dev/null

echo "Done. Vault Kubernetes auth role/policy is in place."
