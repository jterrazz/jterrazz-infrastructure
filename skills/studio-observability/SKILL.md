---
name: studio-observability
description: "Grafana dashboards and alert rules for jterrazz apps and the platform: the kinds, the derived identity, the shared infrastructure dashboards, LogsQL and PromQL against the Victoria stores. Use when creating, changing or reviewing a dashboard or an alert rule, in an app repository's .infrastructure/ or in studio-infrastructure's."
---

# @jterrazz Observability

Every repository ships its dashboards as `.infrastructure/dashboards/<kind>.json`
and its alert rules as `.infrastructure/alerts/<name>.yaml`; app CI hands them to
the `app` chart, which renders them into Grafana
(`grafana.internal.jterrazz.com`, tailnet only). This repository ships the
platform's the same way, from its own root. Instrumenting code (logs, spans,
metrics) is the `studio-telemetry` skill's, not this one's.

## The rules, in one breath

- **One dashboard, one audience, one question.** `service`: is it broken, and
  where (on call, hours). `business`: does it produce what it should (product,
  days). A subsystem only when an investigation keeps coming back to it. Never
  `overview`: the render refuses it. Value decides what stays, not a count.
- **Write panels, never identity.** The chart derives uid `<owner>-<kind>`, title
  `<owner> / <Kind>`, tags, folder and links from the owner and the file name,
  and overwrites whatever the file says.
- **Do not copy what `studio-infrastructure` already shows.** CPU, memory, restarts and
  a container's logs are `studio-infrastructure / Workload` (linked from every app
  dashboard); request rate, errors and latency of a routed app are
  `studio-infrastructure / Ingress`. An app dashboard holds what is its own: its
  domain, its dependencies, its runtime.
- **Top row first**: four to six numbers with thresholds; then symptoms before
  causes; a description and a unit on every panel; datasources by uid.
- **A rule has one of two levels**: `critical` when users are affected now or
  within hours without action, `warning` when it is degraded with no impact yet.
  Each has its Slack channel (`#alerts-critical`, `#alerts-warning`); nothing is
  `info`, since an alert asks for an action (ADR-028).
- **An alert says its impact and its value**: `summary` is one sentence a
  reader acts on, `value` renders the number with its unit and threshold
  (`{{ humanize $values.B.Value }} ms (alert over 1000 ms)`). Slack shows both;
  the relay `studio-alerts` turns the message green when it resolves (ADR-028).
- **An alert points at its panel** (`__dashboardUid__`, `__panelId__`), never sets
  `execErrState: OK`, and keeps a uid under 40 characters.

## Where to read

| Need                                                 | Read (in studio-infrastructure)                                                    |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Why the rules are what they are                      | `docs/decisions/027-a-dashboard-answers-one-audience-and-its-identity-is-derived.md` |
| The layout of `.infrastructure/`, and why            | `docs/decisions/025-dashboards-and-alerts-ship-as-files-in-dot-infrastructure.md`    |
| What an app repo owes                                | `docs/reference/deploy-contract.md`                                                  |
| `spec.dashboards` and `spec.alerts`                  | `src/kubernetes/charts/app/README.md`                                                |
| The derivation itself                                | `src/kubernetes/charts/common/templates/_dashboards.tpl`                             |
| The platform's own dashboards and rules, as examples | `.infrastructure/dashboards/`, `.infrastructure/alerts/platform.yaml`                |
| What each store holds and how to reach it            | `docs/reference/platform-services.md`                                                |

## Rendering, as reviewed on screen

- **Healthy is neutral.** A stat's healthy colour is transparent; only orange or
  red paint it, so a colour always means something.
- **A count is bars over a fixed interval** (`interval` on the panel); a sparse
  series never spans its gaps, so a missing point stays a gap, not a ramp.
- **A count stat ends in `or vector(0)`**: when its series vanishes, a stat shows
  its last value, and a pod that was Pending an hour ago reads as failing now.
- **Aggregate node series** (`max`, `sum by`): node-exporter's `instance` changes
  with its pod, and a bare selector shows each value twice.
- **Percentiles need buckets or exact samples.** Traefik's buckets run 50 ms to
  60 s; for a low-traffic app, take quantiles from its access lines instead.
- **A VictoriaLogs table holds numbers only**, labels turned into columns
  (`labelsToFields` keyed by `__name__`, then `merge`): a text value fails the
  query. A log panel shows one line per entry, no prettified JSON.
- **A log panel reads as messages.** Format the line at query time: a JSON
  line shows its `msg`, a Go bracket line its message and source, an access
  line its status, method, host, path and duration; the level becomes a field
  Grafana colours. The store keeps the raw line.
- **Every app dashboard marks its deploys**: an annotation on
  `kube_deployment_metadata_generation` changing. It holds no dashboard
  variable: Grafana 13 never runs an annotation query that does, so the markers
  cover all the app's environments and name the namespace.
- **Name things as people know them.** A route is its host and path, read from
  the access lines, never Traefik's `<app>-<index>` service label.
- **Check the render, not only the query**: open every dashboard and look at
  every panel; a query that returns data can still draw nothing useful.

## The stores

| Datasource uid     | Holds                                                          | Query in            |
| ------------------ | -------------------------------------------------------------- | ------------------- |
| `victoria-metrics` | kube-state-metrics, node-exporter, Traefik, apps' OTLP metrics | PromQL (MetricsQL)  |
| `victoria-logs`    | every pod's stdout and the apps' OTLP logs                     | LogsQL, never LogQL |
| `victoria-traces`  | the apps' spans                                                | Jaeger API          |

- A log stream is `{k8s.namespace.name="<app>-<env>"}`; OTLP logs also carry
  `service.name`. Stdout JSON keeps its level inside `_msg`
  (`severity_text` is `Unspecified`): filter with `i(error)`.
- In LogsQL a filter after a pipe needs `| filter`; a Go duration (`3.82s`) turns
  into seconds with `| math dur / 1e9 as seconds` once its padding is stripped.
- Traefik's `service` label is `<namespace>-<route>-<hash>@kubernetescrd`;
  `studio-infrastructure / Ingress` shows how to group it by app.
- Traefik's access lines are fields in `{k8s.namespace.name="kube-system"}`:
  filter on `KubernetesIngressRouteNamespace:="<app>-prod"`, read
  `RequestPath`, `DownstreamStatus`, `Duration` (nanoseconds). Fold ids into
  `:id` before grouping by path. An app with no telemetry of its own builds its
  `service` dashboard from them (see jterrazz-web's).

## Before calling a dashboard done

Run every query against the store with the variables filled in, and open the
dashboard: an empty panel is either a bug or a panel nobody needs. Preview an
app's dashboard without publishing anything by upgrading its release from the
local chart with `--reuse-values --set-file spec.dashboards.<kind>=<file>`.
