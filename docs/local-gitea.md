# Local Gitea — offline git for the lab

Replaces github.com with a Gitea container on your own machine, so Config-as-Code commits and Argo CD syncs keep working with no internet. Built for conference/bad-wifi runs, opt-in, and it leaves the normal GitHub-backed setup completely untouched.

## The intended workflow

The end state is that the lab doesn't care about github.com at all, it just reconciles from it occasionally. One direction only:

```
Octopus Cloud (test a deployment/feature)
        ↓
hosted GitHub repo (source of truth for content)
        ↓   make gitea-mirror        ← the only step needing internet
local Gitea (the lab's git)
        ↓
local Octopus + Argo CD run the same content as cloud
```

The principle that keeps this sane: **content lives in git and is identical everywhere; being offline is purely environmental configuration.** Anything that forces the offline setup to be a *different commit* is working against the model, and the one remaining place that still does is called out under "What's left" below.

Two push paths, deliberately distinct:

| Command | Direction | Use |
|---|---|---|
| `make gitea-mirror` | upstream GitHub refs → Gitea | Sync loop. Reads `refs/remotes/origin/*`, never your working tree, so unfinished local work can't leak into the lab. Force-pushes, since upstream always wins. |
| `make gitea-push` | your local commit → Gitea | Dev loop, when you're iterating locally and want the lab to see it before it exists upstream. |

Three phases. Phase 1 is done and verifiable now; Phases 2 and 3 are scoped but not built.

| Phase | What it covers | Status |
|---|---|---|
| 1 | Gitea running, bootstrapped, holding this repo | **Done, verified** |
| 1b | Reversible switch of Octopus CaC, Platform Hub, and Argo CD onto Gitea | **Done** — `cp-apply`, `ph-apply`, `argo-apply` all clean against Gitea |
| 1c | Backend-agnostic OCL (`Git.CloneUrl`) + upstream mirror (`gitea-mirror`) | **Done** |
| 2 | Gitea Actions + `act_runner`, ported build workflow | Not started |
| 3 | Image distribution (`kind load` into the cluster) + Octopus feed change | Not started |

### What's left before the repo truly "doesn't care about github"

1. **The `gitops/` root Applications still hardcode `repoURL`.** This is the last thing forcing the offline setup to be a divergent commit. Fixing it means having the bootstrap Application inject `repoURL` as a Helm value (tofu already knows the backend), so switching touches zero git files. Cost: `gitops/argocd/*.yaml` stops being plain readable YAML, which matters in a repo you demo from. 1 to 2 hours.
2. **The previews ApplicationSet uses a GitHub pull-request generator**, which talks to api.github.com and has no Gitea equivalent wired up. Previews simply don't work offline today.
3. **`app-apply` still fails on the demo-branch projects**, because reading a CaC project's deployment settings needs its branch to exist in the configured repo and only `main` is mirrored. Either mirror those branches (`make gitea-mirror REFS="main demo/canary ..."`) or drop the projects.

## Phase 1: what was added

| File | Purpose |
|---|---|
| `compose/gitea.yaml` | Gitea service, its own compose project (`selfhost-gitea`), joining the main stack's network |
| `compose/configure-gitea.sh` | Idempotent bootstrap: waits for the API, creates the admin, mints a token, creates the repo, pushes your current commit |
| `Makefile` | `gitea-up`, `gitea-bootstrap`, `gitea-push`, `gitea-logs`, `gitea-down`, `gitea-nuke` |
| `.env.example` | Documents the optional `GITEA_*` variables |

Choices worth knowing, because they differ from the instruqt tracks this was adapted from:

- **Separate compose project, not a service in `docker-compose.yml`.** `make up`, `make down`, and `make nuke` behave exactly as before. Gitea is only running if you asked for it.
- **No `/etc/timezone` or `/etc/localtime` bind mounts.** The instruqt tracks mount those, but they don't exist on macOS and the container won't start with them. Gitea runs UTC here.
- **Named volume (`gitea-data`), not a bind mount into the repo.** Keeps untracked Gitea state out of your working tree, and matches how the main compose stack handles its volumes.
- **Pushes your current commit, not github's `main`.** The point of offline mode is that what you have locally is what the lab runs.
- **A named `gitea` git remote gets added** to your repo, so day-to-day pushes are `make gitea-push`.

## Addressing, the part that bites

One repo, three different addresses depending on who's asking:

