# Platform Hub policy bundle

Rego policies enforced at two points in the delivery pipeline:

1. **In-deploy gate** — Octopus runs `conftest test` against the rendered manifests as a pre-deploy step (see the `Validate against Platform Hub` step in `.octopus/deployment_process.ocl` on this branch). Failures surface in the Octopus task log and block the deploy.
2. **Admission** — Gatekeeper (installed cluster-wide on main, see `tofu/k8s-agent/gatekeeper.tf`) catches anything that bypasses Octopus.

The bundle itself is the same set of Rego files for both enforcement points. Today they're read from this directory; once the `octopusdeploy` provider exposes Platform Hub policy resources (none as of v1.12), they'll be registered as a published bundle so consuming projects pull the latest on every deploy.

## Bundle contents

| Rule | Catches |
|---|---|
| `image_registry.rego` | Containers using a image from outside the lab's own registries (typo / supply-chain). |
| `image_tag.rego` | `image: foo:latest` or unpinned digests. |
| `replicas_per_tier.rego` | Replica count exceeding the cap for the tenant tier label (free=1, pro=2, enterprise=3). |
| `required_labels.rego` | Missing `app.kubernetes.io/{name,instance,part-of}` labels. |
| `namespace_convention.rego` | Namespace doesn't match `(argo-)?randomquotes-{source}-{tenant}-{env}`. |
| `pod_security.rego` | `securityContext.privileged: true`, `hostNetwork: true`, or root user. |
| `resource_limits.rego` | Containers without both CPU and memory limits. |
| `worker_pool_gate.rego` | (Not yet enforced — `octopus.process` schema rule) Production steps must bind to a prod-approved worker pool. Companion to the `demo/locked-down-prod-pool` branch. |

## How to run locally

```bash
helm template gitops/charts/randomquotes \
  --set host=foo.localtest.me \
  --set tenant=acme-corp \
  --set tier=free \
  | conftest test - -p tofu/platform-hub/policies/
```

## How to add a new rule

Drop a `.rego` file in this directory. The bundle is reload-on-next-deploy — no Octopus restart, no per-project commit needed.
