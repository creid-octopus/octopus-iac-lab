package main

import rego.v1

# Allow only images from this lab's own registries.
# Trips on typos and any pull from an unintended registry.
#
# BOTH backends are listed on purpose. Offline the lab builds and pulls from
# the local Gitea registry, so a GHCR-only list would make this policy reject
# the lab's own images — the demo failing on its own rule rather than on the
# thing it's meant to catch.
#
# The demo still demonstrates what it's for: anything else (docker.io,
# quay.io, a typo'd namespace) is rejected. See demos/platform-hub-opa.md.
allowed_registries := [
	"ghcr.io/creid-octopus/",
	"host.docker.internal:3000/admin/",
]

deny contains msg if {
	input.kind == "Deployment"
	some i
	image := input.spec.template.spec.containers[i].image
	not allowed_image(image)
	msg := sprintf(
		"container[%d] image %q not from an allowed registry (%v)",
		[i, image, allowed_registries],
	)
}

allowed_image(image) if {
	some prefix in allowed_registries
	startswith(image, prefix)
}
