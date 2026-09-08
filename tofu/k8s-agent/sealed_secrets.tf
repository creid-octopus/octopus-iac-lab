# ─── CLUSTER-WIDE CONTROLLER ─────────────────────────────────────────────
# Lives on main so any branch's `make agent-apply` installs it. Demo branch
# that exercises this: feat/sealed-secrets (commits a SealedSecret CRD that
# this controller decrypts into a real k8s Secret at deploy time).
# ─────────────────────────────────────────────────────────────────────────
#
# Sealed Secrets lets us commit encrypted secrets to git. The controller
# holds a private key in the cluster and decrypts SealedSecret CRDs into
# regular k8s Secrets. Combined with `kubeseal --scope cluster-wide`, one
# sealed blob in the chart works for every tenant's destination namespace
# without per-namespace re-encryption.
#
# Without persistence, the controller's keypair regenerates on every fresh
# cluster install — making every SealedSecret previously sealed against
# the old key un-decryptable. To survive cluster resets, the active
# keypair is mirrored to .env as `SEALED_SECRETS_TLS_B64`:
#
#   - First install: controller mints a fresh keypair. The save step
#     writes a base64 of the labeled Secret YAML back to .env.
#   - Subsequent installs (cluster reset, `make nuke`, etc.): the restore
#     step pre-applies the saved keypair as a labeled Secret BEFORE the
#     controller comes up, so the controller adopts it as active and old
#     SealedSecrets keep decrypting.

# Restore the saved keypair before the controller installs. Only runs
# when the var is non-empty AND no active key is already on the cluster
# — that way a re-apply doesn't clobber a freshly-rotated key in-cluster.
resource "null_resource" "sealed_secrets_restore_key" {
  count = var.sealed_secrets_tls_b64 != "" ? 1 : 0

  triggers = {
    key_hash     = sha256(var.sealed_secrets_tls_b64)
    kube_context = var.kube_context
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-eu", "-c"]
    environment = {
      KEY_B64      = var.sealed_secrets_tls_b64
      KUBE_CONTEXT = var.kube_context
    }
    command = <<-EOT
      if kubectl --context "$KUBE_CONTEXT" -n kube-system get secrets \
           -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
           --no-headers 2>/dev/null | grep -q .; then
        echo "✓ sealed-secrets active key already present in cluster — leaving alone"
        exit 0
      fi
      echo "$KEY_B64" | base64 -d | kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null
      echo "✓ restored sealed-secrets active key from SEALED_SECRETS_TLS_B64"
    EOT
  }
}

resource "null_resource" "sealed_secrets" {
  triggers = {
    chart_version = var.sealed_secrets_chart_version
    kube_context  = var.kube_context
  }

  depends_on = [null_resource.sealed_secrets_restore_key]

  provisioner "local-exec" {
    command = <<-EOT
      helm upgrade --install sealed-secrets sealed-secrets \
        --repo https://bitnami.github.io/sealed-secrets \
        --version "${var.sealed_secrets_chart_version}" \
        --namespace kube-system \
        --kube-context "${var.kube_context}" \
        --set fullnameOverride=sealed-secrets-controller \
        --atomic --wait
    EOT
  }
}

# Capture the active keypair back to .env after install. Only runs when
# the var is empty (i.e. first-ever install on this host) — so it never
# clobbers a SEALED_SECRETS_TLS_B64 the user already has.
resource "null_resource" "sealed_secrets_save_key" {
  count = var.sealed_secrets_tls_b64 == "" ? 1 : 0

  triggers = {
    install_id = null_resource.sealed_secrets.id
  }

  depends_on = [null_resource.sealed_secrets]

  provisioner "local-exec" {
    interpreter = ["bash", "-eu", "-c"]
    environment = {
      KUBE_CONTEXT = var.kube_context
      ENV_FILE     = "${path.module}/../../.env"
    }
    command = <<-EOT
      KEY_YAML=$(kubectl --context "$KUBE_CONTEXT" -n kube-system get secrets \
        -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml)
      if [ -z "$KEY_YAML" ] || ! echo "$KEY_YAML" | grep -q 'kind: Secret'; then
        echo "! no active sealed-secrets key found on cluster — not writing to .env"
        exit 0
      fi
      KEY_B64=$(printf '%s' "$KEY_YAML" | base64 | tr -d '\n')
      if grep -q '^SEALED_SECRETS_TLS_B64=' "$ENV_FILE"; then
        echo "✓ SEALED_SECRETS_TLS_B64 already in .env — not overwriting"
      else
        printf '\n# sealed-secrets controller keypair — written by tofu so the\n# keypair survives cluster resets. See tofu/k8s-agent/sealed_secrets.tf.\nSEALED_SECRETS_TLS_B64=%s\n' "$KEY_B64" >> "$ENV_FILE"
        echo "✓ wrote SEALED_SECRETS_TLS_B64 to $ENV_FILE"
      fi
    EOT
  }
}
