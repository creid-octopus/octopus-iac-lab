# Local stack overview (as of 2026-09-08)

Snapshot of what's actually running after today's bootstrap. Not aspirational, this reflects verified state only.

## What's set up

**Compose (localhost, Docker containers):**
- SQL Server 2022 (`mssql/server:2022-latest`), backing Octopus's database.
- Octopus Server (`octopusdeploy/octopusdeploy:latest`), self-hosted, license applied.

**Octopus objects (Space "IaC Sandbox", not the server default):**
- Environments: Dev, Production.
- A lifecycle, project group, tenant tag sets, and three tenants (acme-corp, globex, initech) with per-tenant variables.
- A GHCR external feed and a GitHub Git credential (pointed at your fork, `creid-octopus/octopus-iac-lab`).
- The `randomquotes` project: Config-as-Code enabled, tracking `main`, with both required channels (Stable, Ephemeral Previews), tenant links (acme-corp on Dev+Production, globex and initech on Production only), tenant branding variables (partially, see gaps below), maintenance-mode scheduled triggers, and a GHCR release trigger.
- Two older projects from earlier work, unrelated to today's bootstrap: `process-template-randomquotes` and `platform-hub-opa-randomquotes`. Not verified today, status unknown.
- Five demo-branch projects that exist but don't fully work yet (see gaps below).

**Kubernetes (Docker Desktop's built-in cluster, context `docker-desktop`):**
- NFS CSI driver, Sealed Secrets controller, Gatekeeper, Argo Rollouts, nginx-ingress controller.
- The Octopus K8s Agent, registered and online, with the live-status monitor (KLOS) wired to it.
- ArgoCD, installed and healthy, with the Octopus↔Argo Gateway connected, plus the `argocd-bootstrap` Application and both `local`/`saas` AppProjects.

## Where it's installed, and how to reach it

| Thing | Address | Notes |
|---|---|---|
| Octopus UI/API | `http://localhost:8090` | Direct, compose port. `admin` / `Password01!`. |
| ArgoCD UI | `http://argocd.localtest.me:8080` (or `localhost:8080` directly, see below) | Behind nginx-ingress. |
| Tenant apps (once deployed) | `http://<source>-<tenant>-<env>.localtest.me:8080` | Same ingress, Host-header routed. `*.localtest.me` resolves to 127.0.0.1, no `/etc/hosts` edits needed. |
| K8s Agent / Argo Gateway | No direct UI | Managed from Octopus's Infrastructure page and the ArgoCD UI respectively. |

**On the port-forward question**: checked this directly. `tofu/k8s-agent/nginx_ingress.tf` installs the controller as `type=LoadBalancer`, but on this machine's Docker Desktop Kubernetes, the assigned `EXTERNAL-IP` is a Docker bridge address (`172.18.0.2`), not `localhost`, and isn't reachable from the host directly. So `kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx`, as CLAUDE.md already documents, genuinely is the right approach here, not a workaround to improve on. One thing worth knowing: hitting `http://localhost:8080` directly (no hostname) correctly 404s, that's nginx's default backend behavior for any request that doesn't match a configured Ingress host. Use the actual hostnames (`argocd.localtest.me:8080`, or a tenant's `*.localtest.me:8080` once deployed) against the same port-forward.

## What it covers

A full Config-as-Code deployment pipeline for one sample app (`randomquotes`), demonstrated two ways into the same Kubernetes cluster:

- **Push**: the K8s Agent deploys directly, steps defined in `.octopus/deployment_process.ocl`.
- **GitOps**: ArgoCD deploys via a shared Helm chart (`gitops/charts/randomquotes/`), with Octopus's `ArgoCDUpdateImageTags` step promoting releases by bumping image tags in git.

Layered on top: multi-tenant fan-out (3 tenants across 2 environments, each with its own namespace and ingress host), native Ephemeral Environments (a parent environment plus a channel wired for one-preview-per-PR), and maintenance-mode runbooks on a schedule. The 5 demo branches, once fixed, would add blue/green, canary, a ServiceNow change-approval gate, a reusable process-template step, and a PR-preview walkthrough on top of this same base.

## Gaps before this is a "real, usable" instance

Ranked by what blocks an actual demo versus what's just incomplete polish:

1. **No release has actually been created or deployed yet.** Everything set up today is infrastructure, not a proven deployment. Nobody has cut a release and watched it land in the cluster. This is the single biggest unknown, worth doing before you trust this for a live demo.
2. **No container image exists in GHCR for this fork yet.** The GHCR feed and release trigger are wired, but `.github/workflows/build.yml` needs to actually run against `creid-octopus/octopus-iac-lab` to publish an image. Without that, a release has nothing to deploy. Check whether the GHA secrets (`OCTOPUS_LOCAL_URL`/`OCTOPUS_LOCAL_API_KEY`) are set on your fork, they won't be by default after a fork.
3. **Tenant branding is half-wired.** `Featured.Mood`, `Brand.Icon`, and `Brand.Color` exist as plain variables but aren't declared as per-tenant templates (missing `prompt {}` blocks in `.octopus/variables.ocl`), and `Brand.DisplayName` doesn't exist at all yet. Tenant-specific branding won't show correctly until that's added.
4. **5 of 7 demo-branch projects don't work**: `blue-green`, `bg-preview`, `servicenow-cr-gate`, `smoke-step-template`, `canary`. All fail on the same missing-channel bootstrap problem (documented in `docs/conference-demo-readiness.md`), one also references a missing step template.
5. **The two older projects** (`process-template-randomquotes`, `platform-hub-opa-randomquotes`) haven't been checked today, unknown whether they still work.
6. **Ephemeral Environments are wired but unexercised.** No PR-tagged image has ever gone through the flow, so it's unverified in practice, not just untested in theory.
7. **`tofu/servicenow`'s missing-on-`main` gap** means a fresh clone needs the same manual empty-state stub redone until that's fixed properly.
8. **No offline resilience yet** (the Gitea swap, tracked separately, scoped at 3 to 5 hours when you pick it up).

If the goal is "show a working deployment pipeline live," items 1 and 2 are the real blockers, everything else is either already working (core CaC + Agent + Argo) or explicitly deferred scope.
