variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server (e.g. http://localhost:8090)."
}

variable "octopus_api_key" {
  type        = string
  description = "API key minted in Octopus → Profile → My API Keys."
  sensitive   = true
}

variable "enable_platform_hub" {
  type        = bool
  description = "Platform Hub is Enterprise-tier on SaaS. Set false to skip the resources entirely (count = 0)."
  default     = true
}

variable "github_pat" {
  type        = string
  description = "GitHub PAT (classic, repo scope). Same one cp uses for the CaC credential."
  sensitive   = true
}

variable "github_username" {
  type        = string
  description = "Username paired with the PAT. Anything works for GitHub PAT auth — the token carries the identity."
  default     = "creid-octopus"
}

variable "ph_repo_url" {
  type        = string
  description = "HTTPS URL of the Git repo Platform Hub reads policies from."
}

variable "ph_branch" {
  type        = string
  description = "Default branch Platform Hub reads from."
  default     = "main"
}

variable "ph_base_path" {
  type        = string
  description = "Path inside the repo where Platform Hub policy YAML lives."
  default     = ".octopus"
}
