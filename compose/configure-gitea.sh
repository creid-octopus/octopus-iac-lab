#!/usr/bin/env bash
#
# Bootstrap the local Gitea instance into something Octopus and Argo CD can
# use as a drop-in replacement for github.com.
#
# Safe to re-run. Every step checks current state first, so this is the
# recovery path after a `make gitea-nuke` as well as the first-time setup.
#
# What it does:
#   1. Waits for Gitea's API to answer (the container is up well before the
#      API is, so this is a real wait, not a courtesy sleep).
#   2. Creates the admin user if it doesn't exist.
#   3. Mints an API token and writes it to .env as GITEA_TOKEN.
#   4. Creates the octopus-iac-lab repo if it doesn't exist.
#   5. Pushes this working tree's current commit to it as `main`.
#
# Run it via `make gitea-bootstrap`, which loads .env first.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GITEA_URL="${GITEA_URL:-http://localhost:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-Admin123!}"
GITEA_REPO="${GITEA_REPO:-octopus-iac-lab}"
GITEA_CONTAINER="${GITEA_CONTAINER:-gitea}"
TOKEN_NAME="octopus-iac-lab-bootstrap"

step() { printf '\n=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required (brew install jq)"

# --- 1. wait for the API ----------------------------------------------------

step "Waiting for Gitea at ${GITEA_URL}"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "${GITEA_URL}/api/healthz" 2>/dev/null; then
    info "ready after ${i} attempt(s)"
    break
  fi
  [ "$i" = 60 ] && fail "Gitea never became ready. Check: docker logs ${GITEA_CONTAINER}"
  sleep 2
done

# --- 2. admin user ----------------------------------------------------------

step "Admin user '${GITEA_ADMIN_USER}'"
# `-u git`: Gitea's CLI hard-refuses to run as root ("Gitea is not supposed to
# be run as root"), and docker exec defaults to root. The instruqt tracks do
# this with `su git -c "..."`; -u avoids the nested quoting.
if docker exec -u git "${GITEA_CONTAINER}" gitea admin user list --config /data/gitea/conf/app.ini 2>/dev/null \
     | awk '{print $2}' | grep -qx "${GITEA_ADMIN_USER}"; then
  info "already exists, leaving it alone"
else
  docker exec -u git "${GITEA_CONTAINER}" gitea admin user create \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASSWORD}" \
    --email "${GITEA_ADMIN_USER}@octopus.local" \
    --admin --must-change-password=false \
    --config /data/gitea/conf/app.ini
  info "created"
fi

# --- 3. API token -----------------------------------------------------------
#
# Gitea rejects a second token with the same name, so delete-then-create keeps
# this idempotent. The token is only needed for API calls and the git push;
# Octopus itself authenticates with plain username/password (Gitea accepts
# that over HTTP git without 2FA), so there's no token to rotate in Octopus.

step "API token '${TOKEN_NAME}'"
curl -fsS -o /dev/null -X DELETE \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
  "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}/tokens/${TOKEN_NAME}" 2>/dev/null \
  && info "removed previous token of the same name" || true

GITEA_TOKEN="$(curl -fsS -X POST \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${TOKEN_NAME}\",\"scopes\":[\"write:repository\",\"write:user\",\"write:organization\",\"write:package\",\"write:admin\",\"write:misc\"]}" \
  "${GITEA_URL}/api/v1/users/${GITEA_ADMIN_USER}/tokens" | jq -r '.sha1')"

[ -n "${GITEA_TOKEN}" ] && [ "${GITEA_TOKEN}" != "null" ] || fail "could not mint a token"
info "minted"

# Persist to .env so Phase 2 (Actions secrets) and any manual curl can reuse
# it. Same sed-in-place pattern as `make mint-api-key` (BSD sed needs the '').
if grep -q '^GITEA_TOKEN=' "${REPO_ROOT}/.env" 2>/dev/null; then
  sed -i '' "s|^GITEA_TOKEN=.*|GITEA_TOKEN=${GITEA_TOKEN}|" "${REPO_ROOT}/.env"
else
  echo "GITEA_TOKEN=${GITEA_TOKEN}" >> "${REPO_ROOT}/.env"
fi
info "written to .env as GITEA_TOKEN"

# --- 3b. Actions secrets ----------------------------------------------------
#
# User-level, so every repo under this account sees them. The build workflow
# uses these to clone from Gitea instead of actions/checkout.
#
# Gitea secret names must be uppercase alphanumeric plus underscore, and
# the GITEA_ prefix is RESERVED (same as GITHUB_ on github). Naming these
# GITEA_TOKEN / GITEA_USERNAME got them silently rejected. Hence LAB_*.
# These names are what .gitea/workflows/build.yml expects — keep in sync.

