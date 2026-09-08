# Demo capture

`capture.js` re-runs the screenshot proofs (and optional WebM recordings) shown in each demo PR's body. Output goes to `demos/out/` (gitignored).

## Setup (one-time)

```bash
npm i playwright
npx playwright install chromium
```

## Run

```bash
# Screenshots — every demo
node demos/capture.js

# Just one
node demos/capture.js main                  # canonical randomquotes
node demos/capture.js platform-hub          # PR #46 (demo/platform-hub-opa)
node demos/capture.js blue-green            # PR #59 (Octopus-native)
node demos/capture.js bg-preview            # PR #30
node demos/capture.js canary                # PR #58
node demos/capture.js process-template      # PR #92
node demos/capture.js smoke-step-template   # PR #103
node demos/capture.js servicenow-cr-gate    # PR #53 (light shots)
node demos/capture.js argo-ephemeral        # PR #25
node demos/capture.js argo-sealed-secrets   # PR #26
node demos/capture.js apps                  # all live-app URLs

# WebM recording — same scenarios, one .webm per demo in demos/out/
node demos/capture.js --record              # all
node demos/capture.js canary --record       # just one
```

`--record` wraps each demo's context with `recordVideo`: same scenario, produces a WebM alongside the PNGs. Convert to MP4 if needed: `ffmpeg -i demos/out/<slug>.webm -c:v libx264 -preset slow -crf 22 demos/out/<slug>.mp4`.

## Narrated recordings (`record-*.mjs`)

When `--record` on a screenshot scenario isn't enough — banner overlays, a live `kubectl` panel that updates during the recording, mid-flow deploy triggers — use the per-demo scripts under `demos/record-*.mjs`. Each file is a scene-driven scenario with explicit timing:

```bash
node demos/record-main.mjs              # canonical randomquotes — worker-pool story (PR #105)
node demos/record-blue-green.mjs        # PR #59 (Octopus-native)
node demos/record-bg-preview.mjs        # PR #30
node demos/record-canary.mjs            # PR #58
node demos/record-platform-hub-opa.mjs  # PR #46
node demos/record-snow.mjs              # PR #53
```

Shared helpers — env loading, Octopus REST client, banner-overlay injector, kubectl-panel HTTP server, `watchDeployment` (task page + auto-scroll), `saveRecording` (page → `<slug>.mp4`) — live in [`recorder-lib.mjs`](recorder-lib.mjs). Each per-demo file is constants + scene script + minor demo-specific helpers. All recorders output `demos/out/<slug>.mp4` (uniform format, QuickTime/browser/GitHub-embed friendly).

**Prereq:** recorders never create Octopus releases — `.github/workflows/build.yml` is the only producer of releases (one per push to main). The recorders redeploy the latest existing release. If a project has fewer than two releases, `requireReleases` fails fast with a pointer to push or run the workflow. To make a demo feel live, change a file under [`app/`](../app/) or [`gitops/charts/randomquotes/`](../gitops/charts/randomquotes/), commit, push to main, and wait ~3 min for build.yml to produce a new release.

The `demo/servicenow-cr-gate` flow has full orchestration in [`capture-snow.mjs`](capture-snow.mjs) (deploy → CR creation → mid-flow PDI approval → resume); light shots are in `capture.js`'s case above.

## Env

| Var | Default |
|---|---|
| `OCTO_URL` | `http://localhost:8090` |
| `OCTO_USER` / `OCTO_PASS` | `admin` / `Password01!` (from `compose/docker-compose.yml`) |
| `ARGOCD_URL` | `http://argocd.localtest.me:8080` |
| `ARGOCD_USER` / `ARGOCD_PASS` | `admin` / `Password01!` (static lab password, set by `tofu/argocd/`; override via `TF_VAR_argocd_password`) |

The published PNG/WebM set (referenced from each PR body) lives on the [`demo-screenshots`](https://github.com/creid-octopus/octopus-iac-lab/releases/tag/demo-screenshots) release.
