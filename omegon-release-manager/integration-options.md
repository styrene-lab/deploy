# Release-manager integration options

This note sketches Armory/Auspex/Omegon integration paths for the Styrene release-manager daemon and the gaps worth targeting.

## Existing building blocks

### Armory catalog agents

Available now in `omegon-armory` / `omegon/catalog`:

| Bundle | Useful pieces | Limitations for release-manager |
|---|---|---|
| `styrene.community-agent` | Discord/community posture, Styrene ecosystem knowledge, `vox`, optional `VOX_DISCORD_BOT_TOKEN`, optional `GITHUB_TOKEN` | Stale project facts in persona/mind, Discord-focused, not release-governed |
| `styrene.discord-agent` | Minimal Discord bridge, `terminal_tool = false`, `vox`, optional Discord/GitHub tokens | Generic chat bridge, no release workflow/publishing policy |
| `styrene.slack-agent` | Minimal Slack bridge, `terminal_tool = false`, `vox`, Slack app/bot token surface | Generic chat bridge, no release workflow/publishing policy |
| `styrene.infra-engineer` | Infrastructure posture and verified bundle metadata | Too broad for public community posting; likely worker/delegate, not public bot |
| `styrene.coding-agent` | General code/release investigation capability | Too broad for autonomous public-facing daemon |
| `styrene.bd-agent` | Public/business communication instincts | Client/commercial-oriented, not ecosystem release management |

The closest existing base is `styrene.community-agent` plus bridge traits from `styrene.discord-agent`/`styrene.slack-agent`, but it should not be deployed as-is for release management.

## Recommended near-term path

### 1. Armory bundle: `styrene.release-manager-agent`

Implemented in `omegon-armory` commit `e3e02da` with this shape:

```text
omegon-armory/catalog/styrene.release-manager-agent/
├── agent.toml
├── agent.pkl
├── PERSONA.md
├── mind/facts.jsonl
└── workflows/release-publication.toml   # if workflow packaging is supported
```

Manifest intent:

```toml
[agent]
id = "styrene.release-manager-agent"
name = "Styrene Release Manager"
version = "1.0.0"
description = "Release readiness, changelog synthesis, and governed community announcements for the Styrene ecosystem."
domain = "ops"

[persona]
directive = "PERSONA.md"
badge = "release"
mind_facts = ["mind/facts.jsonl"]

[[extensions]]
name = "vox"
version = ">=0.3.0"

[settings]
model = "openai-codex:gpt-5.5"
thinking_level = "medium"
context_class = "clan"
max_turns = 80
terminal_tool = false

[secrets]
required = ["GITHUB_TOKEN"]
optional = ["VOX_DISCORD_BOT_TOKEN", "VOX_SLACK_BOT_TOKEN", "VOX_SLACK_APP_TOKEN", "MASTODON_ACCESS_TOKEN"]
```

Persona must encode hard publication boundaries:

- draft-first by default;
- publish only with explicit operator approval or configured workflow trigger;
- public facts only unless the channel is explicitly private;
- no unpublished vulnerability details;
- no token/account/secret/path leakage;
- cite release tags, commits, PRs, issues, deployment manifests, and docs.

### 2. Add an Auspex Armory deployment overlay

Auspex already has the overlay/preflight path:

- Armory package = reusable capability intent.
- Auspex overlay = deployment-specific runtime choices.
- Preflight = generated `OmegonAgent` preview + policy gates + secret envelope checks.

Proposed overlay:

```json
{
  "id": "release-manager",
  "armory": "styrene.release-manager-agent",
  "mode": "daemon",
  "role": "detached-service",
  "image": "ghcr.io/styrene-lab/omegon:0.26.5",
  "model": "openai-codex:gpt-5.5",
  "posture": "architect",
  "namespace": "omegon-agents",
  "required_secrets": ["release-manager-auth-json"],
  "optional_secrets": ["release-manager-public-connectors"],
  "control_tls_profile": "release-manager",
  "mesh_role": "operator",
  "terminalTool": false,
  "resources": { "cpu": "250m", "memory": "512Mi" }
}
```