| Caller | URL | Why |
|---|---|---|
| Your Mac (browser, `git push`) | `http://localhost:3000` | Published container port |
| Octopus container | `http://gitea:3000` | Same docker network, resolves by service name |
| Kubernetes pod (Argo CD) | `http://host.docker.internal:3000` | The cluster is a separate network namespace and cannot resolve `gitea` |

**Anything both Octopus and Argo CD read must use the `host.docker.internal` form.** That means the CaC repo URL and every Application `repoURL` in Phase 1b. This mirrors what the K8s agent already does with `http://host.docker.internal:8090` to reach Octopus, which is known to work on this setup.

`host.docker.internal` does *not* resolve on the Mac itself, only inside containers, which is why Gitea's `ROOT_URL` stays on `localhost` (otherwise every link in the web UI would break).

## Running it

Ordering matters — Gitea attaches to the network the main stack creates:

```bash
make up               # must come first, creates selfhost-setup_default
make gitea-up
make gitea-bootstrap
```

`gitea-up` checks for that network and tells you to run `make up` first rather than failing with docker's more cryptic error.

## Verification

Each check is independent, run whichever you care about.

**1. Container healthy**

```bash
docker compose -f compose/gitea.yaml ps
```

Expect `gitea` with status `running (healthy)`. The healthcheck polls `/api/healthz`, so healthy means the API really is answering, not just that the process started.

**2. API reachable from your Mac**

```bash
curl -fsS http://localhost:3000/api/healthz | jq
```

Expect `"status": "pass"`.

**3. Admin login works**

Open `http://localhost:3000` and log in as `admin` / `Admin123!`. You should land on a dashboard with one repository, `admin/octopus-iac-lab`.

**4. Your commit actually arrived**

```bash
git ls-remote http://localhost:3000/admin/octopus-iac-lab.git refs/heads/main
git rev-parse HEAD
```

Both should print the same SHA. If they differ, you have local commits that haven't been pushed — run `make gitea-push`.

**5. Octopus can resolve Gitea** (this is what Phase 1b depends on)

```bash
docker exec selfhost-setup-octopus-1 curl -fsS -o /dev/null -w '%{http_code}\n' http://gitea:3000/api/healthz
```

Expect `200`. If the container name doesn't match, get it from `make ps`.

**6. Argo CD can reach Gitea** (this is what Phase 1b depends on)

Test from `argocd-repo-server`, the component that actually clones repos, doing the actual thing it will do:

```bash
kubectl -n argocd exec deploy/argocd-repo-server -- \
  git ls-remote http://host.docker.internal:3000/admin/octopus-iac-lab.git
```

Expect your `main` SHA. That confirms both name resolution and git-over-HTTP from the exact pod that matters.

> Don't test this with a throwaway `curlimages/curl` pod. That image is Alpine/musl, and musl's handling of the cluster's `ndots:5` search-domain expansion reports `Could not resolve host: host.docker.internal` even when resolution is working fine everywhere else in the cluster. Verified working value for reference: `host.docker.internal` resolves to `192.168.65.254` (Docker Desktop's host gateway) from a normal pod.

**7. Token was persisted**

```bash
grep '^GITEA_TOKEN=' .env
```

Should show a 40-character hex token. `make gitea-push` uses it.

## Phase 1b: switching the lab onto Gitea

```bash
make gitea-enable      # point everything at Gitea
make gitea-disable     # go back to github.com
```

Both directions are reversible and the round trip is byte-identical, verified by flipping a scratch copy both ways and diffing against the original.

### What the switch touches

| Target | Mechanism |
|---|---|
| `cac_repo_url` (control-plane, app-randomquotes), `ph_repo_url`, `gitops_repo_url` | Generated `gitea.auto.tfvars` per stack (gitignored) |
| 12 `repoURL` fields under `gitops/` | Text rewrite in the working tree — the one remaining wart, see "What's left" |
| `.octopus/runbooks/` git clones | **No longer touched.** They use `#{Git.CloneUrl}`, a tofu-managed library variable that carries whatever backend the stack is configured for |
| Octopus's git credential + the `GitHub.Token` and `Git.CloneUrl` library variables | Makefile swaps `TF_VAR_github_username`/`TF_VAR_github_pat` to `admin`/`$GITEA_TOKEN` when `GITEA_ENABLED=true` |

One credential is deliberately *not* swapped: `applicationset_github_pat`, which feeds the `github-pat` secret the previews ApplicationSet uses to authenticate against api.github.com. It always comes from `GITHUB_PAT`, because handing GitHub a Gitea token just gets it rejected.

