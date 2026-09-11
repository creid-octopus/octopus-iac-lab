# Job container image for Gitea Actions.
#
# Built locally, never pulled. The instruqt tracks point their runner at
# docker.gitea.com/runner-images:ubuntu-latest, which is multi-GB and set to
# force_pull on every run — fine on a provisioned VM with bandwidth, useless
# at a conference. This is ~100MB and covers everything the build workflow
# actually needs:
#
#   docker CLI  build the app image, and load it into the kind nodes via the
#               mounted host socket (no dockerd in here — it talks to the host)
#   git         clone the repo from Gitea (replaces actions/checkout)
#   curl + jq   talk to the Octopus and Gitea APIs
#   bash        the workflow's shell
#
# Rebuild with `make runner-image`. Tagged locally, and the runner config
# sets force_pull: false so it's never looked up in a registry.
FROM docker:cli

RUN apk add --no-cache bash git curl jq coreutils

# Gitea Actions shells out to `node` for some internal plumbing even when a
# workflow uses only `run:` steps. Without it, jobs fail with an obscure
# "exec: node: not found" before the first step runs.
RUN apk add --no-cache nodejs

SHELL ["/bin/bash", "-c"]
