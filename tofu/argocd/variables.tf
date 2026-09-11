variable "octopus_url" {
  description = "Octopus Server URL (HTTP API), as seen from the host where tofu runs. Used by the octopusdeploy provider. Self-host: http://localhost:8090; SaaS: https://<id>.octopus.app."
  type        = string
}

variable "octopus_url_from_cluster" {
  description = "Octopus Server URL as seen from inside the K8s cluster — the registration pod uses this. Defaults match Docker Desktop K8s: localhost on the host = host.docker.internal in the pod. SaaS: same as octopus_url (public URL is reachable from the cluster too)."
  type        = string
  default     = "http://host.docker.internal:8090"
}

variable "octopus_api_key" {
  description = "Octopus API key. Used both by the provider and by the Gateway's registration init job."
  type        = string
  sensitive   = true
}

variable "github_pat" {
  description = "GitHub PAT — materialised into a k8s Secret (`github-pat`) in the argocd namespace so Argo's ApplicationSet SCM Provider generator can talk to GitHub above the 60 req/hr unauthenticated rate limit."
  type        = string
  sensitive   = true
}

variable "octopus_grpc_url" {
  description = "Optional override for the Octopus gRPC URL the Gateway dials. By default derived from octopus_url: SaaS hits <id>.octopus.app:443 (TLS over public cert), self-host hits host.docker.internal:8443. Self-host's :8443 is TLS with a self-signed cert; the Gateway will reject it unless `gateway.serverCertificateSecretName` is wired in. SaaS works out of the box."
  type        = string
  default     = null
}

variable "octopus_grpc_plaintext" {
  description = "If true, the Gateway skips TLS on the Octopus gRPC connection. Useful if you have a separate plaintext-tunnel terminating proxy. Default false."
  type        = bool
  default     = false
}

variable "applicationset_github_pat" {
  type        = string
  sensitive   = true
  description = <<-EOT
    GitHub PAT for the ApplicationSet pull-request generator, which talks to
    api.github.com regardless of which git backend the lab reads from.

    Deliberately separate from var.github_pat: in Gitea mode the Makefile
    swaps github_pat for the Gitea token, and feeding that to this secret
    would hand GitHub a credential it rejects. Always sourced from
    GITHUB_PAT in .env. Empty is fine — the generator falls back to
    unauthenticated calls and just hits rate limits sooner.
  EOT
  default     = ""
}

variable "gitops_repo_url" {
  type        = string
  description = <<-EOT
    Repo the bootstrap Application syncs gitops/argocd/ from.

    Defaults to the local Gitea, NOT github.com, and that's deliberate:
    everything under gitops/ is read exclusively by the Argo CD running in
    this local cluster. Nothing in Octopus Cloud ever reads it — the SaaS
    side drives deployments in through its Gateway, and its `saas`-labelled
    Applications live in this same cluster. So the local Gitea is always a
    correct address for these, and committing it means switching git
    backends no longer requires rewriting and committing gitops/ files.

    Contrast with cac_repo_url in control-plane/app-randomquotes, which
    must stay github.com by default: Octopus Cloud genuinely cannot reach
    host.docker.internal, so the SaaS worktree needs the public URL there.

    `make gitea-disable` overrides this back to github.com for running the
    lab without Gitea at all. See docs/local-gitea.md.
  EOT
  default     = "http://host.docker.internal:3000/admin/octopus-iac-lab"
}

variable "kube_context" {
  description = "kubeconfig context for the cluster. Defaults to docker-desktop."
  type        = string
  default     = "docker-desktop"
}

variable "install_argocd" {
  description = "If true, this worktree's stack installs ArgoCD itself (helm release, namespace, ingress, admin secret data source). If false, ArgoCD is assumed to already exist in the cluster — managed by the OTHER worktree — and we just install our own per-Octopus Gateway + Applications. Two worktrees can't both own the same helm release; whoever applies first sets `install_argocd = true`, the other sets `false`. Defaults to true on local self-host, false on SaaS (the SaaS worktree comes second by convention)."
  type        = bool
  default     = null
}

variable "argocd_chart_version" {
  description = "argo-cd helm chart version. https://github.com/argoproj/argo-helm/releases."
  type        = string
  default     = "7.7.*"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD installs into."
  type        = string
  default     = "argocd"
}

variable "gateway_chart_version" {
  description = "Octopus Argo CD Gateway chart version. Latest 1.x as of 2026-04 is 1.23.x."
  type        = string
  default     = "1.23.*"
}

variable "ingress_host" {
  description = "Hostname the Argo UI is reachable at via the cluster's nginx-ingress controller. *.localtest.me resolves to 127.0.0.1."
  type        = string
  default     = "argocd.localtest.me"
}

variable "argocd_password" {
  description = "Static admin password for ArgoCD. Used by the argocd provider to authenticate AND injected (bcrypt'd) into the helm release so the chart installs with this password. Default Password01! matches the lab's Octopus admin."
  type        = string
  default     = "Password01!"
  sensitive   = true
}

variable "argocd_password_bcrypt" {
  description = "Bcrypt hash of argocd_password. Helm chart sets configs.secret.argocdServerAdminPassword to this. Default matches Password01! (cost=10)."
  type        = string
  default     = "$2y$10$AqFVvMLTOKPKUyraFEoy5.V47mpGRuAAm0A7Q6j8GmMEVpNtYxi7K"
  sensitive   = true
}
