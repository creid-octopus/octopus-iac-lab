# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

Personal lab for scaffolding a self-hosted Octopus Server entirely as code, with Config-as-Code (CaC) on from minute one. Project state lives in Git (`.octopus/*.ocl`) rather than the Octopus database. Sandbox only — not a reference for production.

The lab is dual-target: the same OCL + tofu drives both a **local self-hosted** Octopus (this worktree) and an **Octopus Cloud SaaS** instance (a sibling worktree). The two stay in lock-step via the shared `.octopus/` and `tofu/`, differentiated only by `.env`.

## Common commands

All `make` targets run from the **repo root**. The Makefile loads `.env` once and re-exports `OCTOPUS_URL` / `OCTOPUS_API_KEY` / `GITHUB_PAT` as `TF_VAR_*` for OpenTofu.

```bash
# Local Octopus Server (compose/) — local worktree only
make up | down | logs | ps | nuke   # nuke deletes volumes — wipes DB + master key

# Bootstrap helpers (local only — SaaS has no admin/password to script against)
make master-key                     # one-shot: generate MASTER_KEY into .env (refuses to overwrite)
make mint-api-key                   # log in as admin/Password01! and write a fresh OCTOPUS_API_KEY to .env
make ensure-api-key                 # probe current key; if 401, auto-mint locally / fail-with-pointer on SaaS

# Per-stack
#   space  = tofu/space/             (the kill-switch Space)
#   cp     = tofu/control-plane/     (envs, lifecycle, project group, tenants, library vars, GHCR feed)
#   ph     = tofu/platform-hub/      (Platform Hub Git wiring)
#   app    = tofu/app-randomquotes/  (the CaC project)
#   agent  = tofu/k8s-agent/         (K8s agent + shared cluster infra)
#   argo   = tofu/argocd/            (ArgoCD install + Octopus↔Argo Gateway control plane)
#   snow   = tofu/servicenow/        (ServiceNow ITSM connection + extension settings)
make {space,cp,ph,app,agent,argo,snow}-{init,plan,apply,destroy,fmt,validate}

# Convenience
make fmt validate                   # all stacks
make apply                          # ensure-api-key → space → cp → ph → app → agent → argo
make destroy                        # ensure-api-key → reverse order
```

First-time bootstrap (local): fill `.env` with `OCTOPUS_URL`, `GITHUB_PAT`, and optionally `OCTOPUS_SERVER_BASE64_LICENSE` → `make master-key` → `make up` → `make apply`. `apply`/`destroy` depend on `ensure-api-key`, which auto-mints a fresh `OCTOPUS_API_KEY` when the existing one fails (e.g. after `make nuke` rebuilds the DB). The license auto-applies from `OCTOPUS_SERVER_BASE64_LICENSE` on first boot, or paste `compose/license.xml` via the UI. SaaS bootstrap still requires minting the API key in the UI — there's no admin/password to script against.

## Architecture

### Layout

1. **`compose/`** — docker-compose runtime (SQL Server 2022 + Octopus Server, both pinned `linux/amd64`). Host port `8090`. Reads `MASTER_KEY` from `.env`. Optional `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` is applied by `install.sh` on first boot (otherwise paste via UI). Local worktree only — the SaaS worktree has no compose stack.
2. **`tofu/`** — independent OpenTofu stacks, each with its own local `terraform.tfstate`. Deliberately split, not modules. One reusable local module under `tofu/modules/octopus-argocd-gateway/` placeholders a future provider resource (`octopusdeploy_argocd_gateway`).
3. **`gitops/`** — Argo CD's source of truth: App-of-Apps roots (one per worktree) and per-tenant leaf `Application` YAMLs. Edits here propagate to the cluster on the next Argo poll, no `tofu apply`.
3. **`.octopus/`** — OCL files owned by Octopus. Octopus serialises deployment process / settings / variables / runbooks here on every UI save and commits via the configured Git credential. **Folder name is fixed** — Octopus rejects anything other than `.octopus`.

### Cross-stack state sharing

Downstream stacks read upstream outputs via `terraform_remote_state` with `backend = "local"` pointing at sibling state files. The chain: `space` → `control-plane` → (`platform-hub` | `app-randomquotes` | `k8s-agent` | `argocd` | `servicenow`). `app` and `agent` also read `control-plane`. Apply order is enforced by the Makefile.

