# AGENTS.md

Styrene deployment surface for public-facing services and agent-accessible infrastructure. This repo contains ArgoCD application definitions, Kubernetes manifests, Helm values, and Kustomize overlays — no application code.

For ecosystem context, see `../AGENTS.md` if present, or the sibling project guidance in the Styrene workspace.

## What This Is

GitOps deployment config consumed by ArgoCD on the brutus K3s cluster. Changes here update desired cluster state and may roll out public services.

This repo is becoming the Styrene-org-wide public-facing agent surface: agents should be able to discover what is deployed, identify service boundaries, and make bounded manifest changes without depending on vendor-specific instruction files.

## Structure

```
deploy/
├── omegon-release-manager/ # Auspex OmegonAgent target for release/community manager
├── omegon-site/            # Deployment config for omegon.styrene.io
├── styrene-docs/           # Deployment config for styrene.io static/docs surfaces
└── styrene-i2p/            # I2P eepsite gateway and mesh↔I2P bridge
```

## Operating Constraints

- ArgoCD watches this repo for changes and auto-syncs.
- Application code lives in sibling repos such as `styrened` and `public-hub`.
- Keep runtime/application changes in source repos; only commit desired cluster state here.
- Treat public-facing manifests as production-facing unless a file or namespace explicitly marks staging.
- Respect existing uncommitted manifest changes before editing; this repo is watched by ArgoCD.

## Agent-Surface Conventions

- `AGENTS.md` is the canonical, vendor-neutral guidance file. Do not add vendor-specific instruction mirrors.
- Prefer service directories named after the public surface or cluster service they operate.
- Keep manifests readable and grep-friendly: explicit namespaces, labels, image names, ports, and comments for non-obvious public exposure.
- Prefer immutable image tags (`sha-...` or version tags) over `latest` for reproducible rollouts.
- Use Vault/VSO or sealed-secret patterns for credentials; never commit raw secrets.

## Repo Hygiene

- Do not commit local agent/runtime state (`.omegon/`, `.flynt/`, `ai/memory/`).
- Do not commit generated memory databases, sockets, audit logs, or local profile state.
- Before committing, run at least `git diff --check` and inspect all manifest image/tag changes.
