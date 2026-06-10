#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-}" == "1" || "${-}" == *x* ]]; then
  echo "Refusing to run with shell tracing enabled; connector tokens must never be logged." >&2
  exit 2
fi

: "${KUBECONFIG:=$HOME/.kube/brutus.yaml}"
VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_SERVICE="${VAULT_SERVICE:-svc/vault}"
RELEASE_NAMESPACE="${RELEASE_NAMESPACE:-omegon-agents}"
RELEASE_DEPLOY="${RELEASE_DEPLOY:-release-manager}"
VAULT_LOCAL_ADDR="${VAULT_LOCAL_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-secret}"
CONNECTORS_PATH="${CONNECTORS_PATH:-community/omegon-release-manager/connectors}"
REFRESH_ONLY="${REFRESH_ONLY:-0}"
RESTART_DEPLOYMENT="${RESTART_DEPLOYMENT:-0}"
VAULT_PF_LOG="${VAULT_PF_LOG:-./.vault-release-manager-connectors-pf.log}"

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
  unset GITHUB_TOKEN_VALUE DISCORD_BOT_TOKEN SLACK_OAUTH_TOKEN SLACK_SOCKET_TOKEN MASTODON_ACCESS_TOKEN
}
trap cleanup EXIT

read_secret() {
  local prompt="$1"
  local var_name="$2"
  local required="$3"
  local value=""
  read -rsp "$prompt: " value
  echo
  if [[ -z "$value" && "$required" == "required" ]]; then
    echo "Empty value refused for required secret: $prompt" >&2
    exit 3
  fi
  printf -v "$var_name" '%s' "$value"
}

unset VAULT_NAMESPACE
kubectl -n "$VAULT_K8S_NAMESPACE" port-forward "$VAULT_SERVICE" 8200:8200 >"$VAULT_PF_LOG" 2>&1 &
VAULT_PF_PID=$!
sleep 2
export VAULT_ADDR="$VAULT_LOCAL_ADDR"

echo "Checking Vault token and status..."
vault token lookup >/dev/null
vault status >/dev/null

if [[ "$REFRESH_ONLY" != "1" ]]; then
  echo "Enter release-manager connector/workflow secrets. Input is hidden and not logged."
  read_secret "GitHub token for release evidence (GITHUB_TOKEN)" GITHUB_TOKEN_VALUE required
  read_secret "Discord bot token (VOX_DISCORD_BOT_TOKEN)" DISCORD_BOT_TOKEN required
  read_secret "Slack OAuth token xoxb-* (VOX_SLACK_OAUTH_TOKEN)" SLACK_OAUTH_TOKEN required
  read_secret "Slack Socket Mode token xapp-* (VOX_SLACK_APP_TOKEN)" SLACK_SOCKET_TOKEN required
  read_secret "Mastodon access token (optional, future connector)" MASTODON_ACCESS_TOKEN optional

  echo "Writing connector/workflow secrets to Vault KV ${VAULT_KV_MOUNT}/${CONNECTORS_PATH}..."
  vault kv put "${VAULT_KV_MOUNT}/${CONNECTORS_PATH}" \
    github_token="$GITHUB_TOKEN_VALUE" \
    discord_bot_token="$DISCORD_BOT_TOKEN" \
    slack_oauth_token="$SLACK_OAUTH_TOKEN" \
    slack_socket_token="$SLACK_SOCKET_TOKEN" \
    mastodon_access_token="$MASTODON_ACCESS_TOKEN" >/dev/null
fi

stamp="$(date +%s)"
echo "Triggering VSO refresh for release-manager-public-connectors..."
kubectl -n "$RELEASE_NAMESPACE" annotate vaultstaticsecret release-manager-public-connectors \
  "styrene.sh/refresh=$stamp" --overwrite >/dev/null

echo "Waiting for VSO reconciliation..."
sleep "${VSO_WAIT_SECONDS:-10}"
kubectl -n "$RELEASE_NAMESPACE" get vaultstaticsecret release-manager-public-connectors
kubectl -n "$RELEASE_NAMESPACE" get secret release-manager-public-connectors

echo "Rendered connector Secret keys:"
kubectl -n "$RELEASE_NAMESPACE" get secret release-manager-public-connectors -o json | jq -r '.data | keys[]'

if [[ "$RESTART_DEPLOYMENT" == "1" ]]; then
  echo "Restarting ${RELEASE_NAMESPACE}/deploy/${RELEASE_DEPLOY}..."
  kubectl -n "$RELEASE_NAMESPACE" rollout restart "deploy/${RELEASE_DEPLOY}" >/dev/null
  kubectl -n "$RELEASE_NAMESPACE" rollout status "deploy/${RELEASE_DEPLOY}" --timeout="${ROLLOUT_TIMEOUT:-180s}"
else
  echo "Not restarting deployment. Set RESTART_DEPLOYMENT=1 when the pod spec consumes these file keys."
fi

echo "Done. Connector/workflow secrets are in Vault and materialized by VSO."