| Stack | Owns |
|---|---|
| `tofu/space/` | The non-default `IaC Sandbox` Space (slug pinned to `iac-sandbox`). Kill switch — destroying it cascades through every project, env, lifecycle, target inside. Both `teams-administrators` and `teams-managers` listed as Space managers; additionally, the API-key user is added to the auto-created `Space Managers` team via `space_managers_membership.tf` (provider-native adopt-via-`import` of `octopusdeploy_team`). Octopus's manual-intervention permission check matches by *direct* team membership, so being a space-manager-of via `Octopus Administrators` isn't enough on its own. |
| `tofu/control-plane/` | Environments (`Dev` sort_order=0 / `Production` sort_order=1), lifecycle, project group, GHCR external feed, library variable set (carries `Source = local|saas` per-Octopus + brand/tier defaults), tenant tag sets (mood/tier/app), three tenants (`acme-corp`/`globex`/`initech`) with per-tenant variables, tenant logos (uploaded via `null_resource` + curl to `/api/.../tenants/{id}/logo`), GitHub PAT Git credential. |
| `tofu/platform-hub/` | Octopus Platform Hub Git wiring (`/api/platformhub/versioncontrol` + `/api/platformhub/git-credentials`). Gated by `OCTOPUS_PLATFORM_HUB_ENABLED` (default `true`) so SaaS targets without the feature can opt out. |
| `tofu/app-randomquotes/` | The `randomquotes` project resource only — `is_version_controlled = true`, `is_disabled = false`, `tenanted_deployment_participation = "Tenanted"`. The deployment process and runbooks are NOT declared in HCL — they live in `.octopus/deployment_process.ocl` and `.octopus/runbooks/*.ocl`. The library variable set from control-plane is included on the project. |
| `tofu/k8s-agent/` | NFS CSI driver + nginx-ingress controller (shared cluster infra installed via `helm upgrade --install`, deliberately survives `make destroy`) + Octopus K8s Agent Helm release + a `kubernetes_namespace_v1` for the agent + Sealed Secrets controller install with key-restore/save null_resources (mirrors the active keypair to `.env` as `SEALED_SECRETS_TLS_B64` so cluster resets keep decrypting existing SealedSecrets) + a destroy-time `null_resource` that DELETEs the registered deployment target out of Octopus on `agent-destroy` (otherwise it orphans and blocks env deletion). The agent self-registers tagged with role `k8s` (which `deployment_process.ocl` targets), bound to Dev + Production, and tenant-participating. |
| `tofu/argocd/` | Minimum-footprint stack — owns only the **control plane** of the Octopus↔Argo connection: ArgoCD helm install (gated `install_argocd`, local owns), the `octopus`-account JWT mint, and the Octopus Argo CD Gateway via the `octopus-argocd-gateway` local module. The bootstrap Application that syncs `gitops/argocd/` is created via a separate `null_resource` + `kubectl apply` after the helm release (NOT via `extraObjects`, which dies on the chicken-and-egg between the Application CRD and the resource referencing it). Everything else — App-of-Apps roots, ingress, leaf Applications — lives in [`gitops/`](../gitops/) and is reconciled from git, not tofu state. |
| `tofu/servicenow/` | ServiceNow ITSM connection (OAuth or basic-auth against a PDI) + per-project `servicenow_change_control_extension_settings`. Only applied when `OCTOPUS_SERVICENOW_ENABLED=true` and a connection exists. The env-level `servicenow_extension_settings` toggle on Production lives in `tofu/control-plane/environments.tf` (always present; harmless without a wired connection). The `demo/servicenow-cr-gate` demo demonstrates the full CR-gate flow on Production deploys. |

### Local vs SaaS — what actually differs

OCL is identical across instances (same git tree); the only switch is `local.source_kind = strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"` in `tofu/control-plane/`. Everything else flows from it.

