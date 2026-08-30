# app chart — the `application.yaml` reference

Every application in the fleet deploys through this one chart. An app repo
owns a single file, `.infrastructure/application.yaml`, and the shared CI
workflow (`jterrazz/jterrazz-actions/.github/workflows/release-docker.yaml`)
runs, in essence:

```bash
helm upgrade --install <env>-<app> oci://registry.internal.jterrazz.com/charts/app \
  -n <env>-<app> \
  -f .infrastructure/application.yaml \
  --set environment=<env> \
  --set spec.image=registry.internal.jterrazz.com/<app>:<tag> \
  --set meta.repository=<owner>/<repo> \
  --set registry.username=… --set registry.password=…
```

(The exact invocation lives in `jterrazz-actions/actions/docker-deploy`; the
five `--set` values above are the contract this chart expects from CI —
everything else comes from `application.yaml`.)

`meta.repository` is `${{ github.repository }}`, stamped on the Deployment as
the `app.jterrazz.com/repository` annotation. It is how the infrastructure
repo's `make redeploy-apps` finds the fleet: it reads the annotation off every
app Deployment instead of holding a list of repos that goes stale. An app whose
CI has not run since the action gained that flag stamps nothing and is
**reported as missing**, never silently skipped.

So `application.yaml` **is** a Helm values file; the `apiVersion`/`kind`
header at the top is decorative (Helm ignores unknown top-level keys) and
kept only because it reads like a manifest.

