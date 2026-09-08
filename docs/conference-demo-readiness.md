# Conference demo readiness checklist

Goal: run this lab live at a conference on a local network, resilient to bad or absent venue wifi. Scope decided 2026-09-08:

- Pre-cache everything so the demo doesn't depend on a live pull, but keep GitHub/GHCR reachable as a fallback if wifi does work.
- Replace GitHub as the GitOps source with a local Gitea instance, so Argo CD never depends on internet during the demo itself.

This doc is a working checklist, not a finished runbook. Update it as you test each item.

## Open question: instruqt-octopus-host-images

`/Users/cory/repos/instruqt-octopus-host-images` was not attached to the session that produced this doc, so the Gitea integration steps below are a best-guess pattern, not a copy of that repo's actual approach. Before you build this out, attach that repo and confirm:

1. How it wires Gitea into docker-compose (service definition, port, volumes).
2. How it auto-creates the repo and pushes initial content into Gitea on first boot.
3. How Octopus's Git credential and Argo CD's `repoURL` get pointed at Gitea instead of GitHub.
4. Whether it runs a local container registry too, or only replaces git.

## First full bootstrap (2026-09-08) — what broke and what's fixed

Ran the entire chain end to end for the first time on this machine: `space` → `control-plane` → `platform-hub` → `app-randomquotes` → `k8s-agent` → `argocd`. Several real bugs surfaced, not just missing docs. The fixes are already committed to the working tree; this section is the record of what changed and why, so a future `make nuke` or a fresh-machine bootstrap doesn't require rediscovering all of it.

### Fixed in the repo

1. **Fork URL drift.** Every `cac_repo_url`/`ph_repo_url`/`repoURL` still pointed at `creid-octopus/octopus-iac-lab` instead of this fork (`creid-octopus/octopus-iac-lab`). Fixed across 23 files in `tofu/` and `gitops/`.
2. **`tofu/control-plane/lifecycle.tf`** used the provider's old `release_retention_policy`/`tentacle_retention_policy` blocks, deprecated as of provider 1.19.x (this repo's `~> 1.12` constraint resolves to 1.19.3). Switched to `release_retention_with_strategy`/`tentacle_retention_with_strategy`, same 30-day intent.
3. **`tofu/app-randomquotes/outputs.tf`**: `project_url` read `octopusdeploy_project.randomquotes.space_id`, which comes back `null` after an import (provider gap). Pointed it at `data.terraform_remote_state.space.outputs.space_id` instead, a value we already have reliably.
4. **`tofu/app-randomquotes/tenant_variables.tf`**: crashed indexing `local.template_ids` because `.octopus/variables.ocl` never actually declares `Brand.DisplayName`/`Featured.Mood`/`Brand.Icon`/`Brand.Color` with a `prompt {}` block (which is what makes Octopus treat a variable as a per-tenant template). Made the lookup skip any pair whose template doesn't exist yet instead of crashing — **still need to add the missing `prompt {}` blocks to `.octopus/variables.ocl`** to actually light up tenant branding variables; that's a content decision, not made for you.
5. **`tofu/k8s-agent/sealed_secrets.tf`**: Helm repo URL `bitnami-labs.github.io/sealed-secrets` 404s — the `bitnami-labs` GitHub org migrated to `bitnami` on 2026-06-15 and GitHub Pages doesn't redirect. Updated to `bitnami.github.io/sealed-secrets`.
6. **`tofu/argocd/argocd_install.tf`**: `argocd_bootstrap` and `appproject` were `kubernetes_manifest` resources, which validate a manifest's kind against the cluster's live API discovery at plan time. On a truly fresh cluster, the `Application`/`AppProject` CRDs (installed by this same `helm_release`, same run) aren't visible yet, so this always fails on first bootstrap with "no matches for kind X in group argoproj.io", no matter how `depends_on` is set. Rewrote both as `null_resource` + `kubectl apply`, matching the pattern already used for nginx-ingress/Sealed Secrets, and the working reference in `iac-octopus/argocd/terraform` (which avoids `kubernetes_manifest` entirely for this exact reason).

