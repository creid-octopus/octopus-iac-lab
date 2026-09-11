package octopus.process

import rego.v1

# Production-must-bind-to-prod-approved-pool gate.
#
# Companion to demo/locked-down-prod-pool. That branch closes the
# variable-tamper paths via RBAC (no VariableEdit, no
# LibraryVariableSetEdit). But `ProcessEdit` — which any project
# author needs — still lets a user hand-pin `Octopus.Action.WorkerPool`
# on their own steps, and Octopus has no per-pool ACL to refuse it
# (WorkerView/WorkerEdit are space-wide on/off, workers have no
# label-based selection). This Rego rule is the structural gate: it
# rejects deployment-process payloads where a Production-bound step
# pins anything other than a prod-approved pool. Without this rule,
# "dev can't pick prod-pool" is cosmetic; with it, the server refuses
# the process at submit time regardless of who authored.
#
# NOT YET ENFORCED in this lab. The other rego files in this bundle run
# against rendered Kubernetes manifests via conftest (see README); this
# rule targets the Octopus *process* schema, which isn't wired into a
# Platform Hub policy enforcement endpoint yet (no provider resource as
# of octopusdeploy v1.12, and the API endpoint is undocumented). When
# Octopus ships the Platform Hub Policy resource type, this file moves
# straight to the published bundle — no rule changes needed.
#
# Input shape (Octopus's process-payload form):
#   {
#     "environment": "Production",
#     "process": {
#       "steps": [
#         { "name": "Deploy ...", "worker_pool": "dev-pool" | "prod-pool" | null, ... },
#         ...
#       ]
#     }
#   }

prod_approved_pools := {"prod-pool"}

deny contains msg if {
	input.environment == "Production"
	step := input.process.steps[_]
	pool := step.worker_pool
	pool != null
	not prod_approved_pools[pool]
	msg := sprintf(
		"Step %q in Production must bind to a prod-approved worker pool, got %q. Approved pools: %v",
		[step.name, pool, prod_approved_pools],
	)
}
