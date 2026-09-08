#!/usr/bin/env node
// Records a single-tab WebM of the bg-preview demo (PR #30).
//
// Same Argo Rollouts shape as blue-green, but autoPromotionEnabled=false
// AND the promote is now gated inside Octopus: the deployment process
// has a Manual Intervention step ("Promote to active?") between
// `Deploy Manifests` and a `Promote Rollout` script step that shells
// `kubectl argo rollouts promote`. So the gate is visible in the
// Octopus task page itself.
//
// Sequence:
//   0. (off-camera) baseline: if a rollout is currently paused from a
//      prior demo, promote + wait for drain so we start clean.
//   1. kubectl 'before' — single live RS, both Services on it.
//   2. Create a fresh release on demo/bg-preview branch (the new OCL
//      isn't on prior releases). Deploy it, follow Octopus task page
//      until it lands in the manual-intervention pause.
//   3. kubectl 'paused' — preview Service targets new RS, active still
//      on the old one.
//   4. Preview hostname — new version behind the gate.
//   5. Active hostname — still old version.
//   6. Back to Octopus task page (banner: "approver clicks Proceed"),
//      submit the interruption via API. Octopus runs Promote Rollout
//      which shells `kubectl argo rollouts promote` and blocks on
//      `rollouts status` until the drain completes. Task → Success.
//   7. kubectl 'drained' — single live RS again.
//   8. Active hostname (cache-busted) — now serving new version.
//
// Requires:
//   - ffmpeg + kubectl on PATH (kubectl-argo-rollouts is installed
//     inside the Octopus K8s agent step now, not needed locally)
//   - kubectl context pointing at the lab cluster
//   - .env at repo root with OCTOPUS_API_KEY

import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import {
  REPO_ROOT,
  loadEnv, sleep, octoLogin, octoPost, octoGet,
  banner, dismissOctoChrome, waitForTaskState,
  withPinnedScroll, saveRecording, launchRecorder, verifyDeployed,
  makeTtyd, readLiveImageTag, cancelSiblingDeploys,
  resolveProject, resolveEnv, resolveTenant,
} from "./recorder-lib.mjs";

const env = loadEnv();

// ---------- demo constants ----------
const PROJECT_SLUG = "bg-preview-randomquotes";
const SPACE_ID = "Spaces-2";
const TENANT_NAME = "acme-corp";
const NS = "randomquotes-local-bg-preview-acme-corp-production";
const APP_URL = "http://local-bg-preview-acme-corp-production.localtest.me:8080/";
const PREVIEW_URL = "http://bg-local-bg-preview-acme-corp-production.localtest.me:8080/";
const ROLLOUT_NAME = "randomquotes";
const TTYD_PORT = 7683; // distinct from blue-green's port so both can run side-by-side

const log = (...a) => console.log("[record-bgp]", ...a);

// Resolved at runtime from slug/name (Octopus rotates IDs on every `make nuke`).
let PROJECT_ID;
let ENV_ID;

// Include svc so the audience can read the active Service's SELECTOR
// (rollouts-pod-template-hash=<hash>) and visually match it against the
// ReplicaSet hashes — that's where the blue-green switchover actually happens.
// Drop stale generations + Terminating pods from prior runs.
const ttyd = makeTtyd({
  port: TTYD_PORT,
  kubectlCmd:
    `(kubectl get rollout,svc -n ${NS} -o wide 2>/dev/null; ` +
    ` echo; kubectl get replicaset -n ${NS} -l app=randomquotes -o wide 2>/dev/null | awk 'NR==1 || $3>0'; ` +
    ` echo; kubectl get pods -n ${NS} -l app=randomquotes --field-selector=status.phase=Running -o wide 2>/dev/null)`,
});

// ---------- bg-preview-specific helpers (not in lib) ----------