### Workarounds applied live, not yet in code

1. **`space_managers_membership.tf`'s import** can't resolve on a truly fresh Space, because the import ID depends on `octopusdeploy_space.this.id`, which doesn't exist until the same apply creates it. Worked around today with a two-step apply (`-target=octopusdeploy_space.this` first, then a plain apply). Same class of chicken-and-egg as the Argo one above; worth converting to the same `null_resource` pattern, or accepting the two-step apply as documented, permanent behavior.
2. **`randomquotes_stable`/`ephemeral_previews` channels** (`tofu/app-randomquotes/channels.tf` + `ephemeral.tf`): the project's CaC deployment process references channel slugs `stable`/`ephemeral-previews` from the moment it's created, but those channels are separate resources that depend on the project already existing — and the project's own deployment-settings update re-validates against currently-existing channels on *every* touch, not just creation. Genuinely circular on a fresh Space. Worked around today by creating both channels directly via the Octopus API and importing them into state. **This will hit again on the next from-scratch Space** (a real `make nuke`, or a fresh machine) until it's fixed properly — most likely by moving channel creation to `null_resource` + API calls that don't go through the project resource's own validation path, mirroring the Argo fix above.
3. **`tofu/servicenow/`** doesn't exist on `main` (per CLAUDE.md, it's a `demo/servicenow-cr-gate`-only stack addition), but `tofu/app-randomquotes/main.tf` unconditionally reads `../servicenow/terraform.tfstate` regardless of branch. Stubbed an empty local state file by hand to unblock. Not committed (state files are gitignored), so **this stub needs recreating after any fresh clone** until the actual repo bug (a `main`-branch stack depending on demo-branch-only infrastructure) is fixed.
4. **Two Makefile/OCL gaps worth fixing in docs, not code**: `make apply` doesn't run `tofu init` first — CLAUDE.md's quick-start skips straight from `make up` to `make apply`, which fails on a truly fresh checkout. And `.env`'s `OCTOPUS_SPACE_IS_DEFAULT` needs to be `false` on this local self-host instance (the built-in `Default` space is already server-default; a from-scratch bootstrap can't also make `IaC Sandbox` default without manually demoting `Default` first).

### Known, deliberately deferred

**5 of the 7 demo-branch projects** (`blue-green`, `bg-preview`, `servicenow-cr-gate`, `smoke-step-template`, `canary`) fail to apply: their committed OCL references the same `stable`/`ephemeral-previews` channel slugs (same circular problem as above, times five) and one (`smoke-step-template`) also references a step-action template ID that doesn't exist in this Space. Left alone deliberately, not needed for the core demo. Revisit once the channel-creation ordering is fixed for real; the fix should resolve most of these automatically, `smoke-step-template`'s action-template reference is a separate issue.

### Infrastructure sizing

Running SQL Server 2022 + Octopus Server (compose) alongside a full Docker Desktop Kubernetes cluster (nginx-ingress, NFS CSI, Sealed Secrets, the K8s Agent, ArgoCD, Gatekeeper, Argo Rollouts) genuinely saturated Docker Desktop's default resource allocation today — the UI and even `docker stats` itself became unresponsive. Fixed by raising Docker Desktop's limits to 8 CPUs / 24GB RAM (machine has 64GB total). **Set this before the conference, not during it** — a cold laptop with default Docker Desktop limits will likely repeat this.

## 1. Add a local Gitea service

None of this exists in `octopus-iac-lab` yet. New work:

1. Add a `gitea` service to `compose/docker-compose.yml` (image `gitea/gitea:latest`, pin to a specific tag once chosen).
2. Write a bootstrap script that creates an admin user, an access token, and a repo (mirroring the shape of `octopus-iac-lab` itself, or a scoped-down copy) on first boot.
3. Push the current repo content into that Gitea repo as the CaC + GitOps source of truth for the demo.
4. Point `tofu/control-plane`'s Git credential at Gitea instead of GitHub (swap the PAT for a Gitea token).
5. Point `gitops/*-root-local.yaml`'s `repoURL` at the local Gitea repo.

