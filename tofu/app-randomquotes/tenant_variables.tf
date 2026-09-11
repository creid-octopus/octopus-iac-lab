# Per-tenant values for the randomquotes project templates (project.tf). These
# are facets of how a customer appears in *this* app — display name, plus the
# mood that drives its icon + accent colour — so they live on the project per
# tenant, not as control-plane tenant tags. Keeping the values here (not
# hand-entered on the tenant variables page) means a nuked instance restores
# every customer's branding on apply.
#
# Unscoped: none of these vary by environment (Acme is comedy in Dev and in
# Prod). The provider rejects a fully-absent scope ("Must specify either
# 'environment_id' or 'scope'"), so we pass an empty environment scope — which
# means all environments. Previews are untenanted and keep their own values
# channel-scoped in .octopus/variables.ocl.
locals {
  # tenant => { display name, mood, header icon, accent colour }. Mood was the
  # old `mood/*` tenant tag; icon/colour were derived from it in variables.ocl.
  tenant_branding = {
    acme_corp = { display = "Acme Corp", mood = "comedy", icon = "🃏", color = "#F5C518" }
    globex    = { display = "Globex Corporation", mood = "silicon-valley", icon = "🚀", color = "#00B0FF" }
    initech   = { display = "Initech", mood = "stoic", icon = "🧘", color = "#7E57C2" }
  }

  template_ids = {
    for t in octopusdeploy_project.randomquotes.template : t.name => t.id
  }

  # Flatten to (tenant, template) pairs so one resource block covers every
  # branding value × tenant.
  # Skips any pair whose template isn't declared (with a `prompt {}` block)
  # in .octopus/variables.ocl yet. Add the missing prompt blocks there to
  # light these back up — no change needed here once they exist.
  tenant_branding_vars = merge([
    for tkey, b in local.tenant_branding : {
      for pair in [
        { tmpl = "Brand.DisplayName", value = b.display },
        { tmpl = "Featured.Mood", value = b.mood },
        { tmpl = "Brand.Icon", value = b.icon },
        { tmpl = "Brand.Color", value = b.color },
        ] : "${tkey}.${pair.tmpl}" => {
        tenant_key  = tkey
        template_id = lookup(local.template_ids, pair.tmpl, null)
        value       = pair.value
      }
      if lookup(local.template_ids, pair.tmpl, null) != null
    }
  ]...)
}

resource "octopusdeploy_tenant_project_variable" "branding" {
  for_each = local.tenant_branding_vars

  project_id  = octopusdeploy_project.randomquotes.id
  template_id = each.value.template_id
  tenant_id   = local.cp.tenant_ids[each.value.tenant_key]
  value       = each.value.value

  scope {
    environment_ids = []
  }

  depends_on = [octopusdeploy_tenant_project.tenants]
}