Two things forced that split, both worth knowing if you ever debug this:

- **The tofu side can't use `TF_VAR_*` for the repo URLs.** `cac_repo_url` and `ph_repo_url` are set in each stack's committed `defaults.auto.tfvars`, and `*.auto.tfvars` files *outrank* environment variables in OpenTofu's precedence order, so a `TF_VAR_cac_repo_url` export would be silently ignored. `*.auto.tfvars` files load lexicographically with later ones winning, and "gitea" sorts after "defaults", so a generated `gitea.auto.tfvars` lands on top. Switching back is just deleting the file.
- **The `gitops/` and `.octopus/` URLs can't be templated by tofu at all.** Argo CD and Octopus read those files *from git*, not from tofu state, so the change has to be a real committed edit. Hence the text rewrite, and hence the ordering below.

### Order of operations

The `gitops/` rewrites only take effect once they're actually in Gitea, so commit and push before applying:

```bash
make gitea-enable
git commit -am "Point lab at local Gitea"   # required — see below
make gitea-push                    # rewritten gitops/ URLs into Gitea
make cp-apply ph-apply app-apply   # Octopus CaC + Platform Hub → Gitea
make argo-apply                    # bootstrap Application → Gitea
```

**The commit is not optional.** `gitea-enable` edits your working tree, and git pushes commits rather than working trees. Skip it and you'd push your previous HEAD, Argo would clone Gitea and find the old GitHub URLs still in `gitops/`, and the App-of-Apps would quietly point every leaf Application back at github.com. `make gitea-push` refuses to run with uncommitted changes under `gitops/` or `.octopus/` for exactly this reason (`FORCE=1` overrides if you really mean it).

There's no push to github.com in this flow, and there shouldn't be. In Gitea mode the lab reads only from Gitea, so `origin` falling behind is correct.

**Don't merge the switched URLs to `main`.** They point at one machine's `host.docker.internal`. Do this work on a branch (`feat/gittea` or similar) and keep `main` on the github.com URLs. Going back is `make gitea-disable` plus another commit.

### Verification after switching backends

**Octopus is reading CaC from Gitea**

In the Octopus UI, open the `randomquotes` project → Settings → Version Control. The repository URL should be the `host.docker.internal:3000` one. Then make a trivial edit in the UI (a variable description will do) and save it — the commit should appear in Gitea, not GitHub.

**Argo CD is syncing from Gitea**

```bash
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,REPO:.spec.source.repoURL
```

Every row should show the Gitea URL. Any row still on `github.com` means that Application's manifest didn't get pushed, re-run `make gitea-push`.

**Nothing is still reaching for GitHub**

```bash
kubectl -n argocd logs deploy/argocd-repo-server --tail=50 | grep -i github || echo "no github references"
```

**The credential swap took effect**

```bash
make cp-plan
```

Expect no changes. If it wants to change the git credential's username, `GITEA_ENABLED` isn't being picked up from `.env`.

## Re-running and resetting

`configure-gitea.sh` is safe to re-run; every step checks state first. Full reset:

```bash
make gitea-nuke       # drops the container and the volume, all repos gone
make gitea-up
make gitea-bootstrap
```

The token in `.env` is rewritten on each bootstrap, so nothing needs cleaning up by hand.

## Phase 2 preview: the offline Actions gotcha

Worth knowing before you start Phase 2, because it shapes how the workflow gets written: Gitea Actions resolves `uses:` references against github.com by default (`DEFAULT_ACTIONS_URL`). So a workflow with `uses: actions/checkout@v4` still needs internet, even though Gitea itself doesn't.

Two ways out: mirror those action repos into Gitea and repoint `DEFAULT_ACTIONS_URL` at itself, or skip `uses:` entirely and write plain `run:` steps calling `git` and `docker` directly. For a demo, plain `run:` steps are the lower-drama option and what Phase 2 should probably do.

## Phase 3 preview: where the image lives

The cluster is kind-based (Docker Desktop's multi-node provisioner — that's what `desktop-control-plane`/`desktop-worker` node names mean), so **it does not share Docker's image store**. A locally built image is not automatically visible to pods.

Ranked options:

1. **`kind load docker-image`** after the build. No TLS, no registry config, one extra workflow step. Recommended.
2. **Gitea's built-in container registry.** Cleanest conceptually, but it's HTTP, so containerd on both kind nodes needs insecure-registry configuration before pods can pull from it.
3. **Keep GHCR, pre-pull before the venue.** Zero work, but the Octopus feed still reaches out to the registry.
