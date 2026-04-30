# CLAUDE.md

Deployment configurations for Styrene infrastructure. This repo contains ArgoCD app definitions, Helm values, and Kustomize overlays — no application code.

For ecosystem context, see `../CLAUDE.md`.

## What This Is

GitOps deployment configs consumed by ArgoCD on the brutus K3s cluster. Changes here trigger ArgoCD sync, rolling out updates to running services.

## Structure

```
deploy/
├── omegon-site/     # Deployment config for omegon.styrene.io
├── styrene-docs/    # Deployment config for styrene.io static site
└── styrene-i2p/     # I2P eepsite gateway — all 6 Styrene sites over I2P
```

## Key Context

- ArgoCD watches this repo for changes and auto-syncs
- Application code lives in sibling repos (styrened, public-hub, etc.)
- This is the "deploy-only config" pattern — see workspace CLAUDE.md for rationale
