# tofu/app-randomquotes/

The `randomquotes` Octopus project. Tenanted, CaC-enabled, reads everything else from `control-plane` outputs.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config + `terraform_remote_state` data sources for the Space and control-plane |
| [`variables.tf`](variables.tf) | Inputs (fed via `TF_VAR_*` from the root `Makefile`) |
| [`project.tf`](project.tf) | The `randomquotes` project. `is_version_controlled = true`, `tenanted_deployment_participation = "Tenanted"`, `git_library_persistence_settings` pointing at this repo's `.octopus/`. Includes the `lab-source` library variable set. Linked to the tenants via `octopusdeploy_tenant_project`. Binds the preview runbooks as the native ephemeral-env provisioning/deprovisioning hooks. |
| [`branch_demos.tf`](branch_demos.tf) + [`branch_demo_triggers.tf`](branch_demo_triggers.tf) | `for_each` over `var.demo_branches` (set in `defaults.auto.tfvars`) — provisions one `<slug>-randomquotes` project per kept-open demo branch, each CaC-tracking that branch with `base_path = .octopus-<slug>/`. Auto-release trigger on the new GHCR image is also created per branch. For `demo/process-template` the trigger anchors on the **expanded** action slug (`<usage-slug>-<template-step-slug>`, e.g. `deploy-workload-deploy-manifests`), not the `Octopus.ProcessTemplate` usage step. |
| [`ephemeral.tf`](ephemeral.tf) | Native Ephemeral Environments — a parent environment (`Previews`) + a `Type = EphemeralEnvironment` channel with the `preview-pr-#{PR.Number}` name template. Provider-native (octopusdeploy ~> 1.12). Populates the project's Ephemeral Environments page; the preview runbooks become its provisioning/deprovisioning hooks. |
| [`outputs.tf`](outputs.tf) | Project URL + ID for convenience |

## What's NOT here

- **Deployment process** — lives in [`../../.octopus/deployment_process.ocl`](../../.octopus/deployment_process.ocl) (CaC-managed by Octopus). All actions bind `worker_pool_variable = "Project.WorkerPool"` so Production deploys lease from `prod-pool`.
- **Auto-versioning** — the donor-package `step` in `deployment_settings.ocl` names a real package action. For a `process_template` project the action is the **expanded** one (`<usage-slug>-<template-step-slug>`), not the usage block — Octopus expands the template before it resolves the version. See [`../../docs/process-template-versioning.md`](../../docs/process-template-versioning.md). `NextVersionIncrement: null` on the template endpoint is normal for donor strategy; the signal that it resolved is a non-null `VersioningPackageStepName`.
- **Runbooks** — live in [`../../.octopus/runbooks/`](../../.octopus/runbooks/).
- **Project variables** — live in [`../../.octopus/variables.ocl`](../../.octopus/) alongside the deployment process. Includes the env-scoped `Project.WorkerPool` (Production → `prod-pool`).
- **Image build** — happens in [`.github/workflows/build.yml`](../../.github/workflows/build.yml). Image is `ghcr.io/creid-octopus/octopus-iac-lab` (built from this repo's [`app/Dockerfile`](../../app/Dockerfile)), pulled via the GHCR feed registered in `control-plane`.
- **K8s manifests as files** — packaged as a helm chart in [`../../gitops/charts/randomquotes/`](../../gitops/charts/randomquotes/) and instantiated by the leaf Applications under `gitops/applications/randomquotes/{local,saas}/`. Each leaf supplies its own `helm.valuesObject` for tenant/mood/icon/color/host/replicas. The deployment process OCL inlines its own manifests for the K8s agent path; the gitops/ tree is the source for the Argo path.

## Run

From the repo root, after `make space-apply` and `make cp-apply`:

```bash
make app-init
make app-plan
make app-apply
```
