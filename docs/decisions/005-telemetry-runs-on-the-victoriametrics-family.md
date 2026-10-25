# ADR-005: Telemetry runs on the VictoriaMetrics family, logs folded into the collector

**Status:** Accepted
**Date:** 2026-07-26

Written 2026-10-24 from the comments in `src/kubernetes/services/{otel-collector,
victoria-*,grafana,kube-state-metrics}/` (commit 5093096 and its follow-ups
30c461e and 61be749) that this record replaces.

Revised 2026-10-25: the control plane's series are no longer scraped.

## Context

The first telemetry stack (2026-03-08) was Grafana with Prometheus, Loki and
Tempo, plus an OpenTelemetry collector and a separate log agent, on a single
memory-bound node whose persistent volumes sit on virtiofs. Four stores and
two shippers was a lot of moving parts for one machine, and each store had
its own query language and its own storage engine to tune.

## Decision

One OpenTelemetry collector ships everything, into VictoriaMetrics (metrics),
VictoriaLogs (logs) and VictoriaTraces (traces), each single-node; Grafana
reads all three through core or signed datasources.

### The collector

- **A Deployment, not a DaemonSet**, though it tails the node's container
  logs off a hostPath: one node means one collector sees every pod's log
  file, and the OTLP Service stays backed by exactly one endpoint. The day a
  second node exists it must become `mode: daemonset` (a Deployment would
  silently collect one node's logs), add
  `filter.node_from_env_var: K8S_NODE_NAME` to `k8s_attributes`, and rethink
  where the OTLP receiver lives.
- **`Recreate`, not RollingUpdate.** The filelog read offsets live in the
  `file_storage` extension, one bbolt file on a hostPath that one process can
  hold open. A surged pod dies on startup (exit 2, right after "Starting
  stanza receiver"), the old one is never drained, `helm --wait` burns its
  timeout and the deploy fails on a fine config change. With one replica and
  a shared lock there is no zero-downtime path.
- **Runs as root, read-only on `/var/log`.** containerd creates the files
  under `/var/log/pods` root-owned with group-restricted modes; the image's
  10001 cannot open them, and a collector that starts fine and ships nothing
  is the worst failure shape here. Tightened, verify by content:
  `kubectl logs -n platform-telemetry deploy/otel-collector | grep -i 'permission denied'`.
- **Offsets on a node-local hostPath**, not an emptyDir (deleted with the pod,
  which is exactly the `helm upgrade` case) and not `/var/lib/k8s-data`
  (bbolt over virtiofs, for data worthless after a repave; losing it costs one
  gap). `start_at: beginning` is safe only because `storage:` is set: offsets
  make it apply to never-seen files alone. `end` would silently drop every
  line written while the collector was down.
- **Paths are `/var/log/pods/*/*/*.log`**, never `/var/log/containers`: the
  `container` operator derives pod, uid, namespace and container by parsing
  the path and recognises only that layout. `k8s_attributes` associates on
  `k8s.pod.uid` alone (the preset's trailing `from: connection` would label
  every file-tailed log as the collector's own) and runs only on the
  `logs/pods` pipeline; the chart's preset is not used because it injects the
  processor into every pipeline, `traces/langfuse` included.
- **Orphan client spans are dropped**: undici's instrumentation opens a root
  span for every fetch outside a request context, so a polling loop was 99%
  of everything reaching VictoriaTraces, one unreadable single-span trace per
  call. Structural, not a denylist; client spans under a parent are kept.
- **Lists replace, maps merge**: `service.extensions` must name
  `health_check` beside `file_storage`, or the probes fail forever.
- Component names use the underscore spellings (`k8s_attributes`,
  `otlp_http`, `prometheus_remote_write`, `file_log`), canonical since
  Collector 0.149; the old names still load as deprecated aliases.

### The stores

- **Metrics arrive two ways on :8428**: VictoriaMetrics scrapes a
  Prometheus-compatible config that reproduces prometheus-community/prometheus
  29.19.0's default jobs (derived by rendering that chart, minus the
  blackbox `kubernetes-services` probe, the disabled pushgateway and the two
  `-slow` jobs no target opts into), and it
  receives the collector's remote-write on `/api/v1/write`, kept rather than
  OTLP because it changes nothing (same wire format and label semantics).
  `resource_to_telemetry_conversion` promotes `service.name` and
  `deployment.environment`, or an app's prod, next and staging series
  collide.
- **Scrape interval 1m**, not the chart's 15s: no panel reads finer, and each
  sample is a write to virtiofs; memory follows active series, not the rate.
- **No control-plane series.** k3s is one binary, so the kubelet's `/metrics`
  serves the apiserver's whole registry too: the apiserver job and the kubelet
  job stored the same 65k `apiserver_*`, `etcd_*`, `workqueue_*` and
  `rest_client_*` series twice, 80% of everything, read by no panel or rule.
  The apiserver job is gone and the kubelet job keeps `kubelet_*` alone. A multi-port Service annotated for scraping
  yields one target per port; a `keep_if_equal` rule (RE2 has no
  backreferences) dedups them, and its `if` guard is load-bearing:
  kube-state-metrics and node-exporter set no `prometheus.io/port`, and
  unguarded the rule drops both, that is both dashboards. Discovery is
  annotation-driven, so those releases install in any order.
- **Log streams are pinned** by a `VL-Stream-Fields` header on the pod-log
  exporter (namespace, pod, container, `app`): left open, every attribute
  qualifies, `k8s.pod.uid` and the node included, and stream cardinality is
  the one way to make a small log store miserable. App OTLP logs keep the
  default (a small, meaningful set), which is the only reason there are two
  exporters. Query language is LogsQL, not LogQL.
- **VictoriaTraces is accepted at 0.x**, knowingly: no production traffic
  depends on trace history, the one stream this cluster can afford to lose.
  The tolerance does not extend to the two 1.x stores. Its OTLP path is
  non-standard, so the exporter sets `traces_endpoint` (and `logs_endpoint`
  for VictoriaLogs), never `endpoint`, which would append `/v1/traces`.
  Grafana queries it through the Jaeger API at `/select/jaeger`, the
  documented, non-experimental surface.
- **Retention is by age only**: 90d logs (enforced, ingestion outside it is
  rejected), 30d traces, and no `-retention.maxDiskSpaceUsageBytes` on
  metrics, since a 2GB cap would silently clip the window to about 7d.
- **Each store mounts the PVC its `<name>-platform` release creates**, by
  `existingClaim: <name>-data`; that makes the StatefulSet drop its
  volumeClaimTemplate. Unset, it provisions a fresh volume and starts empty.
  The charts' fsGroup does not apply to hostPath volumes, so logs and traces
  run with `runAsUser: 0` to write a freshly created directory. Memory
  requests are small on purpose: the caches are budgeted from
  `-memory.allowedPercent` of the LIMIT.

### Grafana

- **The datasource uids `prometheus`, `loki` and `tempo` are frozen** though
  the types behind them changed: every dashboard and every app-shipped alert
  rule references a datasource by uid. `deleteDatasources` runs first on
  every provisioning to free those uids from the old rows (matched by name),
  and stays for a from-scratch Grafana on a restored `grafana.db`.
- **Alert rules live with the app that emits the metric**: the app chart
  renders `spec.alerts` into a ConfigMap labelled `grafana_alert=1`, which a
  sidecar picks up from any namespace. Nothing in this repo applies app alert
  rules; one that did would outlive the app it watches.
- VictoriaLogs is a plugin, signed and served from the Grafana catalog, so it
  installs with no unsigned-plugin allowlisting, at every pod start; metrics
  and traces need none.

### Langfuse gets one span per LLM call, from prod only

Added 2026-08-29 (6c77b9b, 338879f). The collector fans GenAI traces out to
Langfuse, where each ingested span is billable (Hobby: 50k a month). The AI
SDK emits three spans per call (`invoke_agent` as root, `agent_step`,
`chat`) in each of prod, next and staging, nine times a single generation
record: about 411k a month projected. A filter processor on
`traces/langfuse` forwards only prod's `chat` span, about 46k a month.

- **`chat`, not `invoke_agent`**: Langfuse reads model, token usage and cost
  from the inference span only; an `invoke_agent` observation lands as type
  AGENT with no model and zero tokens (verified through its API). The
  agent's name reaches `chat` through `@jterrazz/intelligence`'s middleware.
- **The filter drops what a condition matches.** `error_mode: ignore` keeps
  a span whose condition errors flowing; the `== nil` guard drops a span with
  no `gen_ai` attribute.
- **The exporter stays OTLP/HTTP**: Langfuse accepts no gRPC.

## Consequences

- Three stores of one family, one shipper, one config surface; `kubectl logs`
  is never the only copy of a pod's output.
- The single-node assumption is written into the collector's mode: a second
  node is a migration, not a scale-out.
- Flush intervals and other fsync trade-offs on these stores are
  [the storage record](008-storage-on-orbstack-spends-fsyncs-not-bytes.md)'s.
- Trace history may be lost outright on a VictoriaTraces upgrade; that is
  accepted.
- Node CPU is a ratio of summed mode rates, never `avg` over CPUs: OrbStack's
  hot-plugged vCPUs advance less than a second per second, so the average read
  38% busy when the node used 0.7 cores, about 10% (2026-10-25).
