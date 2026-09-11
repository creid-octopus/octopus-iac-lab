# Teach containerd on each cluster node that the local Gitea registry speaks
# plain HTTP.
#
# Why this is needed even though the Octopus feed already works: those are two
# different consumers. Octopus Server queries the registry itself (plain HTTP
# from its own process, no Docker involved) to resolve package versions. But
# kubelet is what actually PULLS the image, and containerd refuses plain-HTTP
# registries unless told otherwise. So a deployment gets a valid version from
# Octopus and then fails with ImagePullBackOff.
#
# Why it lives in tofu rather than a README step: node-level config does NOT
# survive a Docker Desktop Kubernetes reset. Done by hand, it silently
# disappears and resurfaces weeks later as an ImagePullBackOff nobody
# remembers the cause of.
#
# Disabled by default (empty host = no-op), enabled in offline mode by the
# git-backend.auto.tfvars override that compose/set-git-backend.sh writes.

variable "insecure_registry_host" {
  type        = string
  description = "host:port of a plain-HTTP registry to configure containerd for, e.g. host.docker.internal:3000. Empty disables this entirely."
  default     = ""
}

variable "cluster_node_containers" {
  type        = list(string)
  description = "Docker container names of the cluster's nodes. Defaults match Docker Desktop's kind-based provisioner; `docker ps --filter label=io.x-k8s.io/cluster` or `kubectl get nodes` will confirm."
  default     = ["desktop-control-plane", "desktop-worker"]
}

resource "null_resource" "containerd_insecure_registry" {
  count = var.insecure_registry_host != "" ? 1 : 0

  triggers = {
    registry = var.insecure_registry_host
    nodes    = join(",", var.cluster_node_containers)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-eu", "-o", "pipefail", "-c"]
    environment = {
      REGISTRY = var.insecure_registry_host
      NODES    = join(" ", var.cluster_node_containers)
    }
    command = <<-EOT
      for node in $NODES; do
        echo "=== $node"

        if ! docker inspect "$node" >/dev/null 2>&1; then
          echo "    no such container — check cluster_node_containers against 'kubectl get nodes'"
          exit 1
        fi

        # containerd reads per-registry config from a directory tree, but only
        # if config_path points at it. kind normally sets this; verify rather
        # than assume, because adding it is the one case needing a restart.
        if docker exec "$node" grep -q 'config_path.*certs.d' /etc/containerd/config.toml 2>/dev/null; then
          echo "    config_path already set"
          NEEDS_RESTART=no
        else
          echo "    adding registry config_path to containerd config.toml"
          docker exec "$node" bash -c 'cat >> /etc/containerd/config.toml <<CONF

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
CONF'
          NEEDS_RESTART=yes
        fi

        # hosts.toml itself is picked up dynamically, no restart required.
        docker exec "$node" mkdir -p "/etc/containerd/certs.d/$REGISTRY"
        docker exec "$node" bash -c "cat > '/etc/containerd/certs.d/$REGISTRY/hosts.toml' <<CONF
server = \"http://$REGISTRY\"

[host.\"http://$REGISTRY\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
CONF"
        echo "    wrote /etc/containerd/certs.d/$REGISTRY/hosts.toml"

        if [ "$NEEDS_RESTART" = yes ]; then
          # Brief disruption: pods keep running but image operations pause
          # while containerd comes back. Only happens the first time.
          echo "    restarting containerd"
          docker exec "$node" systemctl restart containerd
          for i in $(seq 1 30); do
            if docker exec "$node" crictl version >/dev/null 2>&1; then break; fi
            sleep 2
          done
        fi

        # Prove it: pull through containerd rather than trusting the config.
        if docker exec "$node" crictl pull "$REGISTRY/admin/octopus-iac-lab:latest" >/dev/null 2>&1; then
          echo "    verified: crictl pulled from $REGISTRY"
        else
          echo "    WARNING: config written but crictl pull failed."
          echo "    If the registry has no :latest tag yet that's expected — run the"
          echo "    build workflow, then re-run 'make agent-apply' to re-verify."
        fi
      done
    EOT
  }
}