// PUT helper — not yet in recorder-lib.mjs. Needed for the
// interruption "take responsibility" endpoint.
async function octoPut(p, body) {
  const r = await fetch(`${env.OCTO_URL}${p}`, {
    method: "PUT",
    headers: { "X-Octopus-ApiKey": env.OCTO_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`octo PUT ${p} → ${r.status}: ${await r.text()}`);
  return r.json().catch(() => ({}));
}

// SemVer-ish "is b strictly newer than a" for the lab's 1.1.N image tag
// scheme. Falls back to string compare for non-numeric prefixes.
function isNewer(a, b) {
  const parse = (v) => v.split(/[^0-9]+/).filter(Boolean).map(Number);
  const xs = parse(a), ys = parse(b);
  for (let i = 0; i < Math.max(xs.length, ys.length); i++) {
    const x = xs[i] ?? 0, y = ys[i] ?? 0;
    if (y > x) return true;
    if (y < x) return false;
  }
  return b > a; // tiebreak on full string
}

// Pick the newest existing release on the project that's strictly
// newer than `previousTag`. Returns null if nothing qualifies.
async function findNewerRelease(previousTag) {
  const releases = await octoGet(env, `/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?take=10`);
  return (releases.Items || []).find((r) => isNewer(previousTag, r.Version)) || null;
}

// Kick the CI build workflow and block until Octopus's image-detection
// trigger materialises a release with a version > `previousTag`. This
// is the lab's normal CI→trigger path; the recorder just orchestrates
// it so demo runs always have a real, trustworthy version delta.
//
// bg-preview is the ONLY recorder that dispatches CI builds (the others
// use lib's pickDeployableRelease which just picks from existing releases).
async function buildAndWaitForRelease(previousTag, timeoutMs = 8 * 60_000) {
  const txt = fs.readFileSync(path.join(REPO_ROOT, ".env"), "utf8");
  const m = txt.match(/^GITHUB_PAT=(.+)$/m);
  const PAT = m ? m[1] : null;
  if (!PAT) throw new Error("GITHUB_PAT missing from .env — needed to dispatch CI build");

  log("dispatching build.yml workflow_dispatch on main");
  const dispatch = await fetch(
    "https://api.github.com/repos/creid-octopus/octopus-iac-lab/actions/workflows/build.yml/dispatches",
    {
      method: "POST",
      headers: { Authorization: `Bearer ${PAT}`, Accept: "application/vnd.github+json" },
      body: JSON.stringify({ ref: "main" }),
    },
  );
  if (!dispatch.ok) throw new Error(`build dispatch → ${dispatch.status}: ${await dispatch.text()}`);

  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const r = await findNewerRelease(previousTag);
    if (r) {
      log(`new release ${r.Version} landed in Octopus`);
      return r;
    }
    await sleep(10_000);
  }
  throw new Error(`timed out waiting for a release newer than ${previousTag}`);
}

// Resolves the previous + next versions before the cameras roll. If no
// new release exists, kicks the CI build and waits — that can take a
// few minutes and the recorder mustn't be filming during it.
async function resolveRelease() {
  const previousVersion = readLiveImageTag(NS);
  if (!previousVersion) throw new Error("could not read current live pod image tag");
  log(`previous (live) version: ${previousVersion}`);
  let release = await findNewerRelease(previousVersion);
  if (!release) {
    log(`no release newer than ${previousVersion} — triggering build`);
    release = await buildAndWaitForRelease(previousVersion);
  }
  log(`next version: ${release.Version} (release ${release.Id})`);
  return { previousVersion, release };
}

async function submitDeploy(release, tenantId) {
  // Refresh the release's variable snapshot before deploying — old releases
  // captured their snapshot before later `tofu apply`s and may otherwise
  // fail with "No variable named 'Project.WorkerPool' was in scope".
  await octoPost(env, `/api/${SPACE_ID}/releases/${release.Id}/snapshot-variables`, {});

  const dep = await octoPost(env, `/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id,
    EnvironmentId: ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  log(`deployment ${dep.Id} → task ${dep.TaskId}`);
  const imageTag = release.SelectedPackages?.[0]?.Version || release.Version;
  return { taskId: dep.TaskId, version: imageTag };
}

// Poll the cluster until the only ReplicaSet with replicas > 0 is the
// one running `expectedTag` — i.e. the old ReplicaSets have fully
// drained post-promotion. Returns when drained OR timeoutMs elapses.
async function waitForDrain(expectedTag, timeoutMs = 120_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const raw = execSync(
        `kubectl get rs -n ${NS} ` +
        `-o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.spec.template.spec.containers[0].image}{"\\n"}{end}'`,
        { encoding: "utf8" },
      );
      const stragglers = raw.split("\n").filter((line) => {
        if (!line.trim()) return false;
        const [, replicas, image] = line.split("|");
        const tag = (image || "").split(":").pop();
        return Number(replicas) > 0 && tag !== expectedTag;
      });
      if (stragglers.length === 0) {
        log(`drain complete (only ${expectedTag} RS has replicas)`);
        return;
      }
    } catch (e) {
      log(`waitForDrain transient: ${e.message}`);
    }
    await sleep(2000);
  }
  log("waitForDrain timed out — moving on");
}

