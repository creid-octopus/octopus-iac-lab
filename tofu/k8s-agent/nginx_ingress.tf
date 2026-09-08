# ─── CLUSTER-WIDE CONTROLLER ─────────────────────────────────────────────
# Lives on main so any branch's `make agent-apply` installs it. Used by:
# every tenant's Ingress (12 hostnames, all envs) — every demo branch
# transitively depends on this.
# ─────────────────────────────────────────────────────────────────────────
#
# nginx-ingress controller, cluster-wide infra. One controller serves every
# tenant's Ingress resource via Host header routing. Same idempotent
# `helm upgrade --install` pattern as the NFS CSI driver — multiple stacks
# can apply without coordination, destroy is a no-op.
#
# `controller.service.ports.http = 8080` so we don't fight port 80 with
# other LBs, and 8080 is the conventional dev-friendly high port. Browse
# any tenant at  http://<source>-<tenant>-<env>.localtest.me:8080.
# (`*.localtest.me` resolves to 127.0.0.1, so no /etc/hosts edits.)
#
# HTTPS is disabled (`controller.service.enableHttps=false`) — we don't
# terminate TLS for the lab and keeping :8443 free lets the Octopus compose
# container bind it for the gateway gRPC port without a host-port collision.
locals {
  # helm upgrade --install is idempotent, but null_resource only re-runs
  # local-exec when `triggers` changes, not when the command text itself
  # changes. Hashing the rendered command means editing the --set flags
  # below always re-applies on the next apply, instead of silently no-op'ing.
  nginx_ingress_command = <<-EOT
    helm upgrade --install ingress-nginx ingress-nginx \
      --repo https://kubernetes.github.io/ingress-nginx \
      --version "${var.nginx_ingress_chart_version}" \
      --namespace ingress-nginx --create-namespace \
      --kube-context "${var.kube_context}" \
      --set controller.service.type=LoadBalancer \
      --set controller.service.ports.http=8080 \
      --set controller.service.enableHttps=false \
      --set controller.hostPort.enabled=true \
      --set controller.hostPort.ports.http=8080 \
      --atomic --wait
  EOT
}

resource "null_resource" "nginx_ingress" {
  triggers = {
    chart_version = var.nginx_ingress_chart_version
    kube_context  = var.kube_context
    command_hash  = sha256(local.nginx_ingress_command)
  }

  provisioner "local-exec" {
    command = local.nginx_ingress_command
  }
}