The chart is pulled **unversioned**. There is no version pin anywhere in the
app CI, which means a chart push reaches every app on its next deploy — see
[Versioning](#versioning-and-publishing) before changing a template.

## Shape

```yaml
apiVersion: jterrazz.com/v1
kind: Application
metadata:
  name: my-app                  # required — names every object and the namespace
spec:
  port: 3000                    # container port; the Service always listens on 80
  resources:
    cpu: 100m
    memory: 256Mi
    memoryLimit: 512Mi          # optional; defaults to 2x the request
  health:
    path: /health
  env:
    LOG_LEVEL: info
  secrets:
    path: /my-app               # Infisical path -> InfisicalSecret
    env: [DATABASE_URL, API_TOKEN]
  ingress:                      # base default; an environment may replace it
    - host: my-app.jterrazz.com
      path: /
      public: true
  platformServices: [otel-collector]
  storage:
    size: 2Gi
    mountPath: /data
environments:
  prod:
    tag: main
    replicas: 1
  next:
    tag: next
    secretsEnv: prod            # this env's secrets live in Infisical env `prod`
    resources: { memory: 512Mi }
    ingress:
      - host: my-app-next.jterrazz.com
        path: /
        public: false
```

`kubernetes/charts/app/ci/test-values.yaml` is a working example that
exercises every branch below — CI renders it through `kubeconform` on every
PR. Start from it when you're unsure of a shape.

**Where the templates live.** The IngressRoute, Certificate, PV/PVC,
NetworkPolicy and InfisicalSecret this chart emits are rendered by
`kubernetes/charts/common`, a library chart shared with `platform-service` and
bundled into this chart's published `.tgz` — so an app repo still pulls one
unversioned chart and needs no new repository. What is written down there is
the *shape* and its constraints; what is written down here is what an app
controls. See [charts/common/README.md](../common/README.md).

## Merge semantics

Three layers, resolved per key: **environment override → `spec` → chart
default**. Whole-value replacement, not deep merge, with two exceptions:

| Key                     | Rule                                                             |
| ----------------------- | ---------------------------------------------------------------- |
| any map (`resources`, `env`, `secrets`, `health`, …) | Deep-merged per key — `resources: {memory: …}` in an env keeps the base `cpu`. **The environment wins** on a key collision. |
| any list (`ingress`, `platformServices`) | **Replaces** — an env's list fully supersedes `spec`'s, deliberately (a half-merged list of network surfaces is unreadable) |
| any scalar              | Env value if present, else `spec`, else default                   |

One resolver implements all of it: `app.merged` in `templates/_helpers.tpl`,
which is why an environment can override **any** `spec` key.

**Nothing renders for an environment that isn't declared.** Every template is
gated on `environment` existing as a key under `environments:` — a typo'd
`--set environment=prd` produces an empty release, not an error.

## Fields

### `spec.port`, `spec.servicePort`, `spec.replicas`

`port` is the container port. The Service is `ClusterIP` on port 80 targeting
it, so IngressRoutes never mention the app port. `PORT` is injected into the
container env automatically.

`servicePort` (default 80) is for a workload whose **clients dial it by name and
port** — a database in a connection string, an in-cluster HTTP API — because
that URL is written down somewhere this chart cannot see. Setting it moves the
Service port and every IngressRoute this chart renders along with it.

`replicas` is env-level (default 1). Note storage forces
`strategy: Recreate` — don't ask for >1 replica with a hostPath volume.

### `spec.command`, `spec.args`, `spec.strategy`

`command` and `args` override the image's entrypoint, verbatim; unset, the
image decides. No app in the fleet sets either.

`strategy` is derived and rarely written: **Recreate whenever storage is
mounted**, because every volume this chart mounts is an RWO hostPath and two
writers on one is the trap the datastores exist to avoid; the Kubernetes
default otherwise. Set it explicitly only for a workload that must not run
twice for a reason storage cannot express — `op-api` runs its database
migrations on boot, so a rolling update would put two migration runners on one
database.

### `spec.resources`

```yaml
resources:
  cpu: 100m           # request only; no CPU limit is ever set
  memory: 256Mi       # request
  memoryLimit: 1Gi    # optional; default = 2x request (Mi/Gi aware)
```

Only memory is limited. `memoryLimit` defaults to double the request, always
emitted in `Mi` (a `1Gi` request yields `2048Mi` — identical quantity); a
non-`Mi`/`Gi` request passes through unchanged.

**`NODE_OPTIONS` auto-injection**: for apps requesting **>= 512Mi**, the
chart sets `NODE_OPTIONS=--max-old-space-size=<75% of the request, in MiB>`.
Below that floor it injects **nothing**, and an app that sets its own
`NODE_OPTIONS` always wins. The floor is load-bearing: without a cap V8 sizes
its heap off the (2x) cgroup limit and drifts toward it, which matters for a
768Mi API but starves a ~128Mi Next.js service's SSR boot into a crash-loop.
Harmless on non-Node runtimes — the variable is ignored.

### `spec.health`

```yaml
health:
  path: /health                 # default
  timeoutSeconds: 5             # all three probes (k8s's 1s default is too tight)
  startupFailureThreshold: 30   # x the k8s 10s period = 300s of boot grace
```

All three probes share one action, `httpGet` on `health.path` at `spec.port`.
The startupProbe gates liveness and readiness, so a slow boot can't get
SIGKILLed mid-startup. Everything the chart does not name above — probe periods,
liveness and readiness failure thresholds — is left at the Kubernetes default.

Two alternatives exist for a server that does not speak HTTP; the first one set
wins (`exec`, then `tcp`, then `path`):

```yaml
health:
  exec: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
health:
  tcp: true          # tcpSocket on spec.port
```

`tcp` is not a lazier `exec`: mongod's own client is a Node REPL whose cold
start alone exceeds the probe timeout, so an exec probe crash-loops a perfectly
healthy database on the liveness kill.

### `spec.ingress` — a list, always

Each entry is
`{ host, path?, public, access?, stripPrefix?, tlsSecret?, redirectTo?, preservePath?, smoke? }`.

```yaml
ingress:
  - host: signews.jterrazz.com
    path: /api
    public: true              # via cloudflared; no middleware
  - host: signews.internal.jterrazz.com
    path: /
    public: false             # tailnet-only: private-access middleware attached
```

* `public` is **required** per entry — the render fails without it rather
  than silently defaulting a network-visibility decision.
* The single-object form was removed in chart 1.17.0; a non-list fails with
  an explicit message.
* `access: private | cluster-internal | public` is the same decision as
  `public:` in `platform-service`'s three-value vocabulary, and exists for the
  one answer a boolean cannot give: **cluster-internal**, i.e. tailnet humans
  *plus* the cluster's own pods, for a route something inside the cluster must
  also reach (OpenPanel's dashboard SSRs against its own public URL). Set one or
  the other, never both; `public:` stays the everyday spelling.
* `path` defaults to `/`. Any other path also emits a `stripPrefix`
  middleware (legacy `/api` behaviour: the backend mounts routes at the
  root). Set `stripPrefix: false` on the entry to keep the prefix visible to
  the app — e.g. an MCP server registered at the literal `/mcp` — or to a
  **string** to strip something other than the route's own path: OpenPanel's
  ingest is routed on `/api/track` and its backend serves `/track`, so it
  strips `/api`.
* `tlsSecret` names an existing TLS Secret and suppresses the `Certificate`
  this entry would otherwise render. For a hostname **two releases** answer on:
  neither can own its certificate without a second one being issued for the
  same name, so the service owns it (`certificates:` in its `service.yaml`) and
  both routes name it.
* `redirectTo` turns the entry into a **redirect-only host**: it answers on
  `host` and 301s to the given absolute `https://` URL, never reaching the app.
  The path is carried over by default (`preservePath: true`), which is what a
  canonical-host redirect needs — dropping it would break every deep link that
  ever pointed at the old host. Set `preservePath: false` to send every request
  to one fixed page. Combining `redirectTo` with `path` is a render error: a
  redirect answers for the whole host, so the path would be silently ignored.

  ```yaml
  ingress:
    - host: www.jterrazz.com          # canonical, serves the app
      public: true
    - host: jterrazz.com              # apex -> www, path preserved
      public: true
      redirectTo: https://www.jterrazz.com
    - host: blog.jterrazz.com         # legacy subdomain -> one fixed page
      public: true
      redirectTo: https://www.jterrazz.com/articles
      preservePath: false
  ```

  A redirect host still needs its own `Certificate` and its own Public Hostname
  on the Cloudflare tunnel — TLS terminates before the redirect is served.
* One `Certificate` per **unique host** (`<app>-<host-slug>-tls`, DNS-01 via
  the `letsencrypt-production` ClusterIssuer); one `IngressRoute` per
  **entry** (`<app>-<idx>`), so two entries can share a host.
* Public hostnames still need a Public Hostname route in the Cloudflare Zero
  Trust dashboard, and a new zone must be added to cert-manager's
  `issuers.yaml`. Private `*.internal.jterrazz.com` names resolve through one
  hand-made wildcard CNAME and need no DNS work.

#### `smoke:` — what the probe should get back

`scripts/smoke.sh` in the infrastructure repo lists every IngressRoute in the
cluster and probes what these annotations say. **You almost never write this
block**: the chart already knows where the route lives and where the app says
it is healthy, so it derives the contract per entry.

| Entry | Probes | Expects |
| --- | --- | --- |
| `path: /` (or no path) | `spec.health.path` | `200` |
| `path: /api` (stripPrefix on, the default) | `/api` + `spec.health.path` | `200` |
| `path: /mcp` with `stripPrefix: false` | **nothing** — opted out | — |
| `redirectTo: …` | `/` | `301`, **and** the `Location` the middleware sends |

The `stripPrefix: false` case opts out because the app routes everything under
that prefix itself: nothing here can know which URL below it answers, and a
guessed one would fail on a perfectly healthy route. Every skipped and every
unannotated route is printed by `smoke.sh`, so a gap is visible rather than
silent.

Override only when the derived answer is wrong:

```yaml
ingress:
  - host: my-app.jterrazz.com          # derived: GET /health -> 200
    public: true
  - host: my-app.jterrazz.com
    path: /mcp
    public: true
    stripPrefix: false
    smoke: { path: /mcp/ping, expect: "200" }   # opts a literal-prefix route back in
  - host: legacy.jterrazz.com
    public: false
    smoke: false                                # never probed
```

`expect` is a comma-separated list of accepted codes; keep it as narrow as the
surface genuinely allows, and never put `000` or a 5xx in it — the entire value
of the probe is that a dead service cannot read as "fine". `method:` sets the
verb for a route that answers only one — OpenPanel's ingest is POST-only, and a
GET there 404s whether the backend is healthy or not.

A route whose `stripPrefix` is neither its own path nor false also opts out by
default: nothing can derive the external health URL when the stripped prefix and
the routed one differ. That is what the ingest route's explicit block above
opts back in.

### `spec.secrets` and `secretsEnv`

```yaml
secrets:
  path: /my-app            # Infisical secretsPath (project `jterrazz`)
  env: [DATABASE_URL]      # keys projected into the container as secretKeyRef
```

Renders an `InfisicalSecret` (`<app>-infisical`) that syncs into Secret
`<app>-secrets` in the app's namespace at the operator's own resync interval,
using the shared `infisical-credentials` in `platform-secrets`. The Infisical **env slug**
defaults to the deploy environment name; an environment that has no matching
Infisical env sets `secretsEnv:` to borrow another one (that's what `next`
does — `secretsEnv: prod`).

### `spec.env`

Plain map of literal env vars, merged base + environment. Always quoted on
render, so numbers and booleans arrive as strings. Also auto-injected unless
the app sets them itself: `PORT`, `OTEL_SERVICE_NAME` (= app name),
`OTEL_RESOURCE_ATTRIBUTES` (`deployment.environment=<env>,deployment.environment.name=<env>`).

### `spec.storage`

```yaml
storage:
  size: 2Gi            # required unless claimName is set
  mountPath: /data     # always required
  claimName: openpanel-postgres   # optional: mount a claim another release owns
  owner: "70:70"       # optional: the uid:gid to chown to (default 1000:1000)
```

`size` and `mountPath` are `required`: a missing one would otherwise render an
unbindable PV or an empty mountPath, diagnosable only at runtime.

**`claimName` means the volume belongs to someone else** — a `<svc>-platform`
release, whose `storage:` map created it and whose release name is the identity
of that live data. This chart then only *mounts* it and renders no PV/PVC of its
own (so `size` is unused): two releases owning one volume is how a
`helm uninstall` of the wrong one deletes a bound claim.

**`owner`** is the `uid:gid` the `fix-permissions` initContainer hands the
volume to — the image's own user (`70:70` for alpine Postgres, `101:101` for
ClickHouse, `999:1000` for Redis), not always 1000. Set it to the empty string
to skip the initContainer entirely, for an image that runs as root over a
root-owned volume; chowning a 10Gi blob store on every pod start is both slow
and wrong.

Renders a `Retain` hostPath PV `<app>-<env>-data` at
`/var/lib/k8s-data/<app>-<env>` (`storageClassName: manual`,
`DirectoryOrCreate`) plus PVC `<app>-data` bound by `volumeName`, and flips
the Deployment to `strategy: Recreate`. A root `fix-permissions`
initContainer `chown -R 1000:1000`s the mount, because hostPath dirs are
created root-owned and the app container runs as 1000.

The PV carries **no `nodeAffinity`** — only app CI installs this chart and it
passes no node name. (`platform-service`, whose PVs Ansible creates, does pin
it.) If a second node is ever added, this needs restoring: an unpinned hostPath
PV can bind on a node whose disk holds an empty directory.

### `spec.configFiles`

Map of `filename -> file content`. Renders ConfigMap `<app>-config` and
mounts each entry read-only at `/app/<filename>` via `subPath`.

An entry may instead be a `{ path, content }` map, which puts the same file
where the **image** wants it rather than under `/app`:

```yaml
configFiles:
  op-config.xml:
    path: /etc/clickhouse-server/config.d/op-config.xml
    content: |
      <clickhouse>…</clickhouse>
```

### `spec.secretMounts`

```yaml
secretMounts:
  - secretName: registry-auth      # an EXISTING Secret; this chart creates none
    mountPath: /auth
```

An existing Secret mounted read-only as files, for an image that reads a
credential from disk rather than from the environment — the registry's bcrypt
htpasswd is the one user. For a credential that arrives as env vars, use
`spec.secrets`.

### `spec.dashboards`

Map of `name -> Grafana dashboard JSON`. Renders a ConfigMap labelled
`grafana_dashboard: "1"` and annotated `grafana_folder: <app>`, which
Grafana's sidecar picks up. **Only rendered when `environment == prod`** —
one dashboard per app, not one per environment.

App CI fills this map for you: `jterrazz-actions/actions/docker-deploy` scans
`.infrastructure/dashboards/*.json` and appends
`--set-file spec.dashboards.<basename>=<file>` per file. Dashboards therefore
never appear in `application.yaml` — dropping a JSON file in that directory is
the whole workflow.

### `spec.alerts`

Map of `name -> Grafana alert provisioning YAML` (an `apiVersion: 1` /
`groups:` document — the [unified alerting provisioning
format](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/)).
Renders **one** ConfigMap `<app>-alerts` labelled `grafana_alert: "1"`, with
one data key `<name>.yaml` per entry, picked up by Grafana's `sidecar.alerts`
(`searchNamespace: ALL`, so the app's own namespace is fine).

```yaml
spec:
    alerts:
        signews-api: |
            apiVersion: 1
            groups:
              - orgId: 1
                name: signews-api
                folder: signews-api
                interval: 1m
                rules:
                  - uid: signews-api-eventloop-lag
                    ...
```

**Only rendered when `environment == prod`**, and for a harder reason than
dashboards: a rule `uid:` is global in Grafana, so a staging copy of a rule
would not sit beside the prod one — it would provision *over* it.

Two deliberate differences from `spec.dashboards`:

- **No `grafana_folder` annotation.** The alerts sidecar has no
  `folderAnnotation` configured; each group carries its own `folder:` inside
  the payload.
- **One ConfigMap for all entries**, not one per entry, so an app's rule set is
  replaced atomically — a renamed rule file cannot leave an orphan ConfigMap
  behind still provisioning a rule nobody maintains.

Unlike dashboards, **CI does not populate this map from a directory**:
`docker-deploy`'s `--set-file` loop is hardcoded to `dashboards/*.json`, so
alerts are written inline in `.infrastructure/application.yaml` today. The map
shape is identical to what `--set-file` produces, so generalising that loop to
also scan `alerts/*.yaml` is a jterrazz-actions-only change — this chart needs
no edit when it happens.

### `spec.platformServices`

Opt-in wiring to in-cluster platform services. The catalog is the single
source of truth in `templates/_helpers.tpl` (`app.platformCatalog`):

| Name                   | Injects env                                                                        | Opens egress to                     | Client label |
| ---------------------- | ---------------------------------------------------------------------------------- | ----------------------------------- | ------------ |
| `otel-collector`       | `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.platform-telemetry:4318`          | `platform-telemetry` :4317, :4318   | —            |
| `gateway-intelligence` | `GATEWAY_INTELLIGENCE_BASE_URL=http://gateway-intelligence.prod-gateway-intelligence.svc.cluster.local/v1` | `prod-gateway-intelligence` :8317 | `platform-client.jterrazz.com/gateway-intelligence` |

Declaring a name wires the whole bundle at once:

1. **env injection** into the consumer (a user-set var of the same name
   always wins),
2. an **egress NetworkPolicy** hole to the catalog namespace on the **pod**
   ports (never the Service port),
3. a **pod label** on the consumer, when the entry has a `clientLabel` — and
   the target service, being itself a catalog entry, renders an ingress rule
   selecting that label. A new consumer therefore needs **zero** edits on the
   target.

Ports are pinned per namespace, so `gateway-intelligence` resolves to the
`prod-` namespace regardless of which environment the consumer runs in.

An unknown name **hard-fails the render** with the valid list. Telemetry is
opt-in: an app that doesn't declare `otel-collector` gets no OTLP endpoint —
previously it was an unconditional default that was inert anyway, because
nothing opened the egress hole.

Env names are derived from the service name (`GATEWAY_INTELLIGENCE_BASE_URL`);
`OTEL_EXPORTER_OTLP_ENDPOINT` is the one exception, because the OTel SDK owns
that contract.

### NetworkPolicy

Always rendered. Derived, so an app configures nothing: ingress from
`kube-system` (Traefik) on `spec.port`; ingress from any pod, in any namespace,
carrying this app's `clientLabel` **if** the app is itself a `platformServices`
catalog target; egress to DNS; and egress to the whole internet **except**
RFC1918. Every other in-cluster destination comes from `platformServices`, which
opens both directions at once — or, when nothing in the catalog fits, from
`spec.network` below.

The policy itself — and the peer vocabulary it is written in, and the two traps
it exists to absorb (ports are POD ports; hostNetwork clients are not pods) —
comes from `kubernetes/charts/common`. A platform service declares the same
shapes by hand in its `network:` block.

### `spec.network`

```yaml
spec:
  network:
    exposeTo: [namespace:platform-ai]
    egress:
      - to: namespace:platform-analytics
        ports: [5432]
    isolated: false
```

`exposeTo` names extra clients allowed to reach this app on `spec.port`, and
`egress` extra destinations it may dial; both are appended to the rules the
chart already writes. Each peer is a `kubernetes/charts/common` NetworkPolicy
peer — `namespace:<ns>`, `pods:<key>=<value>`,
`any-namespace-pods:<key>=<value>`, `traefik`, `any-namespace`, `internet`,
`anywhere`; an unknown one **hard-fails the render** with the valid list. Ports
are **pod** ports, never Service ports.

Reach for `exposeTo` only when the client **cannot** opt in through
`platformServices`, which is the mechanism that needs no edit here at all: a
third-party chart renders its pods and cannot stamp the catalog's client label.
That is exactly LibreChat, and `gateway-intelligence` declaring
`exposeTo: [namespace:platform-ai]` is what replaced a hand-written
NetworkPolicy in the infrastructure repo's `cluster/network-policies/`.

**`isolated: true` drops the two DERIVED rules** — Traefik ingress on
`spec.port` and egress to the whole internet — leaving DNS plus exactly what
`exposeTo` and `egress` declare. No app sets it. It is what a datastore is: a
workload whose entire security model is that nothing reaches it and it dials
nothing, because it has no password of its own (`op-postgres`, `op-redis`,
`op-clickhouse`, `librechat-mongodb`).

### `spec.image` — and what the registry decides

`spec.image` is set by CI (`registry.internal.jterrazz.com/<app>:<tag>`), and
falls back to `<registry>/<app>:latest`. Whether the image lives on **our**
registry decides two more things, with no knob for either:

* the `registry-credentials` `imagePullSecret` is attached only then — the
  credential authenticates that registry alone, and naming a Secret that is not
  in the namespace earns a `FailedToRetrieveImagePullSecret` warning on every
  pod start;
* `imagePullPolicy: Always` is set only then — our tags (`main`, `next`) are
  mutable, so `IfNotPresent` would keep serving whatever the node cached first.
  A third-party image keeps Kubernetes' default, which is what its pinned tag
  deserves and what keeps a pod restart off Docker Hub's anonymous pull quota.

### `spec.securityContext` / `spec.runAsRoot`

Containers get hardened defaults: `runAsNonRoot: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
`seccompProfile: RuntimeDefault`; the pod gets `runAsUser/runAsGroup/fsGroup:
1000`. `readOnlyRootFilesystem` is deliberately **not** in the defaults —
every app here writes caches (`.next/cache`, `/tmp`) at runtime.

```yaml
spec:
  securityContext:              # merged OVER the defaults, per key
    capabilities:
      drop: ["ALL"]
      add: ["NET_BIND_SERVICE"]
  runAsRoot: true               # escape hatch: drops runAsNonRoot AND the
                                # pod-level uid/gid/fsGroup block entirely
```

Use `securityContext` to give one capability back; `runAsRoot` only for an
image that genuinely cannot run as 1000. Neither should be the first thing
you reach for — fix the image.

## What gets rendered

For a declared environment, namespace `<environment>-<app>`:

| Object                    | Name                          | Condition                       |
| ------------------------- | ----------------------------- | ------------------------------- |
| Deployment                | `<app>`                       | always                          |
| Service (ClusterIP `servicePort`) | `<app>`               | always                          |
| NetworkPolicy             | `<app>`                       | always                          |
| Secret (dockerconfigjson) | `registry-credentials`        | registry username + password set |
| Certificate               | `<app>-<host-slug>-tls`       | per unique ingress host that does not name a `tlsSecret` |
| IngressRoute              | `<app>-<idx>`                 | per ingress entry               |
| Middleware (stripPrefix)  | `<app>-<idx>-strip-prefix`    | entry has a non-`/` path, `stripPrefix` is not false, and it is not a redirect |
| Middleware (redirectRegex) | `<app>-<idx>-redirect`       | entry sets `redirectTo`          |
| InfisicalSecret           | `<app>-infisical`             | `spec.secrets.path` set         |
| ConfigMap                 | `<app>-config`                | `spec.configFiles` set          |
| ConfigMap                 | `<app>-dashboard-<name>`      | `spec.dashboards` set **and** env is prod |
| ConfigMap                 | `<app>-alerts`                | `spec.alerts` set **and** env is prod |
| PV / PVC                  | `<app>-<env>-data` / `<app>-data` | `spec.storage` set **without** a `claimName` |

## Versioning and publishing

`kubernetes/charts/app/Chart.yaml` carries the chart `version:`. Push to
`main` touching `kubernetes/charts/app/**` and
`.github/workflows/publish-chart.yaml` packages and pushes it to
`oci://registry.internal.jterrazz.com/charts/app`.

Two rules follow from apps pulling the chart **unversioned**:

1. **Bump `version:` in the same commit as any template change.** The workflow
   `helm pull`s the version first and, if it resolves, publishes **nothing**
   (a green no-op with a `::notice::`, not a failure — a routine push right
   after `make deploy` would otherwise go red on an already-current registry).
   The guard's only job is to prevent an *overwrite*, so two template sets can
   never answer to the same tag. The corollary is that a forgotten bump ships
   nothing at all, quietly.
2. **Every behavioural change reaches every app on its next deploy** — there
   is no per-app opt-in window. Additive and defaulted changes only, unless
   you're prepared to redeploy the fleet. (`ansible/roles/platform/tasks/publish-app-chart.yml`
   publishes the same chart from the host during a fresh-cluster build,
   because until it exists in the registry no app can deploy at all. It carries
   the same guard: already-published is a skip, not a failure.)

## Working on the chart

```bash
# Resolve the `common` library dependency first — nothing is vendored, and
# helm refuses to render a chart whose declared dependency is not in charts/.
helm dependency update kubernetes/charts/app

# Render everything the CI fixture covers
helm template ci-test kubernetes/charts/app \
  -f kubernetes/charts/app/ci/test-values.yaml

# What CI actually runs (lint + render + schema-check both charts)
make lint
```

If you add a template branch, add a value that reaches it to
`ci/test-values.yaml` — an unreached branch is an unvalidated branch.
