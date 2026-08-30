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
  --set registry.username=… --set registry.password=…
```

(The exact invocation lives in `jterrazz-actions/actions/docker-deploy`; the
four `--set` values above are the contract this chart expects from CI —
everything else comes from `application.yaml`.)

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

### `spec.port`, `spec.replicas`

`port` is the container port. The Service is always `ClusterIP` on port 80
targeting it, so IngressRoutes never mention the app port. `PORT` is injected
into the container env automatically.

`replicas` is env-level (default 1). Note storage forces
`strategy: Recreate` — don't ask for >1 replica with a hostPath volume.

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

All three probes are `httpGet` on `health.path` at `spec.port`. The
startupProbe gates liveness and readiness, so a slow boot can't get SIGKILLed
mid-startup. Everything the chart does not name above — probe periods, liveness
and readiness failure thresholds — is left at the Kubernetes default.

### `spec.ingress` — a list, always

Each entry is `{ host, path?, public, stripPrefix?, redirectTo?, preservePath? }`.

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
* `path` defaults to `/`. Any other path also emits a `stripPrefix`
  middleware (legacy `/api` behaviour: the backend mounts routes at the
  root). Set `stripPrefix: false` on the entry to keep the prefix visible to
  the app — e.g. an MCP server registered at the literal `/mcp`.
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
  `issuers.yaml`. Private `*.internal.jterrazz.com` names resolve through a
  Pulumi-managed wildcard CNAME and need no DNS work.

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
  size: 2Gi            # required when `storage` is set
  mountPath: /data     # required when `storage` is set
```

Both keys are `required`: a missing one would otherwise render an unbindable
PV or an empty mountPath, diagnosable only at runtime.

Renders a `Retain` hostPath PV `<app>-<env>-data` at
`/var/lib/k8s-data/<app>-<env>` (`storageClassName: manual`,
`DirectoryOrCreate`) plus PVC `<app>-data` bound by `volumeName`, and flips
the Deployment to `strategy: Recreate`. A root `fix-permissions`
initContainer `chown -R 1000:1000`s the mount, because hostPath dirs are
created root-owned and the app container runs as 1000.

The PV carries **no `nodeAffinity`** — only app CI installs this chart and it
passes no node name. (The `service` chart, whose PVs Ansible creates, does pin
it.) If a second node is ever added, this needs restoring: an unpinned hostPath
PV can bind on a node whose disk holds an empty directory.

### `spec.configFiles`

Map of `filename -> file content`. Renders ConfigMap `<app>-config` and
mounts each entry read-only at `/app/<filename>` via `subPath`.

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

Always rendered, with no per-app knob. It allows: ingress from `kube-system`
(Traefik) on `spec.port`; ingress from any pod, in any namespace, carrying this
app's `clientLabel` **if** the app is itself a `platformServices` catalog target;
egress to DNS; and egress to the whole internet **except** RFC1918. Every other
in-cluster destination must come from `platformServices`, which opens both
directions at once.

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
| Service (ClusterIP :80)   | `<app>`                       | always                          |
| NetworkPolicy             | `<app>`                       | always                          |
| Secret (dockerconfigjson) | `registry-credentials`        | registry username + password set |
| Certificate               | `<app>-<host-slug>-tls`       | per unique ingress host         |
| IngressRoute              | `<app>-<idx>`                 | per ingress entry               |
| Middleware (stripPrefix)  | `<app>-<idx>-strip-prefix`    | entry has a non-`/` path, `stripPrefix` is not false, and it is not a redirect |
| Middleware (redirectRegex) | `<app>-<idx>-redirect`       | entry sets `redirectTo`          |
| InfisicalSecret           | `<app>-infisical`             | `spec.secrets.path` set         |
| ConfigMap                 | `<app>-config`                | `spec.configFiles` set          |
| ConfigMap                 | `<app>-dashboard-<name>`      | `spec.dashboards` set **and** env is prod |
| ConfigMap                 | `<app>-alerts`                | `spec.alerts` set **and** env is prod |
| PV / PVC                  | `<app>-<env>-data` / `<app>-data` | `spec.storage` set          |

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
# Render everything the CI fixture covers
helm template ci-test kubernetes/charts/app \
  -f kubernetes/charts/app/ci/test-values.yaml

# What CI actually runs (lint + render + schema-check both charts)
make lint
```

If you add a template branch, add a value that reaches it to
`ci/test-values.yaml` — an unreached branch is an unvalidated branch.