Open question: Auspex's current `ArmoryDeploymentOverlay` does not model `connectors` directly. The WebUI deploy request can pass connectors, and builtin package deploys support them, but overlays should gain a `connectors` field so preflight/deploy can preserve Discord/Slack/Mastodon intent without ad hoc overrides.

### 3. Deploy via `OmegonAgent`, not raw Deployment

`omegon-release-manager/omegon-agent.yaml` is now the right shape for GitOps desired state. Auspex should reconcile the actual Deployment/Service/probes/control-plane metadata.

The Armory bundle now exists. The remaining runtime question is installation/materialization: deployed pods still need either an image/catalog path that contains `styrene.release-manager-agent` or an Auspex/Armory install path that materializes the bundle before `omegon serve --agent styrene.release-manager-agent` starts.

## Extensions that help

### Existing or partially existing

| Capability | Status | Use |
|---|---|---|
| `vox` | Existing | Discord/Slack/community ingress/egress bridge |
| GitHub token via env/secret | Existing secret surface | Release notes, issue/PR summaries, release creation if policy allows |
| Auspex `/api/secrets/grants` | Existing | Redacted preflight evidence for required secret envelopes |
| Auspex `/api/fleet` and ACP proxy | Existing | Observe/open/control deployed daemon through fleet plane |
| Armory package discovery | Existing | Catalog/review reusable agent bundles |
| Armory overlay/preflight | Existing | Review runtime/secret/image policy before deploy |

### Extensions/packages to target

| Target | Kind | Why |
|---|---|---|
| `styrene.release-manager-agent` | Armory agent bundle | Canonical persona/workflow/secret declaration for this daemon |
| `vox-mastodon` / `vox-activitypub` | Vox connector extension | Public fediverse release/community posting without custom bot code |
| `github-release-manager` | Omegon extension or MCP/tool wrapper | Typed operations for tags/releases/changelog/PR summaries with policy gates |
| `community-publication-workflow` | Workflow package | Draft → review → approve → publish state machine; prevents accidental posts |
| `release-readiness-checker` | Agent/profile package | Checks tags, changelog, CI, image digests, SBOM/provenance, docs before announcement |
| `auspex-overlay-connectors` | Auspex enhancement | Add `connectors` to `ArmoryDeploymentOverlay` so Armory preflight fully represents bridge deployments |
| `auspex-agent-bundle-mount` | Auspex enhancement | Allow `OmegonAgent` to reference a ConfigMap/OCI artifact containing agent bundle material for non-primary agents |
| `secret-grant-files` | Auspex/Omegon enhancement | Move connector tokens away from `envFrom` into per-connector file mounts or Vault-rendered files |
| `public-post-policy` | Policy package | Explicit channel matrix, approval rules, redaction rules, vulnerability embargo rules |
| `release-outbox` | Auspex persistence/extension | Durable queue for pending announcements and retries; avoids duplicate posts |

## Secret integration implications

Prefer this progression:

1. **Now:** `authJsonSecret` for provider auth + `secretName` for connector env tokens.
2. **Better:** VSO renders `auth.json` and connector env Secret, both labeled `styrene.sh/secret-grant` for Auspex preflight visibility.
3. **Best:** `spec.secrets.vault` or CSI/Vault Agent renders file-based material directly into the pod; connector extensions read file paths rather than broad env.
4. **Future:** Auspex secret grants become first-class deploy inputs: package declares named grants, preflight verifies envelopes, deploy records grant refs, runtime receives only lease-scoped material.

## Practical next steps

1. Publish/build the `styrene.release-manager-agent` Armory artifact so generated Armory API entries include an OCI ref and verification command, not only source metadata.
2. Wire Auspex preflight/deploy to materialize the selected agent bundle for non-primary `OmegonAgent` workloads.
3. Use `omegon-release-manager/armory-overlay.yaml` as the deploy-side Auspex overlay seed for preflight/review.
4. Extend Auspex overlay schema to include `connectors` if we want connector config represented at overlay level; until then, connector selection remains in `omegon-agent.yaml` or the WebUI deploy request.
5. Decide whether the first deployment is GitOps-applied `OmegonAgent` or WebUI/Auspex preflight-and-deploy.
6. Move connector tokens away from broad `secretName` once Vox supports file/Secret-ref based connector auth.