// True iff the Rollout is in the paused-for-promotion state (new RS
// healthy behind previewService, awaiting manual promote).
function isRolloutPaused() {
  try {
    const out = execSync(
      `kubectl get rollout ${ROLLOUT_NAME} -n ${NS} ` +
      `-o jsonpath='{.status.pauseConditions[*].reason}'`,
      { encoding: "utf8" },
    ).trim();
    return out.includes("BlueGreenPause");
  } catch {
    return false;
  }
}

function promoteRollout() {
  log(`promoting rollout ${ROLLOUT_NAME}`);
  execSync(`kubectl argo rollouts promote ${ROLLOUT_NAME} -n ${NS}`, { stdio: "inherit" });
}

// Block until Octopus has surfaced a pending Manual Intervention on the
// given task (typically a few seconds after Deploy Manifests completes
// and the Rollout reports paused). bg-preview-specific: the only recorder
// with a manual gate in its process.
async function waitForInterruption(taskId, timeoutMs = 300_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const r = await octoGet(env, `/api/${SPACE_ID}/interruptions?regarding=${taskId}&pendingOnly=true`);
    const item = (r.Items || [])[0];
    if (item) {
      log(`interruption ${item.Id} pending on task ${taskId}`);
      return item;
    }
    await sleep(2500);
  }
  throw new Error(`timed out waiting for interruption on task ${taskId}`);
}

async function submitInterruption(interruption, result = "Proceed", notes = "Approved via demo recorder") {
  // The interruption must be assigned to the current user before we can
  // submit a response. The take-responsibility endpoint is idempotent.
  await octoPut(`/api/${SPACE_ID}/interruptions/${interruption.Id}/responsible`, {});
  await octoPost(env, `/api/${SPACE_ID}/interruptions/${interruption.Id}/submit`, {
    Instructions: interruption.Form?.Values || null,
    Notes: notes,
    Result: result,
  });
  log(`interruption ${interruption.Id} submitted: ${result}`);
}

// The kubectl panel is plain HTML (see makeTtyd) — its layout is fully
// under our control. No post-load CSS surgery needed. We keep the
// function as a no-op shim so the scene code reads the same.
async function fitTtyd(_page) { /* nothing to fit anymore */ }

