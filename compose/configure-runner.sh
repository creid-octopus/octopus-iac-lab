#!/usr/bin/env bash
#
# Register a Gitea Actions runner and bring it up.
#
# Safe to re-run: registration tokens are single-use, so this fetches a fresh
# one each time and recreates the container. That's also the recovery path if
# the runner ever shows offline in Gitea.
#
# Run via `make runner-up`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-Admin123!}"
JOB_IMAGE="octopus-iac-lab/runner:local"

step() { printf '\n=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required (brew install jq)"

# --- 1. job image -----------------------------------------------------------
#
# Must exist before any workflow runs: the runner config sets force_pull
# false and the tag is local-only, so a missing image fails the job with a
# confusing "image not found" rather than pulling something.

step "Job container image"
if docker image inspect "${JOB_IMAGE}" >/dev/null 2>&1; then
  info "${JOB_IMAGE} already built (rebuild with 'make runner-image')"
else
  info "building ${JOB_IMAGE} — needs network once, for the docker:cli base"
  docker build -t "${JOB_IMAGE}" compose/runner-image | sed 's/^/    /'
fi

# --- 2. gitea reachable -----------------------------------------------------

step "Checking Gitea"
curl -fsS -o /dev/null "${GITEA_URL}/api/healthz" 2>/dev/null \
  || fail "Gitea isn't answering at ${GITEA_URL}. Run 'make gitea-up' first."
info "up"

# --- 3. registration token --------------------------------------------------
#
# Single-use and short-lived, hence fetched fresh on every run rather than
# stored in .env.

step "Fetching a runner registration token"
TOKEN=""
for i in $(seq 1 10); do
  TOKEN="$(curl -fsS -X POST \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    "${GITEA_URL}/api/v1/admin/actions/runners/registration-token" \
    2>/dev/null | jq -r '.token // empty')"
  [ -n "${TOKEN}" ] && break
  info "attempt ${i}/10 …"
  sleep 3
done
[ -n "${TOKEN}" ] || fail "couldn't get a registration token. Is Actions enabled? Check GITEA__actions__ENABLED in compose/gitea.yaml."
info "got one"

# --- 4. (re)start the runner ------------------------------------------------
#
# Recreated rather than restarted: the token is baked in at registration
# time, and a stale .runner file would make it ignore the new one.

step "Starting the runner"
docker compose --env-file .env -f compose/act-runner.yaml down 2>/dev/null | sed 's/^/    /' || true
GITEA_RUNNER_REGISTRATION_TOKEN="${TOKEN}" \
  docker compose --env-file .env -f compose/act-runner.yaml up -d 2>&1 | sed 's/^/    /'

# --- 5. verify it actually registered --------------------------------------
#
# "Container running" is not the same as "registered" — a bad token shows up
# only in the logs, so check Gitea's own view.

step "Verifying registration"
REGISTERED=""
for i in $(seq 1 15); do
  COUNT="$(curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    "${GITEA_URL}/api/v1/admin/actions/runners" 2>/dev/null | jq -r '.total_count // 0')"
  if [ "${COUNT:-0}" -gt 0 ]; then REGISTERED="yes"; break; fi
  info "attempt ${i}/15 …"
  sleep 2
done

if [ -z "${REGISTERED}" ]; then
  printf '\n'
  docker logs gitea-runner 2>&1 | tail -20 | sed 's/^/    /'
  fail "runner didn't register. Logs above."
fi

cat <<EOF

=== Runner registered

  Runners      ${GITEA_URL}/-/admin/actions/runners
  Job image    ${JOB_IMAGE}  (local only, never pulled)
  Workflows    .gitea/workflows/

Trigger a build:
  Gitea UI -> admin/octopus-iac-lab -> Actions -> "CI / Build Image" -> Run workflow
  (or push a change under app/ and 'make gitea-push')

Verification steps: docs/local-gitea.md ("Phase 2: Actions")
EOF
