resource "octopusdeploy_lifecycle" "dev_to_production" {
  name        = "Dev to Production"
  description = "Auto-deploy to Dev on release creation; promote to Production manually."

  phase {
    name                                  = "Dev"
    automatic_deployment_targets          = [octopusdeploy_environment.dev.id]
    minimum_environments_before_promotion = 1
    is_optional_phase                     = false
  }

  phase {
    name                                  = "Production"
    optional_deployment_targets           = [octopusdeploy_environment.production.id]
    minimum_environments_before_promotion = 1
    is_optional_phase                     = false
  }

  release_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 30
    unit             = "Days"
  }

  tentacle_retention_with_strategy {
    strategy         = "Count"
    quantity_to_keep = 30
    unit             = "Days"
  }
}
