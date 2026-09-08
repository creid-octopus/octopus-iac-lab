output "project_url" {
  value       = "${var.octopus_url}/app#/${data.terraform_remote_state.space.outputs.space_id}/projects/${octopusdeploy_project.randomquotes.id}/deployments/process"
  description = "Open the randomquotes project in the Octopus UI."
}

output "project_id" {
  value = octopusdeploy_project.randomquotes.id
}

# Consumed by tofu/k8s-agent/ to scope the deployment target to the Previews
# parent env — auto-provisioned ephemeral children only inherit targets scoped
# to their parent, and parent envs aren't resolvable by name via the API.
output "previews_parent_environment_id" {
  value = octopusdeploy_parent_environment.previews.id
}
