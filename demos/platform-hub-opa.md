# Platform Hub OPA — local proof run

Captured 2026-05-11 against `demo/platform-hub-opa` (PR #46) with PR #45 (Gatekeeper controller) + PR #47 (chart `tier` + k8s labels) merged to main.

Two enforcement paths, one Rego bundle. Re-validated from a fully nuked compose stack — see [Part 3: fresh-from-scratch run](#part-3--fresh-from-scratch-make-nuke--make-apply).

## Tooling versions

```
conftest: dev  (OPA 1.15.2)
helm:     v3.x (homebrew)
kubectl:  v1.x
gatekeeper helm chart: 3.22.2 (latest matching 3.* constraint)
```

## Part 1 — admission-side: Gatekeeper deploys (PR #45)

Ran the `helm upgrade --install` command that `tofu/k8s-agent/gatekeeper.tf` issues:

```bash
helm upgrade --install gatekeeper gatekeeper \
  --repo https://open-policy-agent.github.io/gatekeeper/charts \
  --version "3.*" \
  --namespace gatekeeper-system --create-namespace \
  --kube-context docker-desktop \
  --atomic --wait
```

```
Release "gatekeeper" does not exist. Installing it now.
chart=gatekeeper requested=3.* selected=3.22.2
NAME: gatekeeper
LAST DEPLOYED: Mon May 11 17:09:08 2026
NAMESPACE: gatekeeper-system
STATUS: deployed
```

```
$ kubectl get pods -n gatekeeper-system
NAME                                             READY   STATUS    RESTARTS   AGE
gatekeeper-audit-85d57dd999-9jb25                1/1     Running   0          32s
gatekeeper-controller-manager-5dc7b68bf8-9lkpf   1/1     Running   0          32s
gatekeeper-controller-manager-5dc7b68bf8-bdrr2   1/1     Running   0          32s
gatekeeper-controller-manager-5dc7b68bf8-cdjpp   1/1     Running   0          32s
```

CRDs installed include `constrainttemplates.templates.gatekeeper.sh`, `assign.mutations.gatekeeper.sh`, and the constraint-status types — full admission-controller surface ready. No ConstraintTemplates loaded yet (those land with the demo branch's Platform Hub registration, currently a placeholder).

**Result: ✅ PR #45 helm install reproducible, controller healthy.**

## Part 2 — in-deploy gate: conftest against rendered chart (PR #46)

### Compliant case — every tier passes

```bash
helm template gitops/charts/randomquotes \
  --set host=test.localtest.me \
  --set tenant=acme-corp \
  --set tier=free \
  --set replicaCount=1 \
  | conftest test - -p tofu/platform-hub/policies/
```

```
48 tests, 48 passed, 0 warnings, 0 failures, 0 exceptions
```

Same for `tier=pro replicaCount=2` and `tier=enterprise replicaCount=3` — all clean.

### Tier rule fires — the headline demo

```bash
helm template gitops/charts/randomquotes ... --set tier=free --set replicaCount=5 \
  | conftest test - -p tofu/platform-hub/policies/
```

```
FAIL - - main - tier=free allows max 1 replicas, got 5

48 tests, 47 passed, 0 warnings, 1 failure, 0 exceptions
```

Exit code: `1`. In Octopus this fails the deploy step before any manifest hits the cluster.

### Image registry rule — only ghcr.io/creid-octopus

Synthetic manifest pulling `docker.io/library/nginx:1.25`:

```
FAIL - - main - container[0] image "docker.io/library/nginx:1.25" not from an allowed registry (["ghcr.io/creid-octopus/"])
```

### :latest tag rule

Synthetic manifest using `ghcr.io/creid-octopus/octopus-iac-lab:latest`:

```
FAIL - - main - container[0] uses :latest tag (image="ghcr.io/creid-octopus/octopus-iac-lab:latest")
```

### Multi-violation manifest

A deliberately broken Deployment (`namespace: default`, no labels, privileged, no limits):

```
FAIL - - main - Deployment "bad" container[0] is privileged
FAIL - - main - Deployment "bad" is missing required label "app.kubernetes.io/instance"
FAIL - - main - Deployment "bad" is missing required label "app.kubernetes.io/name"
FAIL - - main - Deployment "bad" is missing required label "app.kubernetes.io/part-of"
FAIL - - main - container[0] "c" has no CPU limit
FAIL - - main - container[0] "c" has no memory limit
FAIL - - main - namespace "default" does not match lab convention ^(argo-)?randomquotes-[a-z0-9-]+$

12 tests, 5 passed, 0 warnings, 7 failures, 0 exceptions
```

All seven rules fire concurrently — proves no policy is silently no-op.

**Result: ✅ PR #46 Rego bundle validates compliant manifests, fails violations with precise messages.**

## Reproducing this report

```bash
# Install conftest (one-time)
brew install conftest

# Install Gatekeeper (one-time per cluster)
helm upgrade --install gatekeeper gatekeeper \
  --repo https://open-policy-agent.github.io/gatekeeper/charts \
  --version "3.*" --namespace gatekeeper-system --create-namespace \
  --atomic --wait

# Run the compliant case
helm template gitops/charts/randomquotes \
  --set host=x --set tenant=acme-corp --set tier=enterprise --set replicaCount=3 \
  | conftest test - -p tofu/platform-hub/policies/

# Run the headline violation
helm template gitops/charts/randomquotes \
  --set host=x --set tenant=acme-corp --set tier=free --set replicaCount=5 \
  | conftest test - -p tofu/platform-hub/policies/
```

## Part 3 — fresh-from-scratch (`make nuke` → `make apply`)

To prove the bundle works against a freshly-bootstrapped Octopus (not just an already-running one), the local compose stack was nuked and re-applied end-to-end.

### Wipe

```bash
$ echo y | make nuke
 Container selfhost-setup-octopus-1 Stopped/Removed
 Container selfhost-setup-db-1      Stopped/Removed
 Volume selfhost-setup_mssql-data           Removed
 Volume selfhost-setup_octopus-repository   Removed
 Volume selfhost-setup_octopus-tasklogs     Removed
 Volume selfhost-setup_octopus-artifacts    Removed
 Network selfhost-setup_default             Removed
$ docker volume ls --filter name=selfhost-setup
DRIVER    VOLUME NAME           (empty)
```

### Re-up + re-seed admin API key

```bash
$ make up                           # boots db + octopus from scratch
$ # Octopus container healthy after ~80s
$ # License auto-applied from OCTOPUS_SERVER_BASE64_LICENSE in .env (install.sh)
$ # Re-bind the pre-existing API key from .env to fresh admin user:
$ docker exec selfhost-setup-octopus-1 /Octopus/Octopus.Server admin \
    --user=admin --apiKey=$OCTOPUS_API_KEY
Refreshing view dbo.Dashboard …
Always-run post scripts "succeeded"
Creating or modifying administrator "admin"
Done.
$ curl -s -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" http://localhost:8090/api/licenses/licenses-current-status \
    | jq '{IsCompliant, EffectiveExpiryDate}'
{ "IsCompliant": true, "EffectiveExpiryDate": "2027-04-27" }
```

### Re-apply all 6 tofu stacks

```bash
$ yes yes | make apply 2>&1 | grep -E 'Apply complete|Error:'
Apply complete! Resources: 1 added,  0 changed, 0 destroyed.   # space
Apply complete! Resources: 26 added, 0 changed, 0 destroyed.   # control-plane
Apply complete! Resources: 2 added,  0 changed, 0 destroyed.   # platform-hub
Apply complete! Resources: 1 added,  0 changed, 0 destroyed.   # k8s-agent (just Gatekeeper from #45)
```

`app-randomquotes` apply needed the `-target` two-stage workaround for the channel-data-source chicken-and-egg (pre-existing repo issue, unrelated to this PR — projects must exist before the data source can find their auto-created "Default" channel):

```bash
$ tofu apply -auto-approve -target='octopusdeploy_project.this' \
                          -target='octopusdeploy_project.branch_demo'
Apply complete! Resources: 4 added
$ tofu apply -auto-approve
# 3/4 branch-demo projects succeed (blue-green, bg-preview, canary)
# 4th (demo/platform-hub-opa) trigger create fails:
Error: Trigger 'Auto-release on new randomquotes-image' has an action slug
       'deploy-manifests' which does not exist in the project's deployment process.
```

The platform-hub-opa demo branch deliberately ships **only** the Rego bundle — no `.octopus-platform-hub-opa/` with a real `deploy-manifests` step. Octopus auto-seeded an empty OCL skeleton on first project save (commit `ef1c060` "Converting project to use VCS"), then the trigger creation tripped on the missing step. Expected; documented in PR #46.

### Gatekeeper installed via the actual tofu file (not by hand)

```
null_resource.gatekeeper (local-exec): Executing helm upgrade --install gatekeeper …
null_resource.gatekeeper (local-exec): Release "gatekeeper" does not exist. Installing it now.
null_resource.gatekeeper (local-exec): STATUS: deployed
null_resource.gatekeeper: Creation complete after 13s
Apply complete! Resources: 1 added
```

```
$ kubectl get pods -n gatekeeper-system
NAME                                             READY   STATUS    RESTARTS   AGE
gatekeeper-audit-85d57dd999-58xxj                1/1     Running   0          28s
gatekeeper-controller-manager-5dc7b68bf8-b95jf   1/1     Running   0          28s
gatekeeper-controller-manager-5dc7b68bf8-wpqkh   1/1     Running   0          28s
gatekeeper-controller-manager-5dc7b68bf8-zkr5t   1/1     Running   0          28s
```

### Conftest still green against the post-nuke chart

```
$ helm template gitops/charts/randomquotes \
    --set host=test --set tenant=acme-corp --set tier=enterprise --set replicaCount=3 \
    | conftest test - -p tofu/platform-hub/policies/
48 tests, 48 passed, 0 warnings, 0 failures, 0 exceptions

$ helm template gitops/charts/randomquotes \
    --set host=test --set tenant=initech --set tier=free --set replicaCount=5 \
    | conftest test - -p tofu/platform-hub/policies/
FAIL - - main - tier=free allows max 1 replicas, got 5
48 tests, 47 passed, 0 warnings, 1 failure, 0 exceptions
```

### Result

| Stack | Status | Notes |
|---|---|---|
| compose (db + octopus) | ✅ | Fresh DB, license + admin API key restored automatically |
| space | ✅ | `IaC Sandbox` recreated as `Spaces-2` |
| control-plane | ✅ | 26 resources: envs, lifecycle, tenants, tag sets, library var set, GHCR feed |
| platform-hub | ✅ | Git CaC wiring |
| app-randomquotes | ⚠️ | 3/4 demo projects rebuilt; `demo/platform-hub-opa` trigger fails as expected (no OCL `deploy-manifests` step on that branch by design) |
| k8s-agent | ✅ | Gatekeeper installed via `null_resource` + helm (the exact path PR #45 introduces) |
| Rego bundle | ✅ | 48/48 pass compliant; tier rule fires on `free + replicas=5` |

## Part 4 — fresh-from-scratch v2 (after PR #48 lands)

Re-ran the full cycle on top of merged #48, which added `TOFU_APPLY_FLAGS=`, `FORCE=1` for nuke, and the `depends_on` fix on the channel data source. Goal: prove the Part 3 workarounds are no longer needed.

```
$ make nuke FORCE=1
 (4 volumes + network removed, no prompt)             ~2s

$ make up
 (db healthy, then octopus health: starting…)

$ # poll inspect on selfhost-setup-octopus-1
Octopus healthy after 90s

$ docker exec selfhost-setup-octopus-1 /Octopus/Octopus.Server admin \
    --user=admin --apiKey=$OCTOPUS_API_KEY
Creating or modifying administrator "admin"
Done.

$ curl -s -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" .../licenses-current-status \
    | jq '{IsCompliant, EffectiveExpiryDate}'
{ "IsCompliant": true, "EffectiveExpiryDate": "2027-04-27" }
```

### Single-shot apply — no `-target` workaround, no `yes yes |`

```
$ make apply TOFU_APPLY_FLAGS=-auto-approve
Apply complete! Resources: 1 added,  0 changed, 0 destroyed.   # space
Apply complete! Resources: 26 added, 0 changed, 0 destroyed.   # control-plane
Apply complete! Resources: 2 added,  0 changed, 0 destroyed.   # platform-hub
# app-randomquotes: 3/4 demo-branch triggers succeed
#   ProjectTriggers-3 ← demo/blue-green
#   ProjectTriggers-4 ← demo/bg-preview
#   ProjectTriggers-5 ← demo/canary
#   FAIL ← demo/platform-hub-opa (no deploy-manifests step, see below)

Error: octopus deploy api returned an error on endpoint /api/Spaces-2/projecttriggers -
       [Trigger 'Auto-release on new randomquotes-image' has an action slug
        'deploy-manifests' which does not exist in the project's deployment process.]
  with octopusdeploy_external_feed_create_release_trigger.branch_demo["demo/platform-hub-opa"]

$ make agent-apply TOFU_APPLY_FLAGS=-auto-approve   # ran separately since
                                                    # app-apply failure halted make
null_resource.deregister_agent: Refreshing state...
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.   # k8s-agent (Gatekeeper still present)
```

### What's different from Part 3

| Was in Part 3 | Now in Part 4 |
|---|---|
| `yes yes \| make apply` — leaked "yes" to stdin readers | `make apply TOFU_APPLY_FLAGS=-auto-approve` |
| Two-stage `tofu apply -target=octopusdeploy_project.{this,branch_demo}` then full apply | Single `make apply` — the `depends_on` fix defers the channels data source to apply time |
| `echo y \| make nuke` | `make nuke FORCE=1` |
| `app-randomquotes` partially applied (3 demos worked, 1 failed) due to the channel-data-source race | `app-randomquotes` reaches the same 3-out-of-4 result, but for the right reason: only the `demo/platform-hub-opa` trigger fails — because the branch ships only the Rego bundle, no `.octopus-platform-hub-opa/` with a `deploy-manifests` step. Documented in PR #46. |

### Final conftest run against the freshly-applied chart

```
$ helm template gitops/charts/randomquotes \
    --set tenant=acme-corp --set tier=enterprise --set replicaCount=3 --set host=test \
    | conftest test - -p tofu/platform-hub/policies/
48 tests, 48 passed, 0 warnings, 0 failures, 0 exceptions

$ helm template gitops/charts/randomquotes \
    --set tenant=initech --set tier=free --set replicaCount=5 --set host=test \
    | conftest test - -p tofu/platform-hub/policies/
FAIL - - main - tier=free allows max 1 replicas, got 5
48 tests, 47 passed, 0 warnings, 1 failure, 0 exceptions
```

### Result

- **#48 fixes verified end-to-end.** No `-target`, no `yes` pipe, no DB pre-existing.
- **Only outstanding from-scratch issue** is the `demo/platform-hub-opa` trigger creation — by design, not a regression. The demo branch deliberately ships zero OCL steps. If you want a fully-green `make apply`, exclude this branch from `TF_VAR_demo_branches` until the demo's `Validate against Platform Hub` step is added on the branch (see PR #46 description for the OCL snippet).
