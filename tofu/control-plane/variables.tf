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
