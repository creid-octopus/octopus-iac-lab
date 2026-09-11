package main

import rego.v1

# k8s recommended labels — non-negotiable for traceability across the
# 12+ namespaces this lab fans out to.

required_labels := [
	"app.kubernetes.io/name",
	"app.kubernetes.io/instance",
	"app.kubernetes.io/part-of",
]

deny contains msg if {
	input.kind == "Deployment"
	some label in required_labels
	not input.metadata.labels[label]
	msg := sprintf("Deployment %q is missing required label %q", [input.metadata.name, label])
}
