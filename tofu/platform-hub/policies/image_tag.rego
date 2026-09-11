package main

import rego.v1

# Forbid :latest and unpinned tags. Image must end with an explicit version
# or a digest. ArgoCDUpdateImageTags writes a real version in, so this also
# guards against the step silently failing and leaving the previous tag.

deny contains msg if {
	input.kind == "Deployment"
	some i
	image := input.spec.template.spec.containers[i].image
	endswith(image, ":latest")
	msg := sprintf("container[%d] uses :latest tag (image=%q)", [i, image])
}

deny contains msg if {
	input.kind == "Deployment"
	some i
	image := input.spec.template.spec.containers[i].image
	not contains(image, ":")
	not contains(image, "@sha256:")
	msg := sprintf("container[%d] image %q has no explicit tag or digest", [i, image])
}
