# GitHub Container Registry feed. Octopus uses this to resolve image
# references at deploy time — for example, `ghcr.io/<owner>/<repo>` in the
# templated K8s manifest. Authenticated with the same PAT we use for CaC,
# scoped to `repo` + `read:packages`.
# The URI is a variable so offline mode can point the SAME feed at the local
# Gitea registry rather than adding a second one. That matters because the
# OCL references the feed by slug, and the slug derives from the name below.
#
# Keeping the image path identical across both backends is what makes this a
# pure config swap with no OCL edits: the Gitea bootstrap creates an org
# named `creid-octopus`, so `creid-octopus/octopus-iac-lab` resolves on
# either registry. Gitea's registry namespace is per user/org and
# independent of repo names, which is what allows that.
resource "octopusdeploy_docker_container_registry" "ghcr" {
  # Slug auto-derives to "ghcr" from this name. The OCL deployment process
  # references it as `feed = "ghcr"`. Renaming would silently break that —
  # which is also why the name stays "GHCR" even when pointed at Gitea.
  # Misleading, but a silently broken deployment process is worse.
  name        = "GHCR"
  feed_uri    = var.container_registry_url
  username    = var.github_username
  password    = var.github_pat
  api_version = "v2"
}