| Aspect | local self-host | SaaS (octopus.app) |
|---|---|---|
| Reachability | `localhost:8090` (+ Tailscale Funnel for GHA) | `https://lussenburg.octopus.app` |
| `compose/` | runs — db + octopus + workers | n/a, no compose stack |
| `prod-pool` | **static** worker pool, populated by `prod-pool-worker` tentacle in compose | **dynamic** worker pool, Octopus Cloud spins up `UbuntuDefault` per task |
| Built-in default pool | "Default Worker Pool" (slug `default-worker-pool`) | "Hosted Windows" + "Hosted Ubuntu" (slugs `hosted-windows`, `hosted-ubuntu`) |
| `Runbook.LinuxWorker` library var | → "Default Worker Pool" | → "Hosted Ubuntu" (per `partial_name` lookup) |
| `Source` library var | `local` | `saas` |
| Namespaces on K8s | `randomquotes-local-<tenant>-<env>` | `randomquotes-saas-<tenant>-<env>` |
| Platform Hub | enabled | enabled |
| GHA `build.yml` | leg can skip if Funnel down (`continue-on-error: true`) | always runs |

OCL pool references use slugs (e.g. `Project.WorkerPool = "prod-pool"`); naming the pool identically on both instances is what makes the same OCL resolve on both. Don't hardcode `default-worker-pool` in OCL — SaaS doesn't have a pool with that slug. Either omit (let Octopus pick the instance default) or scope per-env to a slug that exists on both.

### Secrets vs config split

- `.env` (gitignored): `MASTER_KEY`, `OCTOPUS_URL`, `OCTOPUS_API_KEY`, `GITHUB_PAT`. Optionally `OCTOPUS_SERVER_BASE64_LICENSE`, `OCTOPUS_PLATFORM_HUB_ENABLED`, `OCTOPUS_URL_FROM_CLUSTER`, `OCTOPUS_POLLING_URL_FROM_CLUSTER`, `SERVICENOW_USERNAME` + `SERVICENOW_PASSWORD` (basic-auth creds for the ServiceNow PDI used by the `demo/servicenow-cr-gate` demo — paired with an Octopus ITSM connection that holds the instance URL).
- `tofu/<stack>/defaults.auto.tfvars` (committed): non-sensitive lab values (space name, CaC repo URL/branch/base path, agent name, chart version, etc.).
- The Makefile is the only thing that bridges `.env` → `TF_VAR_*`. Don't add `terraform.tfvars` files for these.

### Auth model (lab-only choices)

- **Octopus → GitHub (CaC commits + Platform Hub)**: GitHub PAT with `repo` scope, stored as Octopus Git credentials in `control-plane` and `platform-hub`.
- **K8s agent → Octopus**: admin API key passed as `agent.bearerToken` in the Helm chart. Octopus accepts API keys as `Authorization: Bearer`. Replace with a scoped service-account key for anything non-sandbox.
- **KLOS / kubernetes monitor**: enabled. Compose publishes the container's gRPC `:8443` on host `:18443`; the monitor subchart dials `grpc://host.docker.internal:18443` pinned by the server's live self-signed cert thumbprint (fetched at apply time via `data.external`, so it survives a DB nuke). `registration.machineName` is the **agent's** machine name — the monitor binds to the existing agent deployment target rather than registering a machine of its own, so live object status surfaces on that target. Registration auths with the admin API key as a bearer token, same as the agent.

### Compose quirks worth knowing

- Host port is **8090** (not 8080) because 8080 is reserved for an ArgoCD port-forward on this machine.
- Both images forced to `linux/amd64`; enable Docker Desktop "Use Rosetta" on Apple Silicon.
- Polling tentacle port is `host.docker.internal:10943` (Halibut, TLS over TCP) — different from the HTTP API.

### Image + CI

