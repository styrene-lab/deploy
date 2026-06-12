# Dedicated release-manager runtime plan

This plan defines the path from the Brutus Kubernetes smoke deployment to a dedicated miniPC runtime for the Styrene release-manager agent. It uses the vocabulary from `styrene-hub`: OS/service molecules, compounds, Nex reconciliation for the OS layer, and Auspex/OmegonAgent or ExternalAgent for the agent control plane.

## Goal

Run `styrene.release-manager-agent` as a durable, public-facing but tightly governed Omegon daemon on a dedicated miniPC, while keeping Brutus available as a quick integration test lane.

The long-term runtime should be reproducible, observable by Auspex, secret-minimized, and safe for community-facing release/posting workflows.


## 2026-06-11 Brutus smoke progress — Vox bootstrap path

The Brutus release-manager smoke lane advanced from "Vox installed" to a clear host/runtime bootstrap boundary.

Completed:

- `vox` now supports SDK-owned runtime configuration through `bootstrap_config`.
  - Commit: `e2f90b8 feat(vox): accept bootstrap runtime config`
  - Release metadata bump: `e75bb5b chore(release): bump vox to 0.1.4`
  - Published release: `https://github.com/styrene-lab/vox/releases/tag/v0.1.4`
  - Required Linux artifact exists: `vox-0.1.4-x86_64-unknown-linux-musl.tar.gz`
- Vox `main` has a post-`v0.1.4` hardening series pushed and CI-green.
  - Range: `9491778..1c63414` after tag `v0.1.4`.
  - Latest commit: `1c63414 test(connectors): cover permissive token file degradation`
  - CI: `https://github.com/styrene-lab/vox/actions/runs/27425331797` completed successfully.
  - Scope: per-token secret-file permission checks, connector degradation tests, panic removal in startup/tool serialization paths, stale LXMF cfg warning removal, clippy cleanups.
  - Not released/tagged; Brutus installer remains intentionally pinned to the published `v0.1.4` artifact until a future Vox release is authorized.
- `auspex` now installs Vox `v0.1.4` for connector agents.
  - Commit: `63c121f fix(operator): install vox 0.1.4`
  - Validation: `cargo test -p auspex-operator` passed, 21 tests.
- `omegon` has the host-side SDK/runtime contract implemented and pushed.
  - Commit: `21406271 feat(extensions): bootstrap manifest runtime config`
  - Adds manifest `runtime.config`, `runtime.env`, and `runtime.env_passthrough`.
  - Delivers `bootstrap_config` before `bootstrap_secrets`, so connector config is present before secret-backed connector startup.
  - Preserves clean extension environments; secrets still travel through `bootstrap_secrets` or mounted files, not inherited process env.

Live cluster evidence before the host-image update:

- The release-manager pod has the intended deploy env and mounted config:
  - `VOX_CONFIG=/config/vox/vox.toml`
  - `VOX_CONFIG_PATH=/config/vox`
  - `/config/vox/vox.toml` contains `[discord]` and `[slack]` sections with file-backed token paths.
- Current runtime image remains `ghcr.io/styrene-lab/omegon:0.26.5`, which predates `bootstrap_config` support.
- Current Vox startup therefore still falls back to the default config path:
  - `vox config loaded config=/workspace/.config/vox/vox.toml`

Current blocker:

- Omegon push CI for `21406271` is red on an unrelated settings/model-selection test:
  - Run: `https://github.com/styrene-lab/omegon/actions/runs/27319453945`
  - Issue: `https://github.com/styrene-lab/omegon/issues/137`
  - Failure: `settings::tests::selector_policy_constrains_assembly_to_requested_lower_class` expects `Standard` but current inference returns `Massive`.
- Do not work over the agents owning `settings.rs`; that file has unrelated in-flight changes.
- No Omegon runtime tag/release/image was created from this thread.

Next authorized deploy step once Omegon owners restore CI and publish an approved runtime image containing `21406271`:

1. Roll `auspex-operator` so generated release-manager pods install Vox `v0.1.4`.
2. Update the release-manager runtime image to the approved Omegon image containing `bootstrap_config` support.
3. Reconcile/restart `OmegonAgent/release-manager`.
4. Verify logs show Vox loading from the SDK-delivered path, expected:
   - `vox config loaded from bootstrap_config path config=/config/vox/vox.toml`