// ---------- main ----------
(async () => {
  if (!env.OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing in .env");

  const [{ id: projectId }, envId, tenantId] = await Promise.all([
    resolveProject(env, PROJECT_SLUG),
    resolveEnv(env, "Production"),
    resolveTenant(env, TENANT_NAME),
  ]);
  PROJECT_ID = projectId;
  ENV_ID = envId;
  log(`resolved: project=${PROJECT_ID} env=${ENV_ID} tenant=${tenantId}`);

  ttyd.start();
  await sleep(800);

  // ----- Pre-recording (off-camera) -----
  // Normalize: if a prior demo left the rollout paused, promote +
  // drain before we open the browser. Then resolve previous + next
  // versions (kicking the CI build if needed). All of this can take
  // several minutes; do it BEFORE creating the recording context so
  // the resulting WebM only contains the actual demo.
  if (isRolloutPaused()) {
    log("pre: rollout currently paused — promoting + waiting for drain");
    try { promoteRollout(); } catch (e) { log(`promote failed (continuing): ${e.message}`); }
    try {
      const newTag = execSync(
        `kubectl get rs -n ${NS} -o jsonpath='{range .items[*]}{.spec.replicas}{"|"}{.spec.template.spec.containers[0].image}{"\\n"}{end}'`,
        { encoding: "utf8" },
      ).split("\n")
        .filter(Boolean)
        .map((l) => l.split("|"))
        .filter(([r]) => Number(r) > 0)
        .map(([, img]) => img.split(":").pop())
        .pop() || "";
      if (newTag) await waitForDrain(newTag, 90_000);
    } catch (e) { log(`baseline drain skipped: ${e.message}`); }
  }

  const { previousVersion, release } = await resolveRelease();

  const { browser, ctx, page } = await launchRecorder({ slowMo: 200 });

  try {
    // ----- Scene 1: log into Octopus (off-screen prelude) -----
    log("scene 1: login");
    await octoLogin(page, env);

    // ----- Scene 2: kubectl 'before' -----
    log("scene 2: kubectl (before)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, `Before deploy — single live ReplicaSet running ${previousVersion}; both Services target it`);
    await sleep(12_000);

    // ----- Scene 3: submit deploy, follow Octopus task to the gate -----
    log("scene 3: submit deploy + watch task to manual-intervention pause");
    const { taskId, version } = await submitDeploy(release, tenantId);
    // The build dispatch from resolveRelease() already kicked off the
    // auto-release trigger fan-out (18 sibling Dev deploys queued).
    // Take them out so our task isn't stuck behind them.
    await cancelSiblingDeploys(env, taskId);
    const taskUrl = `${env.OCTO_URL}/app#/${SPACE_ID}/tasks/${taskId}`;
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, `Deploy triggered — ${PROJECT_SLUG} release ${version} → Production / ${TENANT_NAME}`);
    const interruption = await withPinnedScroll(page, () => waitForInterruption(taskId));
    // Refresh so the audience sees the "Awaiting Manual Intervention"
    // banner Octopus surfaces on the task page once a Manual step pauses.
    await page.reload({ waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Manual Intervention — Octopus is paused at the gate, awaiting approval");
    await sleep(10_000);

    // ----- Scene 4: kubectl 'paused' — new RS staged behind preview -----
    log("scene 4: kubectl (paused state)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, "Paused — preview Service now targets the new ReplicaSet; active still on the old one");
    await sleep(15_000);

    // ----- Scene 5: preview hostname (new version) -----
    log("scene 5: preview app (new version)");
    await page.goto(PREVIEW_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Preview hostname — bg-* serves the new version (${version}) behind the gate`);
    await sleep(8_000);

    // ----- Scene 6: active hostname (still old) -----
    log("scene 6: active app (still old)");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, "Active hostname — still on the previous version; no traffic flipped yet");
    await sleep(8_000);

    // ----- Scene 7: approve in Octopus by actually clicking Proceed -----
    // Take responsibility via API first (otherwise the buttons aren't
    // active for the current user), then drive the click in the
    // browser so the audience sees the button get hit. Fall back to
    // API submit if no candidate button matches (selectors can shift
    // between Octopus versions).
    log("scene 7: approve gate via UI click + wait for task success");
    await octoPut(`/api/${SPACE_ID}/interruptions/${interruption.Id}/responsible`, {});
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Reviewer clicks Proceed — Octopus runs the Promote Rollout step");
    await sleep(3_000);

    // Octopus sometimes renders a "Take Responsibility" button first even
    // when the API responsible-assignment succeeded; click it so the
    // Proceed button becomes active before we go for it.
    for (const sel of [
      'button:has-text("Take responsibility")',
      'button:has-text("Take Responsibility")',
    ]) {
      const b = page.locator(sel).first();
      if (await b.isVisible().catch(() => false)) {
        log(`pre-click ${sel}`);
        await b.click().catch(() => {});
        await sleep(1500);
        break;
      }
    }

    let clicked = false;
    for (const sel of [
      'button:has-text("Proceed")',
      'button:has-text("Submit Response")',
      '[data-testid="proceed-button"]',
      'button[name="proceed"]',
    ]) {
      const btn = page.locator(sel).first();
      if (await btn.isVisible().catch(() => false)) {
        log(`clicking ${sel}`);
        await btn.click().catch(() => {});
        clicked = true;
        break;
      }
    }
    if (!clicked) {
      log("no Proceed button matched — falling back to API submit");
      await submitInterruption(interruption, "Proceed");
    }
    await withPinnedScroll(page, () => waitForTaskState(env, taskId, ["Success", "Failed"]));
    await banner(page, "Task green — promote + drain completed inside the Promote Rollout step");
    await verifyDeployed(NS, release.SelectedPackages?.[0]?.Version || release.Version);
    await sleep(4_000);

    // ----- Scene 8: kubectl after drain -----
    log("scene 8: kubectl (drained)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, `Single live ReplicaSet again — ${version} is serving on both Services`);
    await sleep(8_000);

    // ----- Scene 9: active hostname (now new version) -----
    // Cache-bust query string + reload — without this Chromium serves
    // the cached page from scene 6 (still-old version).
    log("scene 9: active app (now new)");
    await page.goto(`${APP_URL}?v=${version}`, { waitUntil: "domcontentloaded" });
    await page.reload({ waitUntil: "domcontentloaded" });
    await banner(page, `Active hostname — now serving release ${version}`);
    await sleep(10_000);

    log("done");
  } finally {
    await saveRecording(page, "bg-preview");
    await ctx.close();
    await browser.close();
    ttyd.stop();
  }
})().catch((err) => {
  console.error("[record-bgp] ERROR:", err.message);
  process.exit(1);
});
