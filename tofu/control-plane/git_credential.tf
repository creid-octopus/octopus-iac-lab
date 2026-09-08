# PAT-based credential Octopus uses to read/write OCL in the CaC repo.
# Username can be anything when authenticating GitHub with a PAT — the PAT
# carries the identity.
#
# `repository_restrictions` pins the credential to this single repo URL on
# the Octopus side: even if a project somewhere else in the Space tried to
# point at a different repo with this credential, Octopus would refuse.
# Defence-in-depth on top of the PAT's GitHub-side scope (which should also
# be a fine-grained PAT limited to creid-octopus/octopus-iac-lab Contents R/W).
resource "octopusdeploy_git_credential" "github_pat" {
  name        = "GitHub PAT (octopus-iac-lab)"
  description = "Personal access token used by Octopus for Config-as-Code."
  type        = "UsernamePassword"
  username    = var.github_username
  password    = var.github_pat

  repository_restrictions = {
    enabled              = true
    allowed_repositories = [var.cac_repo_url]
  }
}
