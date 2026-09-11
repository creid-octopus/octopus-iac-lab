# GitHub PAT exposed to the argocd namespace so Argo's ApplicationSet
# SCM Provider generator can reach the GitHub API at the higher
# (5000 req/hr) authenticated rate limit instead of 60 req/hr anonymous.
# Public-repo lookups work without auth, but the cap bites quickly with
# multiple branches + a 30s requeue interval.
#
# Only created when this worktree owns the argocd install — the secret
# only needs to exist once per cluster, and the local worktree is the
# canonical owner of cluster-scoped argocd resources by convention.
resource "kubernetes_secret_v1" "argocd_github_pat" {
  count = local.install_argocd_final ? 1 : 0

  metadata {
    name      = "github-pat"
    namespace = local.argocd_namespace_name
  }

  data = {
    # NOT var.github_pat — that one gets swapped to the Gitea token in
    # offline mode, and this secret authenticates against api.github.com.
    token = var.applicationset_github_pat
  }
}
