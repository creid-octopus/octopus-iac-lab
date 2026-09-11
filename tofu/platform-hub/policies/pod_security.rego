package main

import rego.v1

# Baseline pod-security checks. Cheaper than a full PSA profile for a
# sandbox lab, but enough to catch obvious misconfig.

deny contains msg if {
	input.kind == "Deployment"
	input.spec.template.spec.hostNetwork == true
	msg := sprintf("Deployment %q uses hostNetwork: true", [input.metadata.name])
}

deny contains msg if {
	input.kind == "Deployment"
	some i
	input.spec.template.spec.containers[i].securityContext.privileged == true
	msg := sprintf("Deployment %q container[%d] is privileged", [input.metadata.name, i])
}

deny contains msg if {
	input.kind == "Deployment"
	some i
	input.spec.template.spec.containers[i].securityContext.runAsUser == 0
	msg := sprintf("Deployment %q container[%d] runs as root", [input.metadata.name, i])
}
