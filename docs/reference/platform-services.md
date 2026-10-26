# Platform services

What runs on the cluster that is not an app. Every release, with its chart,
version and values, is declared in `src/kubernetes/helmfile.yaml.gotmpl`; a
service with several moving parts keeps a README beside its values.

| Service                                       | Namespace             | What it is                                                                                                                                                           |
| --------------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| cert-manager                                  | `platform-networking` | certificates over DNS-01 for every route ([ADR-001](../decisions/001-certificates-are-issued-over-dns-01.md))                                                        |
| cloudflared                                   | `platform-networking` | the public tunnel, one catch-all rule to Traefik's `tunnel` entrypoint ([README](../../src/kubernetes/services/cloudflared/README.md))                               |
| external-dns                                  | `platform-networking` | a proxied CNAME for every public route, read off its IngressRoute ([ADR-026](../decisions/026-a-public-route-is-published-by-its-ingressroute.md))                   |
| Infisical operator                            | `platform-secrets`    | syncs every workload Secret from Infisical ([ADR-015](../decisions/015-deploy-secrets-are-fetched-once-by-ansible.md))                                               |
| Zot                                           | `platform-registry`   | `registry.internal.jterrazz.com`, every image and the app chart; collects its own garbage ([ADR-014](../decisions/014-the-registry-collects-its-own-garbage.md))     |
| VictoriaMetrics, VictoriaLogs, VictoriaTraces | `platform-telemetry`  | metrics 30d, logs 90d, traces 30d ([ADR-005](../decisions/005-telemetry-runs-on-the-victoriametrics-family.md))                                                      |
| OTel Collector                                | `platform-telemetry`  | OTLP from the apps and every pod's log file, into the three stores and Langfuse                                                                                      |
| Grafana                                       | `platform-telemetry`  | `grafana.internal.jterrazz.com`; dashboards and alerts provisioned, apps ship their own ([ADR-013](../decisions/013-grafana-gets-768mi-and-configmap-only-reach.md)) |
| kube-state-metrics, node-exporter             | `platform-telemetry`  | the `kube_*` and `node_*` series, scraped by annotation                                                                                                              |
| OpenPanel                                     | `platform-analytics`  | product analytics, six app-chart releases ([README](../../src/kubernetes/services/openpanel/README.md))                                                              |
| Traefik                                       | `kube-system`         | k3s' bundled ingress, shaped by its HelmChartConfig ([ADR-003](../decisions/003-traefiks-service-is-the-tailnet-gate.md))                                            |

An app other workloads call, such as the model gateway `studio-intelligence`,
stays an app: a shared one, a capability of the app chart's
[`uses` catalog](../../src/kubernetes/charts/app/README.md#specuses-and-specserves-access-is-a-consent-from-both-sides)
that admits its consumers with `serves`, not a row here.
