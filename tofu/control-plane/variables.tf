variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server (e.g. http://localhost:8090)."
}

variable "octopus_api_key" {
  type        = string
  description = "API key minted in Octopus → Profile → My API Keys."
  sensitive   = true
}

variable "github_pat" {
  type        = string
  description = "GitHub Personal Access Token. Used by Octopus to read/write CaC OCL files (repo scope) and pull container images from GHCR (read:packages scope)."
  sensitive   = true
}

variable "github_username" {
  type        = string
  description = "GitHub username paired with the PAT. Anything works for PAT auth on the CaC credential, but GHCR pulls require the actual username."
  default     = "creid-octopus"
}

variable "container_registry_url" {
  type        = string
  description = <<-EOT
    Registry the GHCR feed points at. Defaults to ghcr.io; offline mode
    overrides it to the local Gitea registry via git-backend.auto.tfvars.

    Must be an address reachable from BOTH the Octopus Server and the
    Kubernetes nodes, because Octopus queries it for package versions and
    kubelet pulls the image from it. That rules out `gitea:3000` (invisible
    to the cluster) and `localhost:3000` (invisible to both), leaving
    host.docker.internal — same constraint as the git URLs.

    Credentials come from github_username/github_pat, which the Makefile
    already swaps to the Gitea admin + token when GITEA_ENABLED=true.
  EOT
  default     = "https://ghcr.io"
}

variable "cac_repo_url" {
  type        = string
  description = "HTTPS URL of the Git repo Octopus pulls/pushes CaC from."
}

variable "cac_branch" {
  type        = string
  description = "Default branch Octopus uses for CaC."
  default     = "main"
}

variable "cac_base_path" {
  type        = string
  description = "Path inside the repo where Octopus stores OCL files."
  default     = "cac"
}

variable "enable_servicenow_change_control" {
  type        = bool
  description = "Marks the Production environment as ServiceNow change-controlled. Defaults on lab-wide — the env-level flag is harmless without an actual SNow connection (which lives in tofu/servicenow/, applied only when the snow demo is active). Set to false to drop the marker entirely."
  default     = true
}