5. Then verify connector registration/startup for Slack and Discord without enabling unapproved publication behavior.

## Deployment lanes

### Lane A — Brutus smoke

Purpose: validate runtime behavior and Auspex integration before provisioning dedicated hardware.

Current artifacts:

- `omegon-release-manager/omegon-agent.yaml` — direct GitOps/Auspex `OmegonAgent` target.
- `omegon-release-manager/armory-overlay.yaml` — Auspex Armory preflight/review overlay seed.
- `omegon-release-manager/vault-auth.yaml` — VSO bridge for provider auth and connector tokens.

Smoke criteria:

1. `styrene.release-manager-agent` is materialized into the pod runtime catalog.
2. `omegon serve --agent styrene.release-manager-agent` starts on Omegon 0.26.5.
3. Auspex `/api/fleet` lists the daemon.
4. `/api/agents/{namespace}/{name}/control-plane` returns ACP/control metadata.
5. `/api/secrets/grants` shows the required secret envelopes by reference only.
6. Discord/Slack connectors do not publish without explicit approval or configured workflow policy.

### Lane B — dedicated miniPC runtime

Purpose: isolate the public/community automation runtime from the main cluster and make it reproducible with Nex.

Target topology:

```text
Nex compound / forge provisioning
  -> miniPC OS substrate
  -> rootless Podman or systemd Omegon daemon
  -> Armory release-manager bundle materialized locally
  -> file-based secrets and TLS material
  -> Auspex ExternalAgent registration
```

Recommended first durable shape:

- NixOS miniPC.
- Rootless Podman for the Omegon runtime container.
- `styrene.release-manager-agent` installed under the runtime catalog.
- Control plane on `7842` with TLS/mTLS before any non-LAN exposure.
- Auspex observes through `ExternalAgent` first; full remote lifecycle management can come later.

## Compound shape

Styrene-hub's `molecules + compounds` model should own the node definition. The deploy repo should only reference or register the result.

Target compound:

```yaml
apiVersion: styrene.io/v1alpha1
kind: Compound
metadata:
  name: release-manager-runtime
  version: 0.1.0
spec:
  description: Dedicated miniPC runtime for Styrene release/community agent

  os:
    base: styrix-base:0.2.0
    molecules:
      - name: podman
        version: "5.x"
      - name: omegon-agent-runtime
        version: "0.26.x"
      - name: control-plane-mtls
        version: "0.x"
      - name: vault-agent
        version: "1.x"
    values:
      linux:
        hostname: styrene-release-manager-01
        desktop: null
        cpuGovernor: schedutil
        firewall:
          allowedTCPPorts: [22, 7842, 7843, 7844, 7845]

  agents:
    - name: release-manager
      agent: styrene.release-manager-agent
      runtime: omegon
      mode: daemon
      controlPort: 7842
      terminalTool: false
```

The `agents` section is aspirational; styrene-hub currently defines `os` and `services`. This should either become a first-class section or be represented by an OS molecule/node override until the compound schema grows.

## Runtime unit sketch

Rootless Podman managed by systemd matches the existing `styrene-runner` miniPC guidance.

```ini
[Unit]
Description=Styrene Release Manager Omegon daemon
After=network-online.target
Wants=network-online.target

[Service]
User=omegon
Group=omegon
Restart=always
RestartSec=10

ExecStart=/usr/bin/podman run --rm \
  --name omegon-release-manager \
  --publish 7842:7842 \
  --volume /var/lib/omegon/catalog:/data/omegon/catalog:ro \
  --volume /var/lib/omegon/state:/root/.omegon \
  --volume /run/omegon/secrets:/run/omegon/secrets:ro \
  --volume /run/omegon/control-tls:/run/omegon/control-tls:ro \
  --env OMEGON_AUTH_JSON_PATH=/run/omegon/secrets/auth.json \
  --env OMEGON_TERMINAL_TOOL=0 \
  ghcr.io/styrene-lab/omegon:0.26.5 \
  serve \
    --control-port 7842 \
    --strict-port \
    --agent styrene.release-manager-agent \
    --control-tls-cert /run/omegon/control-tls/tls.crt \
    --control-tls-key /run/omegon/control-tls/tls.key \
    --control-tls-client-ca /run/omegon/control-tls/ca.crt

ExecStop=/usr/bin/podman stop omegon-release-manager

[Install]
WantedBy=multi-user.target
```

