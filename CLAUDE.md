# CLAUDE.md

Deployment configurations for Styrene infrastructure. This repo contains ArgoCD app definitions, Helm values, and Kustomize overlays — no application code.

For ecosystem context, see `../CLAUDE.md`.

## What This Is

GitOps deployment configs consumed by ArgoCD on the brutus K3s cluster. Changes here trigger ArgoCD sync, rolling out updates to running services.

## Structure

```
deploy/
└── styrene-docs/    # Deployment config for docs.styrene.io static site
```

## Key Context

- ArgoCD watches this repo for changes and auto-syncs
- Application code lives in sibling repos (styrened, public-hub, etc.)
- This is the "deploy-only config" pattern — see workspace CLAUDE.md for rationale
