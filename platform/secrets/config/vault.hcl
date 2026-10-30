# Vault's server configuration on the estate path. It is the live
# configuration fleet-infra's vault chart renders (ConfigMap
# data-system/vault-config, read 2026-10-29), less what only the chart's
# StatefulSet needed:
#
# - `service_registration "kubernetes"` is gone. It labels the pod
#   vault-active and vault-sealed, which only the chart's vault-active and
#   vault-standby Services and the old ServiceMonitor's relabel read, and it
#   needs a Role on pods the render does not grant.
# - `cluster_addr` and `api_addr` are written here, not handed in through the
#   chart's VAULT_CLUSTER_ADDR and VAULT_API_ADDR. One server is the whole raft
#   cluster, so its cluster address is its own loopback.
# - The raft node id is left to Vault, which writes it into the data volume on
#   first start and reads it back on every later one. The chart named the node
#   after its pod, vault-0; a Deployment's pod name changes on each start.
#
# Integrated storage asks for mlock to be off: the posture drops IPC_LOCK, and
# the live server runs with it off too.

ui            = true
disable_mlock = true

api_addr     = "http://vault.secrets-system.svc.cluster.local:8200"
cluster_addr = "https://127.0.0.1:8201"

listener "tcp" {
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_disable     = 1

  # Prometheus scrapes /v1/sys/metrics without a token. Live, a token scrapes
  # it, which VSO projects for a ServiceMonitor; the model renders a scrape
  # with no credential, so the token, its renewal CronJob and its VSO copy
  # retire with this change (decision D3 in docs/runbooks/secrets-handover.md).
  # The metrics carry no secret.
  telemetry {
    unauthenticated_metrics_access = true
  }
}

storage "raft" {
  path = "/vault/data"
}

# Prometheus format on /v1/sys/metrics, histograms kept for 24h so a
# percentile is not reset on every scrape.
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}
