# Platform services

What runs on the cluster that is not an app. Each service with more than one
moving part keeps its own README beside its values files, with versions, data
paths, secrets and quirks.

- **LibreChat** — private AI chat at `chat.internal.jterrazz.com`, namespace
  `platform-ai`. Three releases: `librechat-platform`, `librechat-mongodb` (app
  chart) and the upstream `librechat`.
  [README](../kubernetes/services/librechat/README.md)
- **OpenPanel** — product analytics; private dashboard at
  `openpanel.internal.jterrazz.com`, public ingest at
  `analytics.jterrazz.com/api/track`, namespace `platform-analytics`. Six
  app-chart releases (`op-postgres`, `op-redis`, `op-clickhouse`, `op-api`,
  `op-worker`, `op-dashboard`) plus `openpanel-platform`, which owns the volumes
  and the two certificates its routes share.
  [README](../kubernetes/services/openpanel/README.md)
- **cloudflared** — the public-traffic tunnel, namespace `platform-networking`.
  The one raw Deployment in the tree, deliberately (`hostNetwork: true`).
  [README](../kubernetes/services/cloudflared/README.md)
- **Telemetry** (`platform-telemetry`) — the VictoriaMetrics family:
  VictoriaMetrics (metrics, 30d, scrapes via `-promscrape.config` and receives
  Prometheus remote-write), VictoriaLogs (logs, 90d) and VictoriaTraces (traces,
  720h, pre-1.0 on purpose), plus Grafana, kube-state-metrics, node-exporter and
  the OTel Collector. Prometheus, Loki, Tempo and Alloy are gone; do not
  resurrect them when editing lists. The collector does double duty: OTLP from
  instrumented apps, and a `filelog` receiver tailing `/var/log/pods` for every
  pod's stdout, which is the job Alloy used to do — so `kubectl logs` is never
  the only copy. Grafana's datasource UIDs are still `prometheus` / `loki` /
  `tempo`, because dashboards and app-shipped alert rules reference them; only
  the names, URLs and two of the types changed.
- **Registry** — `registry.internal.jterrazz.com`, namespace
  `platform-registry`. Its IngressRoute uses `cluster-internal-access` because
  containerd's hairpin pull is sourced from a pod-CIDR or node address, not a
  tailnet IP. Note the loop: the deploy workflow's own setup logs into this
  registry, so taking the `registry` release down means the deploy that would
  restore it cannot start. Recover with `make deploy-platform` from the Mac.
- **gateway-intelligence** — an app-chart workload deployed by its own repo. It
  runs CLIProxyAPI with `api-keys: []`, which leaves its auth middleware
  allowing everything. The security boundary is NetworkPolicy plus private-only
  ingress, not a bearer token; consumers pass the non-secret placeholder
  `gateway-noauth` only because the OpenAI and Anthropic SDKs require a
  non-empty string. There is no gateway API key in Infisical.

n8n and Portainer were removed. Their `/var/lib/k8s-data` directories are kept
(PVs were `Retain`); everything else — namespace, CNAME, manifests — is gone.
Do not resurrect them by accident when editing lists.
