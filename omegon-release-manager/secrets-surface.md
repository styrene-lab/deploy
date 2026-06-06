# Kubernetes-deployed Omegon secrets surface

Auspex-managed Omegon pods get secrets through `spec.secrets` on the `OmegonAgent` CRD. The operator turns that desired state into pod mounts, environment projection, Vault injector annotations, and redacted fleet/API projections.

## Supported surfaces

| Surface | CRD field | Pod effect | Use | Risk |
|---|---|---|---|---|
| Provider auth file | `spec.secrets.authJsonSecret` | Mounts one Secret key `auth.json` at `/config/omegon/auth.json` and sets `OMEGON_AUTH_JSON_PATH` | Preferred narrow provider auth projection for k8s agents | Secret still exists in Kubernetes etcd unless encryption-at-rest is enabled |
| Broad environment Secret | `spec.secrets.secretName` | Adds the Secret via `envFrom` | Connector tokens and legacy env-style integrations | Highest blast radius; every key becomes process environment |
| Vault Agent injection | `spec.secrets.vault` | Adds `vault.hashicorp.com/*` pod annotations for rendered files/env material | Production secret delivery with Vault/OpenBao audit and rotation | Requires Vault injector/CSI posture and working role bindings |
| Control-plane TLS Secret | `spec.controlPlane.tls` or `spec.identity.mtls` | Mounts cert/key/CA at `/run/omegon/control-tls` and, when enabled by operator feature flag, passes Omegon TLS args | ACP/WSS transport security and optional mTLS | Private keys stay in Secret; metadata only should surface in APIs |
| Styrene identity | `spec.identity` | Operator derives/provisions per-agent identity material and mounts it for mesh/TLS use | Workload identity, mesh role, mTLS issuance | Depends on operator root identity security tier |

## Release-manager proposed bindings

`omegon-release-manager/omegon-agent.yaml` uses the Auspex pattern:

- `authJsonSecret: release-manager-auth-json` for provider OAuth/auth material.
  - Secret key must be exactly `auth.json`.
  - Runtime path becomes `/config/omegon/auth.json` through `OMEGON_AUTH_JSON_PATH`.
- `secretName: release-manager-public-connectors` for public connector tokens that currently need environment variables.
  - Expected keys: `GITHUB_TOKEN`, `VOX_DISCORD_BOT_TOKEN`, `VOX_SLACK_BOT_TOKEN`, `VOX_SLACK_APP_TOKEN`, optionally `MASTODON_ACCESS_TOKEN`.
  - This is intentionally broader; move these to Vault-rendered files or narrower connector-specific grants as the operator surface matures.

## Operator/API projection

Auspex exposes redacted secret visibility through `/api/secrets/grants`. That endpoint lists Kubernetes Secrets only when they carry one of the projection labels `styrene.sh/secret-grant`, `styrene.sh/identity`, or `styrene.sh/control-plane-tls`; it returns names, namespace, type, labels, annotations, and data key names, never Secret data values. The deploy UI uses this as preflight evidence that required secret references exist before applying an `OmegonAgent`.

Control-plane metadata is exposed separately through `/api/agents/{namespace}/{name}/control-plane` and `/api/fleet`; it includes URLs, TLS posture, epochs/fingerprints where applicable, and ACP proxy location, not secret payloads.

## Current caveat

The `styrene.release-manager-agent` bundle must be available to the Omegon runtime catalog. The raw ConfigMap in this directory records the intended bundle, but current Auspex operator code only auto-mounts inline catalog material for `styrene.auspex-primary`. For release-manager, use one of:

1. bake the bundle into the Omegon image catalog;
2. publish it through Armory plus an Auspex deployment overlay;
3. extend the operator to mount arbitrary agent bundle ConfigMaps for non-primary agents.

Until one of those exists, the `OmegonAgent` manifest is the desired orchestration shape but may not start successfully because `--agent styrene.release-manager-agent` cannot resolve the bundle.
