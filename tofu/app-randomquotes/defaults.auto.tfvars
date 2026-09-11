# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key come
# in via TF_VAR_* exports from .env. octopus_space comes from tofu/space/
# via terraform_remote_state.
cac_repo_url  = "https://github.com/creid-octopus/octopus-iac-lab.git"
cac_branch    = "main"
cac_base_path = ".octopus"

demo_branches = [
  # "demo/blue-green",
  # "demo/bg-preview",
  # "demo/canary",
  "demo/platform-hub-opa",
  # "demo/process-template",
  # "demo/servicenow-cr-gate",
  # "demo/smoke-step-template",
]