- App image is **built from this repo** by `.github/workflows/build.yml` and pushed to `ghcr.io/creid-octopus/octopus-iac-lab`. The control-plane stack registers GHCR as an external feed; the deployment process pulls the image from there.
- `.github/workflows/release.yml` is a reusable workflow called by `build.yml` once per Octopus target via a job matrix (SaaS + Local). It creates a release on the chosen Octopus and deploys it tenanted via `OctopusDeploy/deploy-release-tenanted-action@v3` (the non-tenanted action doesn't support tenants).
- `build.yml` also pushes **Octopus Build Information** to both Octopus targets after the image push (`OctopusDeploy/push-build-information-action@v4`), so the release page shows commits + a deep link back to the GHA run.
- Local Octopus is reachable from GHA via Tailscale Funnel; if the funnel is down the local matrix leg cleanly skips with `continue-on-error: true`.
- GHA secrets: `OCTOPUS_LOCAL_URL` / `OCTOPUS_LOCAL_API_KEY` for the local target, `OCTOPUS_SAAS_URL` / `OCTOPUS_SAAS_API_KEY` for SaaS. **After `make nuke` or any other event that rotates the local `OCTOPUS_API_KEY` in `.env`, sync the new key into the GHA secret**, otherwise build-info push (and any future release deploys) fails with `The API key you provided was not valid`:
  ```
  grep '^OCTOPUS_API_KEY=' .env | cut -d= -f2- | gh secret set OCTOPUS_LOCAL_API_KEY
  ```

### Tenants + namespaces

Tenants `acme-corp`/`globex`/`initech` are each tagged with `tier/{free,pro,enterprise}` (drives replicas + watermark), `mood/{comedy,silicon-valley,stoic}` (drives quote pool), and the `app/randomquotes` participation tag. **Per-tenant lifecycle scope:** acme-corp is connected to both `Dev` and `Production` (full lifecycle, acts as the canary tenant); globex + initech are `Production`-only — modelling "different customers have different lifecycles". Combined with the envs each tenant participates in and the `Source` values (local/saas), this fans out to namespaces of the form `randomquotes-#{Source}-#{Octopus.Deployment.Tenant.Name}-#{Octopus.Environment.Name | ToLower}` — acme-corp×{Dev,Prod} + globex×Prod + initech×Prod, doubled by Source.

`Source` is supplied via the `Lab Defaults` library variable set, which differs per Octopus instance — it's not derived from the URL via Substring (we tried; library variable set is cleaner).

### Ingress

Apps are reached via the cluster's nginx-ingress controller at `*.localtest.me` (which resolves to 127.0.0.1). One `kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx` covers all tenant×env combinations. Hostnames are `#{Source}-#{tenant}-#{env}.localtest.me`. The ArgoCD UI also rides this ingress at `argocd.localtest.me:8080`.

### GitOps + push: two delivery paths into one project

Two parallel deployment shapes drive the same `randomquotes` Octopus project:

- **Push** (the K8s agent): Octopus runs the `deployment_process.ocl` steps directly; manifests are inlined in OCL. Deploys into `randomquotes-{source}-{tenant}-{env}` namespaces.
- **GitOps** (Argo CD via the Octopus Gateway): Argo Applications carry `argo.octopus.com/{project,environment,tenant}` annotations; the Gateway watches the cluster and surfaces them under Infrastructure → Argo CD Instances. Manifests come from a single Helm chart at `gitops/charts/randomquotes/`; each leaf Application supplies its own `helm.valuesObject` (tenant, mood, icon, brandColor, watermark, host, replicaCount, image.tag) so each Application renders a distinct Deployment + ConfigMap + Ingress set. Octopus's `Octopus.ArgoCDUpdateImageTags` step bumps `image.tag` only on the Applications matching the deployment's env (annotation-matched). Promotion = deploying the same Octopus release to the next env. Deploys into `argo-randomquotes-{source}-{tenant}-{env}` namespaces (separate prefix avoids collision with the agent path).
- **Empty-tag sentinel for Production:** `gitops/charts/randomquotes/values-{local,saas}-production.yaml` ships with `image.tag: ""`, and the chart's `deployment.yaml` is guarded `{{- if .Values.image.tag }} … {{- end }}`. Result: Production Applications render namespace + Service + Ingress + ConfigMap but **zero pods** until Octopus promotes a release to that env. The Octopus image-tag update step writes the real tag, the Deployment materialises on the next Argo sync. Keeps the Argo CD Instances panel honest (Octopus's promotion state = the cluster's deployment state).

The `OctopusDeploy/octopusdeploy` provider has zero Argo CD resources as of v1.12 — `tofu/modules/octopus-argocd-gateway/` placeholders the schema we'd hope they'll ship for the Gateway connection, so the eventual migration is "swap the implementation, keep the call sites".

## Editing rules of thumb

- **Don't redefine deployment process / variables / channels / runbooks in HCL.** They are owned by `.octopus/*.ocl`. Either edit OCL by hand and commit, or edit in the Octopus UI and let it commit.
- **Don't pre-populate `.octopus/`.** Let Octopus seed each file on first save so the schema matches the running server.
- **`MASTER_KEY` is generated once.** Changing it after first boot makes existing encrypted data unreadable.
- The `octopusdeploy` provider is `OctopusDeploy/octopusdeploy ~> 1.12` (the official one, not the older `OctopusDeployLabs/` fork). The k8s-agent stack additionally uses `helm` and `kubernetes` providers and requires Docker Desktop Kubernetes enabled.
- `gitops/charts/randomquotes/` is the source-of-truth Helm chart for the **GitOps path** (every leaf Application instantiates the chart with per-tenant values). Plain manifests in `app/` are not used by Argo. The K8s agent path is independent — its inlined OCL manifests live in `.octopus/deployment_process.ocl` and substitute Octopus variables at deploy time. Argo's path uses Helm values for the same per-tenant variation. Both paths target distinct namespaces (`argo-randomquotes-…` vs `randomquotes-…`) so they coexist on the same cluster.
- **Demo branches are 1 surgical commit on main.** Each open PR branch (`demo/*`, `feat/*`, `infra/ha`) carries only the files that demonstrate that feature: its own `.octopus-<demo>/` OCL, chart template overrides (`rollout.yaml`, `sealed-secret.yaml`), or stack additions (`tofu/platform-hub/policies/`, `tofu/servicenow/`). No drift on shared files (`Makefile`, `tofu/k8s-agent/`, `tofu/argocd/`, etc.). When main moves, rebase the branches (force-push-with-lease is authorised on them); don't push doc/infra updates to demo branches, push to main and let the next rebase carry them.
- **Demo OCL is `git mv` of `.octopus/`, not a copy.** The demo project's CaC payload is the *only* `.octopus-*/` on the branch — `git mv .octopus/<project files> .octopus-<slug>/` so the diff against main shows renames + the targeted edit (in this lab's case, one extra step). Keep `.octopus/process-templates/<slug>.ocl` in place (it's a Platform Hub artifact, cross-space, not a project base_path — its consumer is PH not a tofu-managed project). Copy-then-modify breaks rebase auto-resolve: when main updates `.octopus/deployment_process.ocl`, the demo branch's stale duplicate at `.octopus/...` conflicts. A clean rename has no conflict because `.octopus/...` isn't on the branch at all. The canonical `randomquotes` project is unaffected — its CaC settings track `refs/heads/main`'s `.octopus/`, and demo branches never modify that ref.
- **Process templates live in Platform Hub and use a different OCL schema than step templates** (`.octopus/process-templates/<slug>.ocl`). Gotchas burned in: (1) `default_value` is **not** on `ProcessTemplateParameter` — leaving the field out is fine, set defaults via the UI; (2) deferred packages must bind to a `Package`-typed parameter (`display_settings = { Octopus.ControlType = "Package" }`) via *three* things together — the `parameter` exists, the `packages "<Name>" { }` block name matches the parameter name, **and** `properties.PackageParameterName = "<Name>"` is set on the package block; matching block name alone is not enough (Octopus rejects with `Please select a package parameter for the package`). YAML references the package by parameter name: `#{Octopus.Action.Package[AppImage].Image}`; `feed` and `package_id` stay blank — the consuming project supplies them at instantiation. Cross-check by hitting `/api/communityactiontemplates` to see how working step templates serialize the binding. (3) `Octopus.Action.KubernetesContainers.AutoCreateNamespace = "True"` is accepted at the OCL layer on `KubernetesDeployRawYaml` even though the UI doesn't expose a toggle for that step type; (4) Platform Hub has no feeds endpoint — `/api/platformhub/feeds` is 404 — so the consuming Space's feeds resolve at instantiation time (every Space using a template needs a feed with the same slug, OR the template uses a Package-typed parameter so the project picks the feed).
- **REST endpoint to verify a process template parses without round-tripping the UI** (not advertised in the API root's Links list — found by watching `docker compose logs octopus` while the UI loads a template): `GET /api/platformhub/refs%2Fheads%2F{branch}/processtemplates/summaries` lists templates with a `HasError` flag, and `GET /api/platformhub/refs%2Fheads%2F{branch}/processtemplates/{slug}` returns the parsed template or HTTP 400 with the OCL error message body. Use this to gate template edits before merging.
- **Process Templates ≠ Project Templates** (two distinct features in Octopus's licence XML). Process Templates are reusable deployment-process snippets that projects can instantiate as steps; Project Templates is a separate (and on this version's self-hosted build, **gated-off**) feature where the entire project's identity is template-driven. The runtime check `Project templates feature toggle is not enabled` (thrown by `GetTemplatedProjectDeploymentProcessRequestHandler`) means the project-template-instantiation feature is off — Process Templates themselves still work. On SaaS (`lussenburg.octopus.app`) Project Templates is enabled; on self-hosted (2026.1.x at time of writing) it isn't, and there's no configurable toggle (the `IsEarlyAccessProgram` symbol in the binary suggests it's EAP-only).
- **Instantiating a process template in a project's `deployment_process.ocl`.** The block is a top-level sibling to `step`, with snake_case sub-keys discovered empirically by hitting `/api/Spaces-{n}/projects/{id}/{ref}/deploymentprocesses` and reading the parse errors back. Working shape:
  ```hcl
  process_template "deploy-workload" {              # block label = usage id (free-form slug)
      name                  = "Deploy app workload" # required display name
      process_template_slug = "k8s-tenanted-app"    # the template's slug in Platform Hub
      version_mask          = "1.x"                 # must match '1.x', '1.1.x', or 'prerelease' — semver values like '1.0.0' are rejected

      parameter "AppName"   { value = "randomquotes" }
      parameter "Namespace" { value = "ns-#{...}" }
      ...                                           # one parameter sub-block per template parameter

      package_parameter "AppImage" {                # one per Package-typed template parameter
          feed       = "ghcr"                       # filled in by the project (template leaves these blank)
          package_id = "creid-octopus/octopus-iac-lab"
      }
  }
  ```
  Each instantiation renders as a step with `ActionType = "Octopus.ProcessTemplate"`. Use `parameter` (singular, sub-block) — *not* `parameters = { ... }` map literals — and `package_parameter` (singular) for package bindings, *not* `packages` (which is the keyword inside the *template* file, not the *usage*). Cache gotcha: querying `/refs%2Fheads%2F{branch}/deploymentprocesses` after a push keeps returning the stale parse error; query by commit SHA (`/api/Spaces-{n}/projects/{id}/{commitSha}/deploymentprocesses`) to bypass the branch-ref cache.
- **A process-template project's auto-versioning donor must name the EXPANDED action, not the usage block.** Octopus expands the template into its child actions *before* it resolves the release version (server-side, in the feed-trigger path `FeedTriggerReleaseCreator` → `ReleaseCreationFactory.FillAndCreateRelease`). The expander renames each child to `<usage-slug>-<template-step-slug>` (id/name) — so the placeholder usage step (`deploy-workload`, type `Octopus.ProcessTemplate`) no longer exists when the donor lookup runs. In `deployment_settings.ocl` set `donor_package { package = "<PackageParamName>" step = "<usage-slug>-<template-step-slug>" }` (e.g. `step = "deploy-workload-deploy-manifests"`, same slug the auto-release trigger anchors on) — *not* `step = "deploy-workload"`. The package param name (`AppImage`) survives expansion unchanged. Verify on `…/deploymentprocesses/template?channel=…`: a non-null `VersioningPackageStepName` means it resolved; `NextVersionIncrement` stays null for *any* donor-package project (it's only set by version-template strategy), so don't read null there as failure. The public `POST /releases` always demands an explicit version (`CreateReleaseCommand.Version` is `[Required]`) and is *not* the trigger's path — don't test trigger auto-versioning against it. See [`docs/process-template-versioning.md`](docs/process-template-versioning.md).
- **A process template must be Published + Shared before a project can pin to it.** Saving the OCL in Platform Hub creates the working copy; the template is *unversioned* (`Version: null`, no `PublishedDate`) until a release is cut. Use the two API endpoints (no provider resources yet — `octopusdeploy` v1.12 doesn't ship them):
  ```bash
  # Publish a version (idempotent in the sense that re-posting the same Version errors,
  # but you can keep posting new versions — versioning is per-publish-call).
  curl -X POST "$OCTOPUS_URL/api/platformhub/refs%2Fheads%2Fmain/processtemplates/<slug>/versions" \
       -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" -H "Content-Type: application/json" \
       --data '{"ProcessTemplateSlug":"<slug>","GitRef":"refs/heads/main","Version":"1.0.0","IsPreRelease":false}'

  # Share to all Spaces (or pass space IDs explicitly).
  curl -X POST "$OCTOPUS_URL/api/platformhub/refs%2Fheads%2Fmain/processtemplates/<slug>/share" \
       -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" -H "Content-Type: application/json" \
       --data '{"ProcessTemplateSlug":"<slug>","GitRef":"refs/heads/main","ShareToAllSpaces":true,"IndividuallySharedSpaceIds":[]}'
  ```
  These endpoints are server-wide (Platform Hub), not Space-scoped. API-key auth works (no CSRF token needed). When the provider eventually ships `octopusdeploy_platform_hub_process_template_*` resources, swap these for tofu — until then, a `null_resource` + `local-exec` curl in `tofu/platform-hub/` would be the idiomatic place.
- **OCL scope identifiers use slugs, not display names.** `environment = ["Production"]` and `environment = ["Dev"]` in a `variable "X" { value "..." { environment = [...] } }` block are rejected with `Scope["Environment"][0] has unknown slug "Production"`. Use the env *slug* — `production`, `dev` — exactly as `/api/Spaces-{n}/environments` reports it. Tenant tags are the exception: `tenant_tag = ["tier/enterprise"]` uses the tag *name* (with the canonical `tag-set/tag` shape) because that's how Octopus stores tag references. Rule of thumb: anything that has both an Id and a Slug (Environment, Project, Space, Channel) uses the slug in OCL scopes; anything that's a free-form string identifier (Tenant tag, parameter name) uses the literal value.
- **Worker-pool selection via OCL: use the typed `worker_pool_variable` field on the action, NOT `Octopus.Action.WorkerPoolVariable` in the Properties dict, AND put the variable at the project level (not on a library set).** Both are real gotchas — together they cost most of a session. (1) The Properties-dict form is accepted by the API but Octopus's worker-selection codepath silently ignores it and falls back to the default pool. The typed field on the `action { worker_pool_variable = "Project.WorkerPool" }` block is what actually gets honored. (2) Even with the typed field set, env-scoped variables defined in a *library variable set* don't resolve correctly during worker selection — Octopus picks the unscoped value on Production deploys (env scoping kicks in too late in the worker-selection path for library-set vars). Project-level variables defined in `.octopus/variables.ocl` with `environment = ["production"]` scope DO resolve correctly. WorkerPool-typed OCL values use the pool *slug* (`prod-pool`), not the ID (`WorkerPools-22`). And note: `WorkerView` / `WorkerEdit` both have `RestrictedTo: []` — no per-pool RBAC at the permission layer. Workers themselves have no environment scope, no roles, no labels — only pool membership, machine policy, and optional tenant participation. So the user-axis gate against "dev with ProcessEdit pins prod-pool on their own step" has to live in Platform Hub process-validation policy (Rego with `package octopus.process`), not in Octopus RBAC. As of `octopusdeploy` v1.12 there's no provider resource for that policy type — the rule sits on demo/platform-hub-opa as a placeholder until Octopus exposes it.
- **Template versions are immutable snapshots; bump the version after schema changes.** Editing a published template's OCL on `main` doesn't propagate to consumers — they keep using the snapshot the published version captured. Republish (`make template-publish TEMPLATE=<slug> VERSION=X.Y.Z`) every time you change the template's parameters, steps, or package bindings; bump the major when you rename or remove a parameter so existing `version_mask = "X.x"` pins don't silently break. We hit this twice in one session: (a) v1.0.0 captured the old `Application name` parameter slug pre-rename, and consumers using `version_mask = "1.x"` failed with "Parameter 'Application name' is required" even though the working copy on main had been renamed to `AppName`; (b) v2.0.0 captured the template mid-edit when it had only one step, so consumers got a single-step expansion — only after publishing v2.1.0 from the current main did the full 2-step expansion (workload + Argo image-tag) appear in release snapshots.