## Secret posture

Long-term connector/provider secrets should be file-based, not broad process environment.

Preferred progression:

1. Brutus smoke: `authJsonSecret` + `secretName` as already declared.
2. Dedicated MVP: host-local file mounts from SOPS/age or manually provisioned files.
3. Durable: Vault/OpenBao Agent renders files and control-plane TLS material.
4. Target: Nex/Auspex secret grants declare lease-scoped references and runtime receives only file paths.

Target runtime paths:

```text
/run/omegon/secrets/auth.json
/run/omegon/secrets/github_token
/run/omegon/secrets/discord_token
/run/omegon/secrets/slack_bot_token
/run/omegon/secrets/slack_app_token
/run/omegon/control-tls/tls.crt
/run/omegon/control-tls/tls.key
/run/omegon/control-tls/ca.crt
```

## ExternalAgent registration

First dedicated-host registration should use Auspex `ExternalAgent`:

```yaml
apiVersion: styrene.sh/v1alpha1
kind: ExternalAgent
metadata:
  name: release-manager-minipc
  namespace: omegon-agents
spec:
  display_name: Styrene Release Manager miniPC
  endpoint: https://styrene-release-manager-01.internal.styrene.io:7842
  token_secret: release-manager-minipc-control-token
  probe_interval_seconds: 30
  labels:
    role: release-manager
    placement: minipc
    agent: styrene.release-manager-agent
```

This is adequate for monitoring/proxy MVP. For production, Auspex should support mTLS references on `ExternalAgent` rather than bearer-token-only control.

# Gap matrix before issue creation

## deploy repo

Current status:

- Has Brutus smoke `OmegonAgent`.
- Has Auspex Armory overlay seed.
- Has VSO bridge and secret-surface docs.
- Has Armory status/update docs.

Gaps:

1. Add `external-agent.yaml` once the miniPC endpoint and auth mode are known.
2. Add a small Brutus smoke checklist/runbook.
3. Reference the eventual styrene-hub compound artifact once it exists.
4. Decide whether `omegon-agent.yaml` is a temporary smoke-only manifest or remains a supported fallback lane.

Issue candidates:

- `deploy`: Add release-manager ExternalAgent manifest for dedicated miniPC.
- `deploy`: Add Brutus smoke checklist for release-manager OmegonAgent.

## omegon-armory

Current status:

- `styrene.release-manager-agent` source bundle exists.
- Registry and tests recognize 7 catalog agents / 37 public API items.

Gaps:

1. Publish/build OCI artifact so generated API has `ociRef`, digest, and `verifyCommand` for `styrene.release-manager-agent`.
2. Add compatibility metadata that states native Omegon catalog-agent support and degraded generic entrypoints.
3. Add optional workflow artifact for release publication: draft -> review -> approve -> publish.
4. Add package metadata for required/optional secret semantics in the public API if generated entries do not currently expose them for agents.

Issue candidates:

- `omegon-armory`: Publish OCI artifact for `styrene.release-manager-agent`.
- `omegon-armory`: Add release publication workflow package/metadata.
- `omegon-armory`: Expose agent required/optional secrets in generated Armory API entries.

## styrene-hub

Current status:

- Defines molecules/compounds model.
- Documents OS molecules as Nex profile TOML fragments.
- Documents `styrene-runner` miniPC with NixOS + rootless Podman + Omegon daemon port range.

Gaps:

1. Add `release-manager-runtime` compound.
2. Add `omegon-agent-runtime` OS molecule.
3. Add or formalize an `agents` section in compounds, or document how agent daemons are represented as OS molecule values.
4. Add control-plane mTLS and Vault/OpenBao agent OS molecules if not already present.
5. Connect compound output to Auspex `ExternalAgent` registration.

Issue candidates:

- `styrene-hub`: Define release-manager-runtime compound for dedicated miniPC.
- `styrene-hub`: Add omegon-agent-runtime OS molecule for rootless Podman daemon hosts.
- `styrene-hub`: Extend compound schema or docs for agent runtime sections.

## nex

Current status observed from repo/search:

- Has Armory store/lock/materialization work.
- Forge-template validation currently fails closed in existing work history until schema validation exists.
- Has machine-profile and materialization-payload concepts.

