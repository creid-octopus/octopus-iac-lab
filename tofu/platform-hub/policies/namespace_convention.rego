package main

import rego.v1

# All app workloads must land in a namespace matching the lab's convention.
# Pattern:    (argo-)?randomquotes-{source}-{tenant}-{env}
# Examples:
#   randomquotes-local-acme-corp-dev          (agent path)
#   argo-randomquotes-saas-globex-production  (GitOps path)
#   randomquotes-local-bg-preview-globex-dev  (demo branch)

ns_pattern := `^(argo-)?randomquotes-[a-z0-9-]+$`

deny contains msg if {
	input.kind == "Deployment"
	ns := input.metadata.namespace
	ns != ""
	not regex.match(ns_pattern, ns)
	msg := sprintf("namespace %q does not match lab convention %s", [ns, ns_pattern])
}
