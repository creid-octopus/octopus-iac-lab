# app/

The Random Quotes K8s sample app — the artefact Octopus deploys.

| File | Purpose |
|------|---------|
| [`Dockerfile`](Dockerfile) | nginx + static `index.html`, with a `VERSION` build-arg that gets baked into the page footer. Built + pushed to `ghcr.io/creid-octopus/octopus-iac-lab` by [`../.github/workflows/build.yml`](../.github/workflows/build.yml). |
| [`index.html`](index.html) | The actual page. Reads `/config.json` at startup for tenant/mood/icon/colour/watermark/maintenance overrides — that file is materialised by Octopus at deploy time via a ConfigMap. Honours a `maintenance` overlay used by the `Maintenance Mode On` runbook. |

> **Where are the K8s manifests?** Two places — Octopus's K8s agent path inlines them in [`../.octopus/deployment_process.ocl`](../.octopus/deployment_process.ocl), and the Argo CD path renders them from a helm chart at [`../gitops/charts/randomquotes/`](../gitops/charts/randomquotes/) instantiated by the leaf Applications under [`../gitops/applications/randomquotes/{local,saas}/`](../gitops/applications/) with per-tenant values.

## Build locally (optional)

```bash
docker build -t randomquotes:dev .
docker run --rm -p 8080:80 randomquotes:dev
open http://localhost:8080
```

## How Octopus uses this

[`../.octopus/deployment_process.ocl`](../.octopus/deployment_process.ocl) steps:

1. **Deploy ConfigMap** — `Octopus.KubernetesDeployConfigMap` writes `config.json` (tenant/mood/icon/colour/watermark + empty maintenance) into a ConfigMap named `randomquotes-config`.
2. **Deploy Manifests** — `Octopus.KubernetesDeployRawYaml` applies an inline Deployment (image pulled from the GHCR feed via the `randomquotes-image` package reference), Service, and Ingress for `#{Source}-#{tenant}-#{env}.localtest.me`. The ConfigMap is mounted into the pod at `/usr/share/nginx/html/config.json`.
3. **Update Argo CD Application Image Tags** — `Octopus.ArgoCDUpdateImageTags` walks the Argo CD Applications annotated with `argo.octopus.com/project.<source>` matching this project, updates `image.tag` in their helm values via the Octopus Argo CD Gateway, and waits for them to reconcile healthy.

All three actions bind `worker_pool_variable = "Project.WorkerPool"` so Production deploys lease from `prod-pool` (static on local, dynamic on SaaS).

The `Maintenance Mode On` runbook ([`../.octopus/runbooks/maintenance-on.ocl`](../.octopus/runbooks/maintenance-on.ocl)) patches the same ConfigMap with `maintenance = #{Maintenance.Message}` and scales the Deployment to 1 replica; `Maintenance Mode Off` clears the message and scales back to the tier's `#{Replicas}` value.
