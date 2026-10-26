# app chart: the `application.yaml` reference

Every application in the fleet deploys through this one chart. An app repo
owns a single file, `.infrastructure/application.yaml`, and the shared CI
workflow (`jterrazz/studio-actions/.github/workflows/release-docker.yaml`)
runs, in essence:

```bash
helm upgrade --install <app>-<env> oci://registry.internal.jterrazz.com/charts/app \
  -n <app>-<env> \
  -f .infrastructure/application.yaml \
  --set environment=<env> \
  --set spec.image=registry.internal.jterrazz.com/<app>:<tag> \
  --set meta.repository=<owner>/<repo>
```

(The exact invocation lives in `studio-actions/actions/docker-deploy`; the
three `--set` values above are the contract this chart expects from CI;
everything else comes from `application.yaml`. No credential is among them: the
registry pull secret is synced from Infisical, see
[`spec.image`](#specimage-and-what-the-registry-decides).)

(A shared app, [`scope: shared`](#scope-shared-one-release-for-every-environment),
installs `<app>` into namespace `<app>` with `--set environment=shared`.)

`meta.repository` is `${{ github.repository }}`, stamped on the Deployment as
the `studio.jterrazz.com/repository` annotation. It is how the infrastructure
repo's `make redeploy-apps` finds the fleet: it reads the annotation off every
app Deployment instead of holding a list of repos that goes stale. An app whose
CI has not run since the action gained that flag stamps nothing and is
**reported as missing**, never silently skipped.

So `application.yaml` **is** a Helm values file, and `values.schema.json`
judges it strictly: draft-07, `additionalProperties: false` at every level, so
a typo or a retired key (`secretsEnv`, `platformServices`, an environment's
`tag`) fails `helm upgrade` instead of being ignored. The header
is pinned too: `apiVersion: studio.jterrazz.com/v1`, `kind: Application`
([ADR-029](../../../../docs/decisions/029-an-app-is-declared-strictly-reads-its-own-secrets-and-is-reached-by-consent.md)).

The chart is pulled **unversioned**. There is no version pin anywhere in the
app CI, which means a chart push reaches every app on its next deploy, so read
[Versioning](#versioning-and-publishing) before changing a template.

## Shape

```yaml
apiVersion: studio.jterrazz.com/v1
kind: Application
metadata:
  name: my-app # required; names every object, the Infisical folder, and CI's namespace <name>-<env>
spec:
  port: 3000 # container port; the Service listens on servicePort (80)
  resources:
    cpu: 100m
    memory: 256Mi
    memoryLimit: 512Mi # optional; defaults to 2x the request

  health:
    path: /health
  env:
    LOG_LEVEL: info
  secrets:
    env: [DATABASE_URL, API_TOKEN] # keys of Infisical's /my-app, in this environment
  ingress: # base default; an environment may replace it
    - host: my-app.jterrazz.com
      path: /
      public: true
  uses: [telemetry] # capabilities consumed; the provider must serve this app
  serves: [another-app] # apps whose namespaces may reach spec.port, or [all]
  storage:
    size: 2Gi
    mountPath: /data

environments:
  prod:
    branch: main # app CI deploys this environment on a push to main
    replicas: 1
  next:
    branch: next # ...and this one on a version tag
    resources: { memory: 512Mi }
    ingress:
      - host: my-app-next.staging.jterrazz.com
        path: /
        public: false
```

`src/kubernetes/charts/app/ci/test-values.yaml` is a working example that
exercises every branch below; CI renders it through `kubeconform` on every
PR. Start from it when you're unsure of a shape.

**Where the templates live.** The IngressRoute, PV/PVC,
NetworkPolicy and InfisicalSecret this chart emits are rendered by
`src/kubernetes/charts/common`, a library chart shared with `platform` and
bundled into this chart's published `.tgz`, so an app repo still pulls one
unversioned chart and needs no new repository. What is written down there is
the _shape_ and its constraints; what is written down here is what an app
controls. See [charts/common/README.md](../common/README.md).

## Merge semantics

Three layers, resolved per key: **the environment override, then `spec`, then the
chart default**. Whole-value replacement, not deep merge, with two exceptions:

| Key                                                    | Rule                                                                                                                         |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| any map (`resources`, `env`, `secrets`, `health`, ...) | Deep-merged per key: `resources: {memory: ...}` in an env keeps the base `cpu`. **The environment wins** on a key collision. |
| any list (`ingress`, `uses`, `serves`)                 | **Replaces**: an env's list fully supersedes `spec`'s, deliberately (a half-merged list of network surfaces is unreadable)   |
| any scalar                                             | Env value if present, else `spec`, else default                                                                              |

One resolver implements all of it: `app.merged` in `templates/_helpers.tpl`,
which is why an environment can override **any** `spec` key.

**Nothing renders for an environment that isn't declared.** Every template is
gated on `environment` existing as a key under `environments:` (or being
`shared`, for a shared app), and a typo'd `--set environment=prd` produces an
empty release, not an error.

`environments.<env>.branch` is read by app CI alone
(`studio-actions/.github/workflows/release-docker.yaml`): `main` deploys the
environment on a push to main, `next` on a version tag, anything else is an
image tag a manual dispatch pins.

## `scope: shared`: one release for every environment

An app every environment calls (studio-intelligence, the model gateway;
studio-alerts, Grafana's relay) is not per-environment. It declares, at the
root:

```yaml
scope: shared
branch: main # which push deploys it; a shared app has no `environments`
spec: ...
```

CI then deploys one release, environment `shared`, into namespace `<app>`. Its
volume is `<app>-data` at `/var/lib/k8s-data/<app>`, it reads Infisical's
`prod` env (it serves prod too), its telemetry says
`deployment.environment=shared`, and it carries the dashboards and alert rules
a prod release would, their workload link on namespace `<app>`. The schema
refuses `environments` beside `scope: shared`, and a root `branch` without it.

## Fields

### `spec.port`, `spec.servicePort`, `spec.replicas`

`port` is the container port. The Service is `ClusterIP` on port 80 targeting
it, so IngressRoutes never mention the app port. `PORT` is injected into the
container env automatically.

`servicePort` (default 80) is for a workload whose **clients dial it by name and
port** (a database in a connection string, an in-cluster HTTP API), because
that URL is written down somewhere this chart cannot see. Setting it moves the
Service port and every IngressRoute this chart renders along with it.

`replicas` is env-level (default 1). Note storage forces
`strategy: Recreate`, so don't ask for >1 replica with a hostPath volume.

### `spec.command`, `spec.args`, `spec.strategy`

`command` and `args` override the image's entrypoint, verbatim; unset, the
image decides. No app in the fleet sets either.

`strategy` is derived and rarely written: **Recreate whenever storage is
mounted**, because every volume this chart mounts is an RWO hostPath and two
writers on one is the trap the datastores exist to avoid; the Kubernetes
default otherwise. Set it explicitly only for a workload that must not run
twice for a reason storage cannot express: `op-api` runs its database
migrations on boot, so a rolling update would put two migration runners on one
database.

### `spec.resources`

```yaml
resources:
  cpu: 100m # request only; no CPU limit is ever set
  memory: 256Mi # request
  memoryLimit: 1Gi # optional; default = 2x request (Mi/Gi aware)
```

Only memory is limited. `memoryLimit` defaults to double the request, always
emitted in `Mi` (a `1Gi` request yields `2048Mi`, the identical quantity); a
non-`Mi`/`Gi` request passes through unchanged.

**`NODE_OPTIONS` auto-injection**: for apps requesting **>= 512Mi**, the
chart sets `NODE_OPTIONS=--max-old-space-size=<75% of the request, in MiB>`.
Below that floor it injects **nothing**, and an app that sets its own
`NODE_OPTIONS` always wins. The floor is load-bearing: without a cap V8 sizes
its heap off the (2x) cgroup limit and drifts toward it, which matters for a
768Mi API but starves a ~128Mi Next.js service's SSR boot into a crash-loop.
Harmless on non-Node runtimes, where the variable is ignored.

### `spec.health`

```yaml
health:
  path: /health # default
```

All three probes share one action, `httpGet` on `health.path` at `spec.port`,
with a 5s timeout (Kubernetes' 1s is too tight for a Node app doing background
work). The startupProbe gates liveness and readiness and allows 30 failures,
300s of boot grace, so a slow boot can't get SIGKILLed mid-startup. Everything
else (periods, the other thresholds) is the Kubernetes default.

`health.livenessPath` splits that action. Set, the startup and liveness probes
GET it while readiness keeps `health.path`: the restart decision then asks only
whether the process answers, and a failing readiness route pulls the pod from
the Service without restarting it. Unset, all three use `health.path`. It
applies to the `httpGet` action only.

```yaml
health:
  path: /v1/models # readiness: the route clients call
  livenessPath: /healthz # startup + liveness: the process answers
```

A server that does not speak HTTP is probed with `exec`, which wins over `path`:

```yaml
health:
  exec: ["sh", "-c", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
```

### `spec.ingress`: a list, always

Each entry is
`{ host, path?, public, stripPrefix?, redirectTo?, preservePath?, smoke? }`.

```yaml
ingress:
  - host: signews.jterrazz.com
    path: /api
    public: true # the tunnel entrypoint; external-dns writes its record
  - host: signews.internal.jterrazz.com
    path: /
    public: false # the websecure entrypoint, which only the tailnet reaches
```

- `public` is **required** per entry: the render fails without it rather
  than silently defaulting a network-visibility decision.
- A single object instead of a list fails with an explicit message.
- `path` defaults to `/`. Any other path also emits a `stripPrefix`
  middleware (legacy `/api` behaviour: the backend mounts routes at the
  root). Set `stripPrefix: false` on the entry to keep the prefix visible to
  the app (an MCP server registered at the literal `/mcp`, say), or to a
  **string** to strip something other than the route's own path: OpenPanel's
  ingest is routed on `/api/track` and its backend serves `/track`, so it
  strips `/api`.
- `redirectTo` turns the entry into a **redirect-only host**: it answers on
  `host` and 301s to the given absolute `https://` URL, never reaching the app.
  The path is carried over by default (`preservePath: true`), which is what a
  canonical-host redirect needs: dropping it would break every deep link that
  ever pointed at the old host. Set `preservePath: false` to send every request
  to one fixed page. Combining `redirectTo` with `path` is a render error: a
  redirect answers for the whole host, so the path would be silently ignored.

  ```yaml
  ingress:
    - host: www.jterrazz.com # canonical, serves the app
      public: true
    - host: jterrazz.com # apex -> www, path preserved
      public: true
      redirectTo: https://www.jterrazz.com
    - host: blog.jterrazz.com # legacy subdomain -> one fixed page
      public: true
      redirectTo: https://www.jterrazz.com/articles
      preservePath: false
  ```

  A redirect host is a public route like any other: external-dns writes its
  record.

- **No certificate per host.** A private route is served the private zone's
  wildcard by Traefik's default TLSStore, and a public route's TLS ends at the
  Cloudflare edge, so the chart renders none
  ([ADR-001](../../../../docs/decisions/001-certificates-are-issued-over-dns-01.md)).
  One `IngressRoute` per **entry** (`<app>-<idx>`), so two entries can share a
  host.
- A public host needs nothing outside its entry: it lands on Traefik's
  `tunnel` entrypoint, and external-dns writes its proxied CNAME in whichever
  of our zones holds it
  ([ADR-026](../../../../docs/decisions/026-a-public-route-is-published-by-its-ingressroute.md)).
  A private name sits under one of the two wildcard zones,
  `<product>.internal.jterrazz.com` or `<name>.staging.jterrazz.com`, and
  needs nothing but `public: false`. Staging is always private.

#### `smoke:` names what the probe should get back

The platform contract in the infrastructure repo (`specs/specs/api`) lists
every IngressRoute in the cluster and probes what these annotations say. **You almost never write this
block**: the chart already knows where the route lives and where the app says
it is healthy, so it derives the contract per entry.

| Entry                                      | Probes                      | Expects                                            |
| ------------------------------------------ | --------------------------- | -------------------------------------------------- |
| `path: /` (or no path)                     | `spec.health.path`          | `200`                                              |
| `path: /api` (stripPrefix on, the default) | `/api` + `spec.health.path` | `200`                                              |
| `path: /mcp` with `stripPrefix: false`     | **nothing**, opted out      | nothing                                            |
| `redirectTo: ...`                          | `/`                         | `301`, **and** the `Location` the middleware sends |

The `stripPrefix: false` case opts out because the app routes everything under
that prefix itself: nothing here can know which URL below it answers, and a
guessed one would fail on a perfectly healthy route. Every unannotated route is
probed with the fallback and named `fallback` in its test's title, so a gap is
visible rather than silent.

Override only when the derived answer is wrong:

```yaml
ingress:
  - host: my-app.jterrazz.com # derived: GET /health -> 200
    public: true
  - host: my-app.jterrazz.com
    path: /mcp
    public: true
    stripPrefix: false
    smoke: { path: /mcp/ping, expect: "200" } # opts a literal-prefix route back in
  - host: legacy.jterrazz.com
    public: false
    smoke: false # never probed
```

`expect` is a comma-separated list of accepted codes; keep it as narrow as the
surface genuinely allows, and never put `000` or a 5xx in it: the entire value
of the probe is that a dead service cannot read as "fine". `method:` sets the
verb for a route that answers only one; OpenPanel's ingest is POST-only, and a
GET there 404s whether the backend is healthy or not.

A route whose `stripPrefix` is neither its own path nor false also opts out by
default: nothing can derive the external health URL when the stripped prefix and
the routed one differ. OpenPanel's ingest route is one, and opts back in with
an explicit block:

```yaml
- host: analytics.jterrazz.com
  path: /api/track
  public: true
  stripPrefix: /api # routed on /api/track, served on /track
  smoke: { method: POST, path: /api/track, expect: "400" } # an empty body is refused
```

### `spec.secrets`

```yaml
secrets:
  env: [DATABASE_URL] # keys projected into the container as secretKeyRef
```

Renders an `InfisicalSecret` (`<app>-infisical`) that syncs folder `/<app>`
(project `studio-infrastructure`) into Secret `<app>-secrets` in the app's
namespace at the operator's own resync interval, using the shared
`infisical-credentials` in `platform-secrets`. The folder is always the app's
name and the **env slug** always the release's environment (`prod` for a
shared app): nothing in `application.yaml` names another, and the cluster's
ownership policy refuses any other pair, so an environment never reads
another's secrets. An environment with no keys in Infisical yet gets them
there, not borrowed.

`secrets.path` overrides the folder, and is for **platform releases only**:
an app's CI identity is refused anything but `/<app>` by the admission policy,
while a platform release is deployed by the admin identity, which the policy
never judges. OpenPanel's four releases share `/studio-infrastructure/openpanel`
this way.

### `spec.env`

Plain map of literal env vars, merged base + environment. Always quoted on
render, so numbers and booleans arrive as strings. Also auto-injected unless
the app sets them itself: `PORT`, `OTEL_SERVICE_NAME` (= app name),
`OTEL_RESOURCE_ATTRIBUTES` (`deployment.environment=<env>,deployment.environment.name=<env>`).

### Labels and the graceful stop

Every object carries `app.kubernetes.io/{name,instance,managed-by}` and
`studio.jterrazz.com/environment`; the pods are selected by
`app.kubernetes.io/name` and `studio.jterrazz.com/environment`, an immutable
selector, so changing it is a Deployment deleted and recreated. Every key the
estate invents is under `studio.jterrazz.com/`.

Each container sleeps 5s in `preStop` before its SIGTERM, inside the default
30s grace period: Traefik keeps routing to a terminating pod until its
endpoint is removed, and the sleep covers that window.

### `spec.storage`

```yaml
storage:
  size: 2Gi # required unless claimName is set
  mountPath: /data # always required
  claimName: openpanel-postgres # optional: mount a claim another release owns
```

`size` and `mountPath` are `required`: a missing one would otherwise render an
unbindable PV or an empty mountPath, diagnosable only at runtime.

**`claimName` means the volume belongs to someone else**: a `<svc>-platform`
release, whose `storage:` map created it and whose release name is the identity
of that live data. This chart then only _mounts_ it and renders no PV/PVC of its
own (so `size` is unused): two releases owning one volume is how a
`helm uninstall` of the wrong one deletes a bound claim.

Renders a `Retain` hostPath PV `<app>-<env>-data` at
`/var/lib/k8s-data/<app>-<env>` (`<app>-data` at `/var/lib/k8s-data/<app>`
for a shared app) (`storageClassName: manual`,
`DirectoryOrCreate`) plus PVC `<app>-data` bound by `volumeName`, and flips
the Deployment to `strategy: Recreate`. No init container chowns it: on
OrbStack's virtiofs ownership is not enforced and `chown` changes nothing, so
every image writes as its own user (ADR-008). A target with a real filesystem
would need that chown back.

The PV carries **no `nodeAffinity`**: only app CI installs this chart and it
passes no node name. (`platform`, whose PVs Ansible creates, does pin
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
      <clickhouse>...</clickhouse>
```

### `spec.secretMounts`

```yaml
secretMounts:
  - secretName: registry-auth # an EXISTING Secret; this chart creates none
    mountPath: /auth
```

An existing Secret mounted read-only as files, for an image that reads a
credential from disk rather than from the environment; the registry's bcrypt
htpasswd is the one user. For a credential that arrives as env vars, use
`spec.secrets`.

### `spec.dashboards`

Map of `kind -> Grafana dashboard JSON`. Renders a ConfigMap
`<app>-dashboard-<kind>` labelled `grafana_dashboard: "1"` and annotated
`grafana_folder: <app>`, which Grafana's sidecar picks up. **Only rendered
in prod, or in a shared app's one release**: one dashboard per app, not one per environment.

The kind is `service`, `business` or a subsystem's name, in kebab-case;
`overview`, `misc`, `general` and `main` fail the render. `common.dashboards`
overwrites the identity: uid `<app>-<kind>`, title `<app> / <Kind>`, tags
`[<app>, <kind>]`, a link to each of the app's dashboards and one to
`studio-infrastructure / Workload` on `<app>-prod` (`<app>` for a shared app)
([ADR-027](../../../../docs/decisions/027-a-dashboard-answers-one-audience-and-its-identity-is-derived.md)).

App CI fills this map for you: `studio-actions/actions/docker-deploy` scans
`.infrastructure/dashboards/*.json` and appends
`--set-file spec.dashboards.<basename>=<file>` per file. Dashboards therefore
never appear in `application.yaml`; dropping a JSON file in that directory is
the whole workflow.

### `spec.alerts`

Map of `name -> Grafana alert provisioning YAML` (an `apiVersion: 1` /
`groups:` document, in the [unified alerting provisioning
format](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/)).
Renders **one** ConfigMap `<app>-alerts` labelled `grafana_alert: "1"`, with
one data key `<name>.yaml` per entry, picked up by Grafana's `sidecar.alerts`
(`searchNamespace: ALL`, so the app's own namespace is fine).

App CI fills this map the way it fills dashboards: `docker-deploy` scans
`.infrastructure/alerts/*.yaml` and appends `--set-file spec.alerts.<basename>=<file>`
per file, so a rule group is one file beside the dashboards, never inline in
`application.yaml`. The platform ships its own rules in the same layout, under
`.infrastructure/alerts/` at the root of the infrastructure repo
([ADR-025](../../../../docs/decisions/025-dashboards-and-alerts-ship-as-files-in-dot-infrastructure.md)).

```yaml
# .infrastructure/alerts/signews-api.yaml
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

A query names its datasource by the store's uid: `victoria-metrics`,
`victoria-logs` (LogsQL, never LogQL) or `victoria-traces`.

**Only rendered in prod (or a shared app's one release)**, and for a harder reason than
dashboards: a rule `uid:` is global in Grafana, so a staging copy of a rule
would not sit beside the prod one; it would provision _over_ it.

**The rules are checked in every environment, and a bad one fails the
render.** Grafana reloads every app's rule files as one set, so one file it
refuses stops alerting for the whole cluster, not for one app. The chart
refuses first: each payload must be an `apiVersion: 1` document with a `groups`
list, each group must name its `name` and `folder`, and each rule must carry a
`uid` of at most 40 characters from `[a-zA-Z0-9_-]`, unique across the app's
entries, and no rule may set `execErrState: OK`, which keeps a broken query
green forever (unset, Grafana's `Error` fires on it). The same check covers the
platform's rules (`common.alerts`). The payload itself passes through byte for
byte.

Two deliberate differences from `spec.dashboards`:

- **No `grafana_folder` annotation.** The alerts sidecar has no
  `folderAnnotation` configured; each group carries its own `folder:` inside
  the payload.
- **One ConfigMap for all entries**, not one per entry, so an app's rule set is
  replaced atomically: a renamed rule file cannot leave an orphan ConfigMap
  behind still provisioning a rule nobody maintains.

**Removing a rule takes one more step.** Grafana keeps a provisioned rule in
its database when the file that declared it disappears, so a rule dropped from
`spec.alerts` (or an app removed) stays, and with `noDataState: Alerting` it
fires on its own. Delete it once with a `deleteRules` file, then remove the
ConfigMap:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: { name: delete-rule, namespace: platform-telemetry, labels: { grafana_alert: "1" } }
data:
  delete.yaml: |
    apiVersion: 1
    deleteRules: [{ orgId: 1, uid: <rule uid> }]
YAML
sleep 60 && kubectl -n platform-telemetry delete configmap delete-rule
```

### `spec.uses` and `spec.serves`: access is a consent from both sides

A consumer names the capabilities it **uses**; the catalog,
`app.capabilities` in `templates/_helpers.tpl`, is the one place that says
where each lives:

| Capability     | Injects env                                                                                        | Opens egress to                   |
| -------------- | -------------------------------------------------------------------------------------------------- | --------------------------------- |
| `telemetry`    | `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.platform-telemetry:4318`                        | `platform-telemetry` :4317, :4318 |
| `intelligence` | `STUDIO_INTELLIGENCE_BASE_URL=http://studio-intelligence.studio-intelligence.svc.cluster.local/v1` | `studio-intelligence` :8317       |

`uses` injects the env (a user-set var of the same name always wins) and an
egress rule to the provider's namespace on its **pod** ports. It grants
**nothing**: the provider admits its consumers itself, with **serves**:

```yaml
spec:
  serves: [signews-api] # namespaces labelled studio.jterrazz.com/app=signews-api
  # serves: [all]       # every namespace labelled studio.jterrazz.com/tier=app
```

which renders one ingress rule on `spec.port` from the namespaces whose
`studio.jterrazz.com/app` label is in the list (every environment of those
apps), or every app namespace for `all`. Those labels sit on the namespace,
which only its owning repository's deploy may set, never on a pod, which any
workload could stamp. The collector, a platform service, serves every app
namespace on its own (its `service.yaml`).

An unknown capability **hard-fails the render** with the valid list.
Telemetry is opt-in: an app that does not use it gets no OTLP endpoint. Env
names are the contract the client reads: `STUDIO_INTELLIGENCE_BASE_URL` is what
a consumer passes to `@jterrazz/intelligence`, `OTEL_EXPORTER_OTLP_ENDPOINT`
the OTel SDK's. studio-intelligence enforces no API key, so its `serves` and its
private-only route are its whole boundary; its consumers pass the non-secret
placeholder `gateway-noauth` the OpenAI and Anthropic SDKs require.

### NetworkPolicy

Always rendered. Derived, so an app configures nothing: ingress from
`kube-system` (Traefik) on `spec.port`; ingress from the namespaces it
`serves`; egress to DNS; egress to the whole internet **except** RFC1918; and
egress to the provider of each capability it `uses`. Every other in-cluster
destination comes from `spec.network` below.

The policy itself, with the peer vocabulary it is written in and the two traps
it exists to absorb (ports are POD ports; hostNetwork clients are not pods),
comes from `src/kubernetes/charts/common`. A platform service declares the same
shapes by hand in its `network:` block.

### `spec.network`

```yaml
spec:
  network:
    exposeTo: [namespace:platform-telemetry]
    egress:
      - to: namespace:platform-analytics
        ports: [5432]
    isolated: false
```

`exposeTo` names extra clients allowed to reach this app on `spec.port`, and
`egress` extra destinations it may dial; both are appended to the rules the
chart already writes. Each peer is a `src/kubernetes/charts/common` NetworkPolicy
peer: `namespace:<ns>`, `namespace-label:<key>=<value>[,<value>...]`,
`pods:<key>=<value>`, `traefik`, `any-namespace`, `internet`, `anywhere`; an
unknown one **hard-fails the render** with the valid list. Ports
are **pod** ports, never Service ports.

Reach for `exposeTo` only when the client is not an app `serves` can name: a
platform namespace, such as Grafana's `platform-telemetry` calling
studio-alerts. Declaring the client's namespace on the TARGET is what replaces
a hand-written NetworkPolicy in the infrastructure repo's `cluster` chart: a
rule there would be granting access to an app that repo does not deploy.

**`isolated: true` drops the two DERIVED rules** (Traefik ingress on
`spec.port` and egress to the whole internet), leaving DNS plus exactly what
`exposeTo` and `egress` declare. No app sets it. It is what a datastore is: a
workload whose entire security model is that nothing reaches it and it dials
nothing, because it has no password of its own (`op-postgres`, `op-redis`,
`op-clickhouse`).

### `spec.image`, and what the registry decides

`spec.image` is required. App CI sets it to the digest it built
(`registry.internal.jterrazz.com/<app>@sha256:...`), and Kubernetes' default
`IfNotPresent` pulls a digest once, so a pod start never waits on the registry.
Whether the image lives on **our** registry decides one more thing, with no
knob:

- the `registry-credentials` `imagePullSecret` is attached only then: the
  credential authenticates that registry alone, and naming a Secret that is not
  in the namespace earns a `FailedToRetrieveImagePullSecret` warning on every
  pod start. That Secret is not built from values: the chart renders a second
  `InfisicalSecret` (`<app>-registry-infisical`) and the operator syncs the
  registry's read-only account (`REGISTRY_PULL_USERNAME` /
  `REGISTRY_PULL_PASSWORD`, project `studio-ci`) into a
  `kubernetes.io/dockerconfigjson`. The password is never a chart value, so it
  never lands in a release Secret or on a runner's argv, and rotating it needs
  no app deploy.

### `spec.securityContext` / `spec.runAsRoot`

Containers get hardened defaults: `runAsNonRoot: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
`seccompProfile: RuntimeDefault`; the pod gets `runAsUser/runAsGroup/fsGroup:
1000`. `readOnlyRootFilesystem` is deliberately **not** in the defaults:
every app here writes caches (`.next/cache`, `/tmp`) at runtime.

```yaml
spec:
  securityContext: # merged OVER the defaults, per key
    capabilities:
      drop: ["ALL"]
      add: ["NET_BIND_SERVICE"]
  runAsRoot:
    true # escape hatch: drops runAsNonRoot AND the
    # pod-level uid/gid/fsGroup block entirely
```

Use `securityContext` to give one capability back; `runAsRoot` only for an
image that genuinely cannot run as 1000. Neither should be the first thing
you reach for; fix the image.

## What gets rendered

For a declared environment, namespace `<app>-<environment>` (ADR-023), or
`<app>` for a shared app:

| Object                            | Name                              | Condition                                                                             |
| --------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------- |
| Deployment                        | `<app>`                           | always                                                                                |
| Service (ClusterIP `servicePort`) | `<app>`                           | always                                                                                |
| NetworkPolicy                     | `<app>`                           | always                                                                                |
| IngressRoute                      | `<app>-<idx>`                     | per ingress entry                                                                     |
| Middleware (stripPrefix)          | `<app>-<idx>-strip-prefix`        | entry has a non-`/` path, `stripPrefix` is not false, and it is not a redirect        |
| Middleware (redirectRegex)        | `<app>-<idx>-redirect`            | entry sets `redirectTo`                                                               |
| InfisicalSecret                   | `<app>-infisical`                 | `spec.secrets.env` lists a key                                                        |
| InfisicalSecret                   | `<app>-registry-infisical`        | `spec.image` is on our registry; it syncs the `registry-credentials` dockerconfigjson |
| ConfigMap                         | `<app>-config`                    | `spec.configFiles` set                                                                |
| ConfigMap                         | `<app>-dashboard-<name>`          | `spec.dashboards` set **and** env is prod or shared                                   |
| ConfigMap                         | `<app>-alerts`                    | `spec.alerts` set **and** env is prod or shared                                       |
| PV / PVC                          | `<app>-<env>-data` / `<app>-data` | `spec.storage` set **without** a `claimName` (PV `<app>-data` when shared)            |

## Versioning and publishing

`src/kubernetes/charts/app/Chart.yaml` carries the chart `version:`. A push to
`main` touching `src/kubernetes/charts/**` runs a platform deploy, whose last step
(`src/ansible/roles/publish`) packages and pushes it
to `oci://registry.internal.jterrazz.com/charts/app`.

Two rules follow from apps pulling the chart **unversioned**:

1. **Bump `version:` in the same commit as any template change.** The publisher
   looks the version up first and, if it exists, publishes **nothing**, a green
   no-op, so two template sets never answer to one tag. A forgotten bump ships
   nothing at all, quietly.
2. **Every behavioural change reaches every app on its next deploy**: there
   is no per-app opt-in window. Additive and defaulted changes only, unless
   you're prepared to redeploy the fleet. On a fresh cluster the same step
   is what makes the chart exist at all; until then no app can deploy.

## Working on the chart

```bash
helm dependency update src/kubernetes/charts/app   # resolves ../common; nothing is vendored
helm template ci-test src/kubernetes/charts/app -f src/kubernetes/charts/app/ci/test-values.yaml
make check
```

If you add a template branch, add a value that reaches it to
`ci/test-values.yaml`: an unreached branch is an unvalidated branch.