Gaps:

1. Validate and materialize `forge-template` packages rather than failing closed.
2. Pull OS molecules from OCI and compose them through existing profile merge semantics.
3. Generate NixOS/systemd/rootless-Podman config from a compound/node override.
4. Emit host facts for Auspex ingestion: endpoint, version, agent id, TLS posture, bundle digest, secret substrate.
5. Provide a dedicated `release-manager-minipc` forge template or example.
6. Support safe secret substrate choices: Vault Agent, SOPS/age, systemd credentials.

Issue candidates:

- `nex`: Support forge-template validation/materialization.
- `nex`: Support OCI OS molecule resolution and profile composition.
- `nex`: Emit Auspex-compatible host facts after provisioning.
- `nex`: Add release-manager miniPC forge template.

## auspex

Current status:

- `OmegonAgent` reconciles daemon agents into Deployment + Service.
- `ExternalAgent` monitors external Omegon endpoints with `token_secret`.
- Armory overlay/preflight exists.
- Deploy requests support connectors, but `ArmoryDeploymentOverlay` does not model connectors directly.
- Only `styrene.auspex-primary` gets inline catalog ConfigMap mounting.

Gaps:

1. Add `connectors` to `ArmoryDeploymentOverlay` and generated `AgentPackage` path.
2. Materialize/mount agent bundles for non-primary managed `OmegonAgent` workloads.
3. Extend `ExternalAgent` for mTLS CA/client secret refs and server fingerprint pinning.
4. Ingest Nex host facts and synthesize/update `ExternalAgent` records.
5. Expose richer ExternalAgent lifecycle: control-plane TLS posture, bundle digest, agent id, runtime version, last probe reason.
6. Add release publication outbox / approval-state integration if Auspex is the operator-facing review surface.

Issue candidates:

- `auspex`: Add connectors to Armory deployment overlays.
- `auspex`: Materialize Armory agent bundles for non-primary OmegonAgent pods.
- `auspex`: Add mTLS control-plane fields to ExternalAgent.
- `auspex`: Ingest Nex host facts into ExternalAgent registry.
- `auspex`: Add release/publication outbox review surface.

## omegon

Current status:

- `omegon serve --agent <id>` loads catalog agent manifests.
- Runtime supports `OMEGON_AUTH_JSON_PATH` and headless control-plane endpoints in current release line.

Gaps:

1. Headless catalog install/materialization path suitable for container startup.
2. Runtime report of active agent bundle id + bundle digest in `/api/startup` or `/api/state`.
3. File-based secret references for Vox connectors or extension bootstrap.
4. Public-post workflow guardrails in runtime/workflow layer.
5. Ensure `terminal_tool = false` and `OMEGON_TERMINAL_TOOL=0` are enforced clearly for bridge daemons.

Issue candidates:

- `omegon`: Add headless catalog materialization/install support for daemon startup.
- `omegon`: Report active agent bundle id and digest in control-plane metadata.
- `omegon`: Support file-based connector secret references for headless agents.
- `omegon`: Add governed publication workflow primitives.

## vox

Current status:

- Existing connector extension covers Discord/Slack bridge use cases.

Gaps:

1. File-based token references for Discord/Slack instead of env-only tokens.
2. Mastodon/ActivityPub connector for public release posts.
3. Publication policy hooks: draft-only, require approval, channel allowlist, rate limits.
4. Clear operator/user trust metadata in public bridge events.

Issue candidates:

- `vox`: Add file-based connector token configuration.
- `vox`: Add Mastodon/ActivityPub connector.
- `vox`: Add publication policy hooks for approval-gated public posting.

# Issue ordering recommendation

Open issues in this order:

1. `styrene-hub`: release-manager-runtime compound and omegon-agent-runtime OS molecule.
2. `nex`: OCI OS molecule + forge-template materialization support.
3. `auspex`: ExternalAgent mTLS + Nex host-fact ingestion.
4. `auspex`: non-primary Armory agent bundle materialization.
5. `omegon-armory`: publish release-manager OCI artifact and workflow metadata.
6. `omegon`/`vox`: file-based connector secrets and runtime bundle digest reporting.
7. `deploy`: add ExternalAgent manifest once endpoint/auth facts exist.

