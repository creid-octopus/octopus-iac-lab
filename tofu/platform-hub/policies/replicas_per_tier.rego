package main

import rego.v1

# Tier-aware replica cap. The headline rule that makes Platform Hub the
# right home for this bundle: it's not generic CIS baseline material, it
# encodes a business contract about what each subscription tier may use.
#
# Tier comes from the chart's tenant.octopus.com/tier label, which is set
# from the existing `tier/{free,pro,enterprise}` tenant tag.

tier_cap := {
	"free": 1,
	"pro": 2,
	"enterprise": 3,
}

deny contains msg if {
	input.kind == "Deployment"
	tier := input.metadata.labels["tenant.octopus.com/tier"]
	cap := tier_cap[tier]
	input.spec.replicas > cap
	msg := sprintf(
		"tier=%s allows max %d replicas, got %d",
		[tier, cap, input.spec.replicas],
	)
}

deny contains msg if {
	input.kind == "Deployment"
	tier := input.metadata.labels["tenant.octopus.com/tier"]
	not tier_cap[tier]
	msg := sprintf("tier=%q is not one of: free, pro, enterprise", [tier])
}
