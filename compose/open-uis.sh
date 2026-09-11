#!/usr/bin/env bash
#
# Open the lab's three web UIs in your default browser.
#
#   ./compose/open-uis.sh          # or: make open
#
# Checks each one first so you don't end up with three tabs, two of which
# are connection errors. Anything that isn't up gets a one-line reason
# instead of a dead tab.

set -uo pipefail

OCTOPUS_UI="${OCTOPUS_UI:-http://localhost:8090}"
ARGOCD_UI="${ARGOCD_UI:-http://argocd.localtest.me:8080}"
GITEA_UI="${GITEA_UI:-http://localhost:3000}"

# Any HTTP response at all means something is listening. Argo CD and Octopus
# both answer redirects or 401s at the root depending on auth state, so don't
# require a 200.
reachable() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null)" != "000" ]; }

open_if_up() {
  local name="$1" url="$2" hint="$3"
  if reachable "$url"; then
    printf '  %-8s %s\n' "$name" "$url"
    open "$url"
  else
    printf '  %-8s DOWN — %s\n' "$name" "$hint"
  fi
}

echo "Opening lab UIs:"
open_if_up "Octopus" "$OCTOPUS_UI" "run 'make up'  (login: admin / Password01!)"
open_if_up "Argo CD" "$ARGOCD_UI"  "needs the ingress port-forward: kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx  (login: admin / Password01!)"
open_if_up "Gitea"   "$GITEA_UI"   "run 'make gitea-up'  (login: admin / Admin123!)"
