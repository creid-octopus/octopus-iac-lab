# `is_task_queue_stopped = false` while we use the Space, but the destroy
# lifecycle of this resource flips it to true before issuing DELETE — that's
# the precondition Octopus enforces.
#
# Both system teams as Space managers because the API key user lives in a
# different team depending on the target: local self-host puts the bootstrap
# user in `teams-administrators`; SaaS puts the customer in `teams-managers`.
# Listing both works on both targets — the empty team is a no-op.
resource "octopusdeploy_space" "this" {
  name = var.space_name
  # Pin the slug — it's the stable interface CI references (the auto-generated
  # `Spaces-N` ID increments every destroy/recreate). Renaming the Space won't
  # invalidate GHA secrets when the slug is locked here.
  slug        = "iac-sandbox"
  description = var.space_description
  # Make IaC Sandbox the post-login landing space — otherwise non-admin
  # users (dev / prod-deployer) land in the empty Default space and see
  # the "Deploy your first application" welcome screen. SaaS overrides to
  # false: Octopus Cloud's managed Default Space can't be demoted from here.
  is_default            = var.space_is_default
  is_task_queue_stopped = false
  space_managers_teams  = ["teams-administrators", "teams-managers"]
}
