package main

import rego.v1

# Every container declares CPU + memory limits. The lab's chart already
# does this on main; this catches drift if anyone copies a Deployment from
# elsewhere without limits.

deny contains msg if {
	input.kind == "Deployment"
	some i
	c := input.spec.template.spec.containers[i]
	not c.resources.limits.cpu
	msg := sprintf("container[%d] %q has no CPU limit", [i, c.name])
}

deny contains msg if {
	input.kind == "Deployment"
	some i
	c := input.spec.template.spec.containers[i]
	not c.resources.limits.memory
	msg := sprintf("container[%d] %q has no memory limit", [i, c.name])
}
