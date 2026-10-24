# ADR-011: Every namespace is default-deny; a service declares its own flows

**Status:** Proposed
**Date:** 2026-08-30

Written 2026-10-24 from the comments in `kubernetes/cluster/network-policies/`,
the charts' `network:` blocks and the service values that this record
replaces (the per-service split landed in 1814709).

## Context

k3s enforces NetworkPolicy, and several stores authenticate nothing:
VictoriaMetrics, VictoriaLogs and VictoriaTraces accept writes on always-on
paths, ClickHouse and Redis run without passwords (upstream design), and the
registry is the crown jewel behind htpasswd. Without policies any pod could
write junk into the telemetry stores or read them back. The policies used to
be one hand-written file per namespace naming every workload's flows, which
drifted from the services they described.

## Decision

Two layers. `kubernetes/cluster/network-policies/<ns>.yaml` holds only the
namespace baseline: default-deny both ways, allow-same-namespace, and the
namespace-wide egress every pod needs (DNS, from `namespaceSelector: {}`,
since a pod resolves before it knows who answers). Every rule that names one
workload is declared by that service, in the `network:` block of its values
file (platform-service) or its `spec.network` (app chart), in a peer
vocabulary defined once in `common/templates/_network-policy.tpl`.

The rules carry the traps already paid for:

- **Ports are pod ports.** A policy is evaluated after kube-proxy's DNAT, so
  a rule naming a Service port (Traefik's 443, Grafana's 80) applies to
  nothing, and default-deny drops the traffic with nothing logged.
- **hostNetwork clients are not pods.** cloudflared and the apiserver arrive
  as node addresses, matched only by an ipBlock; node-exporter, hostNetwork,
  cannot be protected by a policy at all. The kubelet's probes are
  node-sourced and never filtered, so a workload that admits nothing still
  passes them.
- **The apiserver is RFC1918 twice over**: pods dial 10.43.0.1:443, DNATed to
  the node's 6443. Apiserver egress therefore uses `anywhere` with no
  `except` and lists both ports (pre- or post-DNAT is a CNI detail). Tidying
  it into `0.0.0.0/0 except RFC1918` cuts the Infisical operator off from
  writing Secrets while its fetch keeps working, which reads as "auth broke",
  and makes every cert-manager process exit at startup. A running pod keeps
  working through conntrack, so the break shows only at the next recreate.
- **Store-facing flows stay namespace-local.** Every legitimate client of a
  telemetry store lives in its namespace, so allow-same-namespace carries
  them and the stores get no cross-namespace ingress; only the collector's
  two OTLP ports and Grafana's 3000 are reachable from outside. The
  collector's ingest is deliberately namespace-wide: NetworkPolicy has no
  globbing, app namespaces carry only their names, and its catalog entry has
  no client label yet. VictoriaMetrics' scrape egress is deliberately
  unrestricted: targets are discovered at runtime, a scraper only GETs
  `/metrics`, and each target namespace enforces its own ingress.
- **kube-system was the last namespace to get a policy**, because a wrong
  rule there takes the cluster down; it is ingress-only and every allow is a
  real path (DNS from everywhere, metrics-server from the host, the scrape
  ports, Traefik and klipper-lb as in [the Traefik record](003-traefiks-service-is-the-tailnet-gate.md)).
- **The Infisical operator gets no ingress at all**: its privilege flows
  through the apiserver, and it registers no webhook. cert-manager's webhook
  is the one admission hole (apiserver to 10250).

## Consequences

- A new service declares its flows beside its values, and a typo'd peer fails
  to render rather than producing a policy that admits nothing.
- An app declares its clients with `exposeTo`; the platform-services catalog
  stamps a client label the target selects on, so a new consumer needs no
  edit on the target.
- Open: the registry namespace keeps 443 egress until someone confirms
  distribution 3.x makes no outbound call; it is on the critical path of
  every deploy.
- Narrowing the collector's ingest means adding a client label to its catalog
  entry, landed only after every app has redeployed carrying it.
