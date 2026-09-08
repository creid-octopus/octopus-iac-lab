# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key,
# github_pat come in via TF_VAR_* exports from .env. octopus_space comes
# from tofu/space/ via terraform_remote_state.
cac_repo_url  = "https://github.com/creid-octopus/octopus-iac-lab.git"
cac_branch    = "main"
cac_base_path = ".octopus"

# Production env is permanently marked change-controlled. Has no effect on
# projects without ServiceNowChangeControlled = true, so it's safe to leave
# on for the whole lab — only the servicenow-cr-gate demo project actually
# fires the CR. Setting this here means the env wakes up demo-ready after
# any tofu wipe / `make destroy + apply`.
enable_servicenow_change_control = true
