# ADR-010: Every workload renders through two charts that share one library

**Status:** Accepted
**Date:** 2026-08-30

Written 2026-10-24 from the comments in `src/kubernetes/charts/`,
`src/kubernetes/services/openpanel/` and `roles/platform/tasks/publish-app-chart.yml`
that this record replaces (the platform-service rename, 076bc79; app chart
2.11, which absorbed OpenPanel and the registry; OpenPanel's in-cluster SSR
on 2026-09-19).

## Context

Apps deploy from their own repositories; the platform deploys from this one.
Both need the same objects (Deployments, IngressRoutes, Certificates,
hostPath PVs, InfisicalSecrets, NetworkPolicies) and the same vocabulary for
access and network peers. Hand-written manifests beside charts had drifted:
OpenPanel's six workloads and the registry were raw YAML sharing a ConfigMap,
a Secret created by an Ansible task, and a namespace-wide policy file.

## Decision

Three charts. `app` renders any workload, published to the registry and
pulled unversioned by every app's CI; `platform-service` renders a service's
storage, certificates, routes, secrets and policy (the `<name>-platform`
releases); `common` is a library both include, never installed, resolved as
an exact-version `file://` dependency (a mismatch fails `helm dependency
update` before anything renders) and bundled into the app chart's package.

### The app chart

- **Any workload, not just a Node service.** Chart 2.11 added `command` and
  `args`, exec and tcp probes, `storage.claimName` (a claim another release
  owns renders no PV or PVC, so the wrong `helm uninstall` cannot delete a
  bound claim), `storage.owner: ""` (no chown of a root-owned store),
  `servicePort`, `Recreate` without storage (one migration runner per
  database), no pull secret or `Always` policy for third-party images, and
  `network.isolated` (nothing reaches an unauthenticated datastore, and it
  dials nothing). No app repo reaches these branches, so the unit tests pin
  each one.
- **`values.yaml` owns every default**; templates read keys plainly. Probe
  defaults: a 5s timeout (1s is too tight for a Node app doing in-process
  work) and `startupFailureThreshold` 30 on the default 10s period, 300s of
  boot grace.
- **NODE_OPTIONS is derived from the memory REQUEST**, 75% of it, only at or
  above a 512Mi floor: below it, a 96MB cap for a 128Mi Next.js service
  starved SSR boot and crash-looped spwn.sh. An app's own NODE_OPTIONS wins
  verbatim. The quantity parser understands `Mi` and `Gi` only and otherwise
  leaves the value alone, since a misread unit would ship a 1000x-wrong limit.
- **Lists replace, maps merge** when an environment overrides `ingress`, so a
  staging environment never inherits half of prod's public hosts. `public`
  is required on every entry, never implied. One Certificate per host.
- **Cron jobs run the app's own container** with its env, secrets and
  mounts, never its Service selector labels (or Traefik routes live requests
  to a job).
- **Dashboards and alerts are prod-only**: dashboards would collide per
  folder, and alert rule uids are global, so a staging copy would overwrite
  the prod rule.
- **An environment typo renders an empty release**, and `helm upgrade` of an
  empty release deletes everything the previous revision owned. The test
  pins today's behaviour so turning it into a failure (chart 3.0) is a
  conscious, coordinated edit.
- **A template change bumps `version:` in the same commit.** The chart is
  pulled unversioned, and its one publisher, the platform deploy, skips a
  version already published rather than overwrite it (two template sets must
  never answer to one tag), so a forgotten bump publishes nothing, silently.
  The publish waits for the registry certificate, since DNS-01 issuance lags
  a fresh registry by a minute or two.

### Tests are the contract

Default values render nothing, so each chart's `ci/test-values.yaml` is the
validation contract and must exercise the widest surface; the app fixture's
`staging` environment is the datastore shape, the other arm of every switch.
Snapshot suites pin the whole rendered set byte for byte: they catch what no
targeted test looks at (a dropped label, a hostPath that moves, `Retain`
flipped to `Delete`). A failing snapshot is read before `helm unittest -u`
regenerates it, and that regenerated diff is what review reads. The app
snapshot's template list must name every template, or a new one renders
unwatched.

### OpenPanel, the case that widened it

Each OpenPanel workload is an app-chart release loading the shared
non-secret env from `config.yaml` first, each syncing its own copy of the
Infisical folder; `openpanel-platform` owns the storage and both
certificates, because op-api and op-dashboard answer on one hostname. The
private host routes `/api/*` to op-api and the rest to op-dashboard; the
public `analytics.jterrazz.com` carries `/api/track` alone, so the dashboard,
admin and export stay off the internet.

Until 2.2.1 the dashboard could only fetch its own public URL server-side,
which a pod cannot hairpin to, so it rested on three workarounds: the host in
`private_hostnames_via_traefik`, a Traefik egress rule (on 8443, the
containerPort, since a policy is evaluated after DNAT), and
`access: cluster-internal` routes. `API_URL_SSR` (honoured since 2.3.0) sends
those fetches to op-api's Service instead; the workarounds were retired on
2026-09-19 after `/onboarding` rendered with no `[tRPC SSR Error]`. If an
image ever drops it, all three come back together, never one at a time,
with `platform-analytics` admitted by `allow-traefik-ingress`.

Two operating rules come with it: `ALLOW_REGISTRATION` stays `"false"` on
op-api and op-dashboard (to add a user, flip both, invite, flip back, and
always keep a password login: OAuth-only plus signup-disabled can lock you
out, upstream #363); and the public smoke probe POSTs `{}` and expects 400,
since 2.3.0 validates the body before the client headers.

## Consequences

- A raw manifest is the exception, justified in
  [Develop](../guides/develop.md#workloads); today only cloudflared.
- Changing a `pathSuffix`, a PV name or a `<name>-platform` release name moves
  or orphans live data: the paths are byte-identical to what the pre-chart
  manifests produced, on purpose.
- An app chart change reaches production on the next unrelated app deploy,
  which is why the snapshots exist.
- Open: the op-* images document no uid, so they run without a uid pin
  (still dropping every capability), and op-api's enrichment egress cannot be
  narrowed until someone enumerates what it dials.