Keep this behind a flag or a separate compose override file, so you can still run the real GitHub-backed setup for non-demo work.

## 2. Pre-pull container images

Run this on your home network before you leave, then verify nothing re-pulls at the venue:

- `mcr.microsoft.com/mssql/server:2022-latest`
- `octopusdeploy/octopusdeploy:latest`
- `octopusdeploy/tentacle:latest`
- `alpine:latest`
- `gitea/gitea:latest` (once added)

Consider pinning each to a digest once pulled, so a `docker compose pull` at the venue can't silently grab a different image if wifi is up.

## 3. Pre-cache Terraform providers and Helm charts

These currently pull live on every `init`/`apply`, with no local cache:

1. `OctopusDeploy/octopusdeploy`, `hashicorp/helm`, `hashicorp/kubernetes`, `hashicorp/null`, `oboukili/argocd`. Run `tofu init` on all six stacks at home so the plugin cache under `~/.terraform.d/plugin-cache` is warm, and confirm the Makefile/tofu config actually points at that cache directory.
2. Helm charts, each currently fetched via `--repo` at apply time: nginx-ingress, ArgoCD, Sealed Secrets, NFS CSI driver, Gatekeeper, Argo Rollouts, plus the Octopus K8s Agent chart (`oci://registry-1.docker.io/octopusdeploy`). Run `helm pull` for each into a local chart cache, or `helm repo add` + `helm repo update` at home so the local Helm repo cache is populated.
3. Test a full `make apply` with wifi disabled, right after the pre-cache step, to confirm nothing still reaches out.

## 4. GHCR and image feed

The control-plane feed and the app image both come from `ghcr.io/creid-octopus/octopus-iac-lab`. Two options:

1. Pre-pull the app image into local Docker, and if the demo needs a fresh build during the session, skip that step and use the last known-good tag.
2. Confirm the GHCR feed in Octopus resolves the cached image locally rather than re-checking the registry on every deploy (verify this behavior; if it always calls out, decide whether that's acceptable given the "resilient, not air-gapped" scope).

## 5. Network dependency map after these changes

| Dependency | Still needed? |
|---|---|
| GitHub (CaC push, gitops repoURL) | No, replaced by local Gitea |
| GHCR (image feed) | Yes, unless image is pre-pulled and feed check is skip-able |
| Docker Hub / registry-1.docker.io (compose images, agent Helm chart) | No, if pre-pulled per section 2 |
| Helm chart repos (ingress-nginx, argo-helm, etc.) | No, if pre-cached per section 3 |
| Terraform registry | No, if provider cache is warm per section 3 |
| Tailscale Funnel | No, CI-only, not used in a live demo |
| ServiceNow PDI | Only if you're running the `demo/servicenow-cr-gate` demo branch |

## 6. Day-before checklist

1. Run `make nuke && make up && make apply` end to end on your home network, timing it.
2. Disable wifi/ethernet on the laptop, then re-run `make down && make up` and a `tofu plan` on each stack to confirm nothing calls out.
3. Confirm Argo CD's Application list shows `Synced` against the local Gitea repo, not github.com.
4. Charge the laptop, and if the venue has no reliable LAN, bring a travel router so your own devices can reach `localhost:8090` / `*.localtest.me` over your own wifi instead of the venue's.

## 7. Day-of checklist

1. Do not connect to venue wifi before the demo starts, so you're testing the same offline state you'll actually run on stage.
2. Have a fallback: a screen recording of a full successful run, in case something in the room (proxy, captive portal, corporate firewall) breaks something pre-caching didn't anticipate.
3. Know the one command that resets state fast (`make down && make up`) in case you need to recover mid-demo.
