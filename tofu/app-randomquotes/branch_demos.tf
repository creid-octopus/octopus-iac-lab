# One Octopus project per feature-branch demo, all sharing the same OCL
# shape but pointed at different branches via CaC. Each project overrides
# `Source` so its tenant deployments land in distinct namespaces and on
# distinct ingress hosts (no collisions between demos on the same cluster).
#
# Add a string to var.demo_branches → next `make app-apply` creates one
# more demo project. Remove a string → tofu destroys it.
variable "demo_branches" {
  type        = set(string)
  description = "Branches to spin up as their own randomquotes demo project. Each gets a CaC-tracked project named randomquotes-<slug>. Empty by default — set via tfvars or `TF_VAR_demo_branches='[\"demo/foo\",\"demo/bar\"]'`."
  default     = []
}

locals {
  # Mirror of the agent stack's per-Octopus detection. Derives the base
  # `Source` value (local | saas) from the URL, then suffixes the branch
  # slug so each demo project's Source is unique.
  source_base = strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"

  # Strip the `demo/` prefix that the discovery filter already pinned —
  # within demo/* the path-after-prefix is unique because git refs are
  # unique paths, so no hash needed for disambiguation.
  branch_slugs = {
    for b in var.demo_branches :
    b => replace(b, "demo/", "")
  }
}

resource "octopusdeploy_project" "branch_demo" {
  for_each = var.demo_branches

  name                              = "${local.branch_slugs[each.key]}-randomquotes"
  description                       = "Branch demo: ${each.value}. Same OCL shape as randomquotes, CaC-tracking this branch so its bg variant is the live deployment process."
  project_group_id                  = local.cp.project_group_id
  lifecycle_id                      = local.cp.lifecycle_id
  default_guided_failure_mode       = "EnvironmentDefault"
  tenanted_deployment_participation = "Tenanted"
  is_version_controlled             = true

  included_library_variable_sets = [local.cp.lab_source_set_id]

  # base_path is the per-branch `.octopus-<slug>/` folder. Each demo branch
  # renames its `.octopus/` to that path so every demo project gets a
  # unique (repo, base_path) tuple — works around Octopus's CaC constraint
  # that limits projects sharing the same base_path.
  git_library_persistence_settings {
    url               = var.cac_repo_url
    default_branch    = each.value
    base_path         = ".octopus-${local.branch_slugs[each.key]}"
    git_credential_id = local.cp.git_credential_id
  }
}

# Override Source per project so each demo's namespaces + ingress hosts
# are unique. Project-scope wins over the included Lab Defaults set.
resource "octopusdeploy_variable" "branch_demo_source" {
  for_each = var.demo_branches

  owner_id = octopusdeploy_project.branch_demo[each.key].id
  name     = "Source"
  # Marked Sensitive purely because Octopus's API rejects non-sensitive
  # variable writes on VCS-controlled projects (those must go via OCL).
  # Source isn't actually a secret; the flag's just a workaround.
  type            = "Sensitive"
  sensitive_value = "${local.source_base}-${local.branch_slugs[each.key]}"
  is_sensitive    = true
}

# Each demo project participates with the same three tenants so the fan-out
# matches the main randomquotes project — three tenants × two envs per
# branch = 6 namespaces per branch on the cluster.
resource "octopusdeploy_tenant_project" "branch_demo_tenants" {
  # Map key uses "::" as separator — branch names may contain "-", tenant
  # keys may contain "_", but neither can contain "::". Prevents pairs
  # like (demo/foo, bar-baz) and (demo/foo-bar, baz) collapsing to the
  # same map key.
  for_each = {
    for pair in setproduct(tolist(var.demo_branches), keys(local.cp.tenant_ids)) :
    "${pair[0]}::${pair[1]}" => {
      branch = pair[0]
      tenant = pair[1]
    }
  }

  tenant_id  = local.cp.tenant_ids[each.value.tenant]
  project_id = octopusdeploy_project.branch_demo[each.value.branch].id
  # Per-tenant lifecycle scope: acme-corp lives on Dev + Production
  # (full lifecycle), globex + initech are Production-only — same
  # rule as project.tf, applied to every demo branch.
  environment_ids = each.value.tenant == "acme_corp" ? [
    local.cp.environment_ids.dev,
    local.cp.environment_ids.production,
    ] : [
    local.cp.environment_ids.production,
  ]
}
