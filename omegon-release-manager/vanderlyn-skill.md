---
title: Vanderlyn Operations Skill
status: local
sensitivity: private-homelab
tags: [ops, vault, kubernetes, release-manager]
---

# Vanderlyn Operations Skill

This is local/private homelab doctrine for Vanderlyn/Brutus operations. Do not bundle this into upstream Omegon source.

## Operating facts

- Brutus kubeconfig is `~/.kube/brutus.yaml`.
- Vault runs in namespace `vault`, pod `vault-0`.
- Vault may be sealed after restart; VSO fails while Vault is sealed.
- Vault seal type is Shamir with threshold 3 of 5 shares.
- VSO runs in `vault-secrets-operator-system` and materializes Kubernetes Secrets from Vault.
- Release-manager runs in namespace `omegon-agents` as `OmegonAgent/release-manager`.
- Release-manager uses VSO target Secret `release-manager-auth-json` mounted at `/config/omegon/auth.json`.
- Release-manager provider auth Vault path is `secret/community/omegon-release-manager/auth-json`, key `auth_json`.
- Release-manager connector secret Vault path is `secret/community/omegon-release-manager/connectors`.
- Smoke-only Kubernetes Secret bypasses are acceptable only for isolating runtime failures; durable state belongs in Vault/VSO.

## Hard security rules

- Never paste Vault unseal keys, root tokens, or API keys into chat.
- Never route unseal keys through model-visible tool arguments.
- Never echo, log, persist, or commit unseal material.
- Use terminal-local masked input (`read -rsp`) for operator secrets.
- Disable shell tracing for unseal workflows; `set -x` is forbidden.
- Unset secret variables immediately after use.
- Treat direct Kubernetes Secrets as temporary smoke bypasses unless explicitly marked durable by the operator.

## Fast-unseal doctrine

When Vault is sealed and VSO is blocked:

1. Confirm Vault status with `kubectl -n vault exec vault-0 -- vault status`.
2. Run `omegon-release-manager/fast-unseal.sh`.
3. The script prompts locally for 3 unseal shares with hidden input.
4. The script submits keys through stdin/API payloads, not visible command argv.
5. After unseal, annotate VSO `VaultStaticSecret` resources to refresh.
6. Restart and verify `deployment/release-manager`.

## Admin-token bootstrap doctrine

When VSO cannot authenticate because the Vault Kubernetes auth role/policy is missing:

1. Run `omegon-release-manager/vault-release-manager-bootstrap.sh` from a local terminal.
2. The script prompts locally for a Vault admin/root token and the Ollama Cloud API key with hidden input.
3. The script creates/updates the release-manager Vault policy and Kubernetes auth role.
4. The script writes Ollama Cloud provider auth to Vault KV, not directly to Kubernetes Secret.
5. The script refreshes VSO and restarts `deployment/release-manager`.

The admin token must never enter chat or model-visible tool arguments.

## Release-manager Ollama Cloud provider

Preferred provider for the current dedicated runtime lane:

```text
ollama-cloud:gpt-oss:120b-cloud
```

Auth material should be stored in Vault as JSON under key `auth_json`:

```json
{
  "ollama-cloud": {
    "type": "api-key",
    "access": "<OLLAMA_API_KEY>",
    "refresh": "",
    "expires": 18446744073709551615
  }
}
```

Use the runtime model only after the key is in Vault/VSO or an explicitly temporary smoke Secret.

## Validation loop

```bash
export KUBECONFIG="$HOME/.kube/brutus.yaml"
kubectl -n vault exec vault-0 -- vault status
kubectl -n omegon-agents get vaultstaticsecret release-manager-auth-json release-manager-public-connectors
kubectl -n omegon-agents rollout status deploy/release-manager
kubectl -n omegon-agents logs deploy/release-manager --tail=120
```

Success criteria:

- Vault status reports `Sealed false`.
- VSO stops reporting `Vault is sealed`.
- `release-manager-auth-json` is materialized by VSO.
- `deployment/release-manager` is `1/1`.
- Omegon logs show `version=0.26.5` and no provider-auth warning for the selected model.
