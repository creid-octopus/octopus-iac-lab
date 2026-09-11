# ArgoCD itself — shared cluster infra. Owned by exactly ONE worktree at a
# time (default: the local self-host worktree; SaaS piggybacks). The other
# worktree sets `install_argocd = false` and references the same namespace
# via the `argocd_namespace_name` local.
#
# Two lab-specific tweaks to the upstream chart:
#   1. `octopus` account configured with apiKey-only capability — that's
#      what each Gateway authenticates as.
#   2. RBAC policy granting `octopus` the minimum permissions the Gateways
#      need (per https://octopus.com/docs/argo-cd/instances/terraform-bootstrap).

resource "kubernetes_namespace_v1" "argocd" {
  count = local.install_argocd_final ? 1 : 0

  metadata {
    name = var.argocd_namespace
  }
}

resource "helm_release" "argocd" {
  count = local.install_argocd_final ? 1 : 0

  name             = "argocd"
  namespace        = kubernetes_namespace_v1.argocd[0].metadata[0].name
  create_namespace = false

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  atomic = true
  wait   = true

  # `values` (yamlencode) instead of `set` blocks: helm's --set parser
  # treats commas as field separators, which mangles RBAC policy CSVs.
  # yamlencode hands the chart a clean YAML doc and avoids the escaping mess.
  values = [
    yamlencode({
      configs = {
        # Static admin password — the chart writes the bcrypt hash into
        # the argocd-secret. Avoids the argocd-initial-admin-secret
        # bootstrap dance and means the password is stable across reinstalls.
        secret = {
          argocdServerAdminPassword      = var.argocd_password_bcrypt
          argocdServerAdminPasswordMtime = "2026-05-21T00:00:00Z"
        }
        cm = {
          # One account per Gateway so each is RBAC-scoped to its own
          # AppProject — the local Gateway must not surface saas Applications
          # into local Octopus, and vice versa. apiKey capability is enough;
          # the Gateway only consumes JWTs, never logs in interactively.
          "accounts.octopus-local" = "apiKey"
          "accounts.octopus-saas"  = "apiKey"
        }
        rbac = {
          # Per https://octopus.com/docs/argo-cd/instances/terraform-bootstrap,
          # but application verbs are scoped to the matching project (`local/*`
          # / `saas/*`) so each Gateway only sees its own leaves. clusters,
          # repositories and projects gets stay unscoped — scoping those makes
          # the Gateway fail to list anything.
          "policy.csv" = trimspace(<<-EOT
            p, role:octopus-local, applications, get, local/*, allow
            p, role:octopus-local, applications, sync, local/*, allow
            p, role:octopus-local, applications, action/*, local/*, allow
            p, role:octopus-local, applications, override, local/*, allow
            p, role:octopus-local, applications, update, local/*, allow
            p, role:octopus-local, applications, create, local/*, allow
            p, role:octopus-local, applications, delete, local/*, allow
            p, role:octopus-local, clusters, get, *, allow
            p, role:octopus-local, repositories, get, *, allow
            p, role:octopus-local, projects, get, *, allow
            p, role:octopus-local, logs, get, local/*, allow
            g, octopus-local, role:octopus-local
            p, role:octopus-saas, applications, get, saas/*, allow
            p, role:octopus-saas, applications, sync, saas/*, allow
            p, role:octopus-saas, applications, action/*, saas/*, allow
            p, role:octopus-saas, applications, override, saas/*, allow
            p, role:octopus-saas, applications, update, saas/*, allow
            p, role:octopus-saas, applications, create, saas/*, allow
            p, role:octopus-saas, applications, delete, saas/*, allow
            p, role:octopus-saas, clusters, get, *, allow
            p, role:octopus-saas, repositories, get, *, allow
            p, role:octopus-saas, projects, get, *, allow
            p, role:octopus-saas, logs, get, saas/*, allow
            g, octopus-saas, role:octopus-saas
          EOT
          )
        }
        params = {
          # argocd-server runs HTTP-only — nginx-ingress terminates TLS
          # in front. Lab-friendly; for anything serious, terminate at
          # argocd-server with a real cert.
          "server.insecure" = true
        }
      }
    })
  ]
}

# Bootstrap Application — points at `gitops/argocd/`, which holds the
# per-Octopus App-of-Apps roots and the argocd-server Ingress.
#
# Applied via `kubectl apply` (null_resource + local-exec), not
# `kubernetes_manifest`. The `kubernetes_manifest` resource validates a
# manifest's GVK against the cluster's API discovery at plan/apply time —
# on a truly fresh cluster the Application/AppProject CRDs (installed by
# this same helm_release, in this same run) aren't visible yet, so it
# fails with "no matches for kind X in group argoproj.io" even with a
# correct depends_on. kubectl re-discovers the API fresh on every
# invocation, so it doesn't hit this timing problem. Matches the pattern
# already used for nginx-ingress/NFS CSI/Sealed Secrets in tofu/k8s-agent,
# and the working reference in iac-octopus/argocd/terraform.
resource "null_resource" "argocd_bootstrap" {
  count = local.install_argocd_final ? 1 : 0

  triggers = {
    argocd_release_id = helm_release.argocd[0].id
    kube_context      = var.kube_context
    namespace         = var.argocd_namespace
    repo_url          = var.gitops_repo_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      cat <<'YAML' | kubectl --context "${var.kube_context}" apply -f -
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: argocd-bootstrap
        namespace: ${var.argocd_namespace}
        labels:
          lab.octopus.com/role: argocd-bootstrap
        annotations:
          argocd.argoproj.io/sync-options: Prune=false
      spec:
        project: default
        source:
          repoURL: ${var.gitops_repo_url}
          path: gitops/argocd
          targetRevision: HEAD
        destination:
          server: https://kubernetes.default.svc
          namespace: ${var.argocd_namespace}
        syncPolicy:
          automated:
            prune: true
            selfHeal: true
          syncOptions:
            - ApplyOutOfSyncOnly=true
      YAML
    EOT
  }

  depends_on = [helm_release.argocd]
}

# AppProjects exist purely as the RBAC boundary the scoped Gateway accounts
# key off — they're as permissive as `default` on what they can deploy. Leaves
# move into `local` / `saas` (spec.project) in gitops; each Gateway's account
# can only `get` Applications in its own project, so the local Octopus stops
# surfacing saas leaves and vice versa.
#
# Same kubectl-apply reasoning as argocd_bootstrap above.
resource "null_resource" "appproject" {
  for_each = local.install_argocd_final ? toset(["local", "saas"]) : toset([])

  triggers = {
    argocd_release_id = helm_release.argocd[0].id
    kube_context      = var.kube_context
    namespace         = var.argocd_namespace
    project           = each.key
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      cat <<'YAML' | kubectl --context "${var.kube_context}" apply -f -
      apiVersion: argoproj.io/v1alpha1
      kind: AppProject
      metadata:
        name: ${each.key}
        namespace: ${var.argocd_namespace}
      spec:
        sourceRepos:
          - "*"
        destinations:
          - server: "*"
            namespace: "*"
        clusterResourceWhitelist:
          - group: "*"
            kind: "*"
        namespaceResourceWhitelist:
          - group: "*"
            kind: "*"
      YAML
    EOT
  }

  depends_on = [helm_release.argocd]
}

