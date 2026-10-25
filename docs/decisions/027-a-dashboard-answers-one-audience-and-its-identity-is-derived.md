# ADR-027: A dashboard answers one audience, and its identity is derived

**Status:** Proposed
**Date:** 2026-10-25

## Context

Five dashboards existed, written by hand with no shared rule: titles
`Kubernetes - Cluster Overview` and `Signews API - Business Metrics`, uids
`infra-k8s-overview` and `signews-api-reliability`, tags `signews` on one and
`signews-api` on the next. signews-api's `overview` and `reliability` were
both technical, so neither was the one to open. Every app copied the same CPU,
memory and restart panels. Grafana folders outlived what they held: a
`registry` folder stayed after its only alert went with distribution. The one
written rule lived in the workstation's corpus (jterrazz-os
`home/_all/context/observability.md`), far from the chart that renders the
dashboards, and nothing enforced it.

What the stores hold shaped the rest. Only signews-api emits metrics, and no
app emits HTTP server metrics; Traefik counted requests per entrypoint only;
the model gateway is an upstream Go binary that writes access lines and
nothing else.

## Decision

- **One dashboard, one audience and one question.** `service` asks whether it
  works and where it breaks, for whoever is on call, over hours. `business`
  asks whether it produces what it should, for whoever owns the product, over
  days. A subsystem earns its own dashboard when an investigation keeps
  returning to it (`pipeline`), never because a dashboard grew long. A panel
  nobody reads is deleted, not moved.
- **The file name is the kind, and the identity is derived from it.**
  `common.dashboards` stamps uid `<owner>-<kind>`, title `<owner> / <Kind>`,
  tags `[<owner>, <kind>]`, folder `<owner>`, a link to every dashboard of the
  owner and, for an app, a link to `infrastructure / Workload` on its prod
  namespace. The owner is the app's name, or `infrastructure` for what this
  repository runs: node, cluster and platform services together, like the
  repository. Whatever the file says about its own identity is overwritten, and
  a catch-all kind (`overview`, `misc`, `general`, `main`) fails the render.
- **What every workload shares lives once, in `infrastructure`.** `Node` (the
  machine), `Cluster` (what is broken, where capacity goes), `Workload` (one
  container's resources against its requests and limits, restarts and logs,
  for any namespace) and `Ingress` (rate, errors and latency per app, from
  Traefik with `addServicesLabels`, so every routed app has RED signals without
  instrumenting anything). An app's dashboards hold only what is its own.
- **Traefik writes one access line per request**, JSON with host, path, status,
  duration and route, and the collector lifts its fields so LogsQL filters on
  them. No client field, no header and no query string reach the store: the
  client address is the visitor's real IP once Traefik trusts cloudflared's
  `X-Forwarded-For`, and a query string can carry a token. It is the per-path
  signal apps without instrumentation lack: jterrazz-web, signews-web,
  spwn-web and jterrazz-console have nothing else, so their `service`
  dashboards are their routes, paths and latency read from it.
- **One reading order.** A top row of four to six numbers with thresholds, then
  symptoms before causes; a description and a unit on every panel; datasources
  by uid. Metrics are preferred, logs read with LogsQL where the app has
  nothing else.
- **An alert points at its panel.** A rule carries `__dashboardUid__` and
  `__panelId__`, so a notification opens the graph that explains it, and it
  lives in its owner's folder like the dashboards.

## Consequences

- An author writes panels and a file name; nothing else can drift. The rule is
  enforced where every repository's dashboards pass, whatever its language,
  rather than by a linter only TypeScript repositories run.
- A call between pods never crosses Traefik, so `Ingress` does not see an app
  calling the gateway; the gateway's own dashboard reads its access lines.
- The first ten minutes of access lines carried client IPs; the 96 lines were
  purged from VictoriaLogs the same day.
- The gateway has no `business` dashboard: its lines carry neither the model
  nor the tokens. That waits on its usage API or the callers' traces.
- Renaming a file renames the uid, and a link or alert that named the old uid
  breaks; the platform contract does not yet check them.
