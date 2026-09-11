# Library variable set holding per-Octopus values that the CaC project
# references but can't carry in OCL (OCL is shared across both Octopi —
# values that differ per instance must live in HCL).
#
# Right now: just `Source` = local | saas. Used to build per-(source,
# tenant, env) namespace names without parsing the agent's name with a
# magic-number Substring.

locals {
  # Same derivation as agent name: `*.octopus.app` host → SaaS, otherwise
  # local. Each Octopus's HCL apply produces the right value for itself.
  source_kind = strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"
}

resource "octopusdeploy_library_variable_set" "lab_source" {
  name        = "lab-source"
  description = "Per-Octopus identity (local vs saas). Included by the randomquotes project."
}

resource "octopusdeploy_variable" "source" {
  owner_id = octopusdeploy_library_variable_set.lab_source.id
  name     = "Source"
  type     = "String"
  value    = local.source_kind
}

# GitHub PAT exposed as a sensitive script variable so runbook steps that
# commit to git (e.g. the maintenance-on/off runbooks' "Set Argo
# Maintenance" step) can authenticate the push. The same PAT is already
# stored as an Octopus Git credential for CaC, but Git credentials aren't
# directly addressable from script steps — they're consumed internally by
# Octopus's Git plumbing. Hence this duplication.
resource "octopusdeploy_variable" "github_token" {
  owner_id        = octopusdeploy_library_variable_set.lab_source.id
  name            = "GitHub.Token"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = var.github_pat
}

# Ready-to-use authenticated clone URL for runbook script steps.
#
# Exists so OCL never hardcodes a git host. Before this, the maintenance
# runbooks embedded `github.com/...` (or `host.docker.internal:3000/...`)
# directly in their script bodies, which meant switching the lab between
# github.com and the local Gitea required editing and committing OCL — the
# offline setup became a divergent commit instead of the same content
# running against a different backend.
#
# Now the runbooks just `git clone "#{Git.CloneUrl}"` and this variable
# carries whatever backend the stack is configured for. Credentials are
# injected after the scheme, which works for both forms:
#   https://<user>:<pat>@github.com/owner/repo.git
#   http://admin:<token>@host.docker.internal:3000/admin/repo.git
#
# Sensitive because the token is part of the value. Anything cloning with
# it inherits push rights, which is what the maintenance runbooks need.
resource "octopusdeploy_variable" "git_clone_url" {
  owner_id        = octopusdeploy_library_variable_set.lab_source.id
  name            = "Git.CloneUrl"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = replace(var.cac_repo_url, "://", "://${var.github_username}:${var.github_pat}@")
}

# Worker pool name to target for bash script steps. SaaS's default dynamic
# worker is Windows ("Hosted Windows") and there's no /bin/bash there;
# pin to "Hosted Ubuntu" instead. Local self-host has only "Default Worker
# Pool" (the built-in Octopus Server worker, which is Linux).
# Used by runbook script steps via Octopus.Action.WorkerPoolVariable.
data "octopusdeploy_worker_pools" "linux" {
  partial_name = local.source_kind == "saas" ? "Hosted Ubuntu" : "Default Worker Pool"
}

resource "octopusdeploy_variable" "linux_worker_pool" {
  owner_id = octopusdeploy_library_variable_set.lab_source.id
  name     = "Runbook.LinuxWorker"
  type     = "WorkerPool"
  value    = data.octopusdeploy_worker_pools.linux.worker_pools[0].id
}

# Default for Project.WorkerPool — keeps Dev deploys working on both
# instances. The CaC OCL (.octopus/variables.ocl) layers a Production-scoped
# override on top → prod-pool. With no library-level default, Dev deploys
# fail with "No variable named 'Project.WorkerPool' was in scope" because
# worker_pool_variable on an action doesn't fall back to the instance
# default. Slug-per-instance can't live in OCL (shared across both Octopi).
resource "octopusdeploy_variable" "project_worker_pool_default" {
  owner_id = octopusdeploy_library_variable_set.lab_source.id
  name     = "Project.WorkerPool"
  type     = "WorkerPool"
  value    = data.octopusdeploy_worker_pools.linux.worker_pools[0].id
}

