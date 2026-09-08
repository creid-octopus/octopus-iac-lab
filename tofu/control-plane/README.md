# tofu/control-plane/

Shared Octopus infra inside the Space. Apply once after `space-apply`, then largely leave alone.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config + `terraform_remote_state` for the Space |
| [`variables.tf`](variables.tf) | Inputs (fed via `TF_VAR_*` from the root `Makefile`) |
| [`environments.tf`](environments.tf) | `Dev` and `Production` |
| [`lifecycle.tf`](lifecycle.tf) | `Dev → Production` |
| [`project_group.tf`](project_group.tf) | `IaC Lab` project group |
| [`feeds.tf`](feeds.tf) | GHCR external feed (`ghcr.io`) for the `creid-octopus/octopus-iac-lab` image |
| [`library_variables.tf`](library_variables.tf) | `lab-source` library variable set — carries `Source = local|saas` (per-Octopus), `GitHub.Token`, `Runbook.LinuxWorker` (per-instance Linux pool lookup). Included on the project. |
| [`tenants.tf`](tenants.tf) | Fictional customer tenants (`acme-corp`, `globex`, `initech`) + tag sets (`tier/{free,pro,enterprise}`, `mood/{comedy,silicon-valley,stoic}`, `app/randomquotes`) + per-tenant variables (brand colour/icon, mood, replicas) |
| [`tenant_logos.tf`](tenant_logos.tf) | Uploads brand-coloured PNG logos to each tenant via `null_resource` + curl POST to `/api/{space}/tenants/{id}/logo` (the provider doesn't expose a logo attribute). Retriggers on file SHA. |
| [`worker_pools.tf`](worker_pools.tf) | The `prod-pool` worker pool. Branched on `local.source_kind`: **static** on local (workers register from compose), **dynamic** (`UbuntuDefault`) on SaaS (Octopus Cloud auto-provisions per task). Same slug both instances, so OCL references resolve everywhere. |
| [`teams.tf`](teams.tf) | Demo users (`developer`, `prod-deployer`) + scoped teams (`developers`, `prod-deployers`) with `scoped_user_role` bindings composing Octopus's built-in roles (Project viewer + Environment viewer + Deployment creator [Dev-scoped for devs] + Release creator). |
| [`user_roles.tf`](user_roles.tf) | The single custom `Developer-AddOn` overlay role — adds `GitCredentialView` + `VariableView` (which Octopus's slim built-in roles don't include). All other RBAC uses built-in roles. |
| [`git_credential.tf`](git_credential.tf) | GitHub PAT credential Octopus uses for CaC commits |
| [`outputs.tf`](outputs.tf) | IDs the app + agent stacks read via `terraform_remote_state` |

## Run

From the repo root:

```bash
make cp-init
make cp-plan
make cp-apply
```
