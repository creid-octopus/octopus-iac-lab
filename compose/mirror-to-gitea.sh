#!/usr/bin/env bash
#
# Reconcile the local Gitea from an upstream remote (github.com by default).
#
#   ./compose/mirror-to-gitea.sh            # mirror the default refs
#   ./compose/mirror-to-gitea.sh main demo/canary
#
# This is the "pull relevant changes into gitea" step of the intended
# workflow: test in Octopus Cloud → land it on the hosted GitHub repo →
# mirror into Gitea → the local lab runs the same content.
#
# Deliberately NOT the same thing as `make gitea-push`:
#
#   gitea-push    your local working commit  → Gitea   (dev loop)
#   gitea-mirror  upstream's refs            → Gitea   (sync loop)
#
# Mirroring reads UPSTREAM refs (refs/remotes/<upstream>/<ref>), not your
# working tree, so a half-finished local branch can't leak into the lab.
# It's also the only step here that needs internet, by design — everything
# else the lab does runs against Gitea.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

UPSTREAM="${GITEA_MIRROR_UPSTREAM:-origin}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_REPO="${GITEA_REPO:-octopus-iac-lab}"
GITEA_TOKEN="${GITEA_TOKEN:-}"

# Refs to mirror: CLI args win, then GITEA_MIRROR_REFS from .env, then main.
if [ "$#" -gt 0 ]; then
  REFS=("$@")
else
  # shellcheck disable=SC2206
  REFS=(${GITEA_MIRROR_REFS:-main})
fi

step() { printf '\n=== %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${GITEA_TOKEN}" ] || fail "GITEA_TOKEN is empty — run 'make gitea-bootstrap' first."

GITEA_PUSH_URL="http://${GITEA_ADMIN_USER}:${GITEA_TOKEN}@localhost:3000/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"

step "Fetching from ${UPSTREAM}"
git remote get-url "${UPSTREAM}" >/dev/null 2>&1 \
  || fail "no remote named '${UPSTREAM}'. Set GITEA_MIRROR_UPSTREAM to the right one."
if ! git fetch --prune "${UPSTREAM}" 2>&1 | sed 's/^/    /'; then
  fail "fetch from ${UPSTREAM} failed. This step needs internet — it's the only one that does.
    If you're offline, skip mirroring; Gitea already holds whatever you last synced."
fi
info "fetched $(git remote get-url "${UPSTREAM}")"

step "Mirroring ${#REFS[@]} ref(s) into Gitea"
for ref in "${REFS[@]}"; do
  src="refs/remotes/${UPSTREAM}/${ref}"
  if ! git rev-parse --verify --quiet "${src}" >/dev/null; then
    info "SKIP ${ref} — no such branch on ${UPSTREAM}"
    continue
  fi
  sha="$(git rev-parse --short "${src}")"
  # --force: Gitea is a mirror, so upstream always wins. Anything committed
  # straight into Gitea that isn't upstream is expected to be discarded —
  # that's what makes the direction unambiguous.
  git push --force "${GITEA_PUSH_URL}" "${src}:refs/heads/${ref}" 2>&1 | sed 's/^/    /'
  info "${ref} -> ${sha}"
done

cat <<EOF

=== Mirrored

Gitea now matches ${UPSTREAM} for: ${REFS[*]}

If Octopus CaC or Argo CD should pick this up right now:
  make cp-apply app-apply     # re-read CaC from the new commit
  # Argo CD polls on its own; force it with a Refresh in the UI if impatient
EOF