step "Actions secrets"
for pair in "LAB_GIT_TOKEN:${GITEA_TOKEN}" "LAB_GIT_USERNAME:${GITEA_ADMIN_USER}"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if curl -fsS -o /dev/null -X PUT \
       -H "Authorization: token ${GITEA_TOKEN}" \
       -H "Content-Type: application/json" \
       -d "{\"data\":\"${value}\"}" \
       "${GITEA_URL}/api/v1/user/actions/secrets/${name}" 2>/dev/null; then
    info "${name} set"
  else
    info "WARNING: couldn't set ${name} — Actions workflows will fail to clone"
  fi
done

# Registry namespace: images push under the admin user (admin/octopus-iac-lab)
# rather than a dedicated org matching the GHCR path. An earlier version
# created a `creid-octopus` org so package_id could be identical on both
# registries; dropped as unnecessary complexity. The consequence is that
# .octopus/deployment_process.ocl's package_id differs per backend, which
# set-git-backend.sh handles alongside the other rewrites.

# --- 4. repository ----------------------------------------------------------

step "Repository ${GITEA_ADMIN_USER}/${GITEA_REPO}"
if curl -fsS -o /dev/null \
     -H "Authorization: token ${GITEA_TOKEN}" \
     "${GITEA_URL}/api/v1/repos/${GITEA_ADMIN_USER}/${GITEA_REPO}" 2>/dev/null; then
  info "already exists"
else
  # Endpoint is /user/repos (create for the authenticated user), NOT /repos —
  # the latter doesn't exist and 404s.
  #
  # auto_init=false: this repo gets its history from the push below, and an
  # auto-created initial commit would just be a conflicting root commit.
  CREATE_BODY="$(curl -sS -w '\n%{http_code}' -X POST \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${GITEA_REPO}\",\"description\":\"Offline mirror of octopus-iac-lab for local CaC + GitOps\",\"auto_init\":false,\"private\":false,\"default_branch\":\"main\"}" \
    "${GITEA_URL}/api/v1/user/repos")"
  CREATE_CODE="$(printf '%s' "${CREATE_BODY}" | tail -n1)"
  if [ "${CREATE_CODE}" != "201" ]; then
    fail "repo create returned HTTP ${CREATE_CODE}:
$(printf '%s' "${CREATE_BODY}" | sed '$d')"
  fi
  info "created"
fi

# --- 5. push this working tree ---------------------------------------------
#
# Pushes the CURRENT commit, not github's main. That's deliberate: the point
# of the offline setup is that what you have locally is what the lab runs.
# Commit before running this if you want uncommitted work included.

step "Pushing $(git -C "${REPO_ROOT}" rev-parse --short HEAD) to gitea/main"
PUSH_URL="http://${GITEA_ADMIN_USER}:${GITEA_TOKEN}@localhost:3000/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"

if git -C "${REPO_ROOT}" push "${PUSH_URL}" "HEAD:refs/heads/main" 2>&1 | sed 's/^/    /'; then
  info "pushed"
else
  fail "push failed. If Gitea's main has diverged from local, re-run with:
    git push --force ${PUSH_URL//${GITEA_TOKEN}/\$GITEA_TOKEN} HEAD:refs/heads/main"
fi

# Register a named remote so day-to-day pushes are just `git push gitea main`.
# Uses the token-free URL — git will prompt, or you can rely on the Makefile
# target. Keeps the token out of .git/config.
if git -C "${REPO_ROOT}" remote get-url gitea >/dev/null 2>&1; then
  git -C "${REPO_ROOT}" remote set-url gitea "http://localhost:3000/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"
else
  git -C "${REPO_ROOT}" remote add gitea "http://localhost:3000/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"
fi

cat <<EOF

=== Done

  Web UI      ${GITEA_URL}    (${GITEA_ADMIN_USER} / ${GITEA_ADMIN_PASSWORD})
  Repo        ${GITEA_URL}/${GITEA_ADMIN_USER}/${GITEA_REPO}
  Push again  make gitea-push

  URLs to use when you flip Octopus + Argo CD over (Phase 1b):
    http://host.docker.internal:3000/${GITEA_ADMIN_USER}/${GITEA_REPO}.git

  Verification steps: docs/local-gitea.md
EOF
