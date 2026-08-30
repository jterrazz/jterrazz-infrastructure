# LibreChat (private AI chat UI)

Private chat UI on **`chat.internal.jterrazz.com`** (Tailscale-only), namespace
**`platform-ai`**. Backed by the in-cluster AI gateway
(`gateway-intelligence`) rather than any provider API directly, so no
provider key is ever stored here.

Two Helm releases in `kubernetes/helmfile.yaml.gotmpl` — `librechat-platform`
(storage, certificate, ingress) and `librechat` (the app) — plus the standalone
`mongodb.yaml`, applied by `ansible/roles/platform/tasks/raw-manifests.yml`
between the two helmfile passes.

## Architecture

```
 me on tailnet ──► chat.internal.jterrazz.com (private IngressRoute, private-access) ──► Traefik
                                                                                  │
                                                                                  ▼
                                                                         librechat (:3080)
                                                                            │        │
                          mongodb://librechat-mongodb:27017/LibreChat ◄─────┘        │
                                  (standalone mongo:7.0, PVC librechat-data)         │
                                                                                     ▼
                              http://gateway-intelligence.prod-gateway-intelligence
                                     .svc.cluster.local  (Service :80 → pod :8317)
```

- **Upstream chart, our datastore.** The official LibreChat chart is installed
  as-is, but every bundled datastore subchart is **off** — `mongodb`, `redis` and
  `meilisearch` are disabled in `helm.yaml`; `librechat-rag-api` is already off by
  chart default, so nothing sets it. The bundled MongoDB is a
  Bitnami subchart, deprecated upstream since 2025-09 and no longer pullable;
  it would also land on the default `local-path` StorageClass, which does not
  survive a repave. We run our own `mongo:7.0` Deployment instead
  (`mongodb.yaml`) on a `manual` hostPath PVC.
- **No Meilisearch** ⇒ `SEARCH: "false"` — conversation search is off.
- **Private-only for now**: `ALLOW_REGISTRATION: "false"` plus the
  `private-access` middleware. Going public means flipping `access: private`
  to `access: public` in `platform.yaml` and leaning on LibreChat's own auth.
- `fullnameOverride: librechat` — the IngressRoute in `platform.yaml` targets a
  Service literally named `librechat`, so the chart's fullname must match.
- **`ingress.enabled: false`** — the chart defaults it to **true** with the
  placeholder host `chat.example.com`, and k3s' Traefik serves Ingress objects as
  happily as IngressRoutes. So the default renders a second, middleware-free
  route to this Service, reachable on that Host header alone. Never remove the
  override; the real route is the IngressRoute the service chart renders.
- **NetworkPolicy**: `kubernetes/cluster/network-policies/platform-ai.yaml`. It
  is the substitute for MongoDB auth — mongod has none — so it admits :27017
  from the LibreChat pod and nothing else, and gives mongod no egress beyond DNS.

## Deployed versions (pinned)

| Component      | Version                                                     |
| -------------- | ----------------------------------------------------------- |
| Helm chart     | `oci://ghcr.io/danny-avila/librechat-chart/librechat` **2.0.7** (pinned on the `librechat` release in `kubernetes/helmfile.yaml.gotmpl`) |
| LibreChat app  | `registry.librechat.ai/danny-avila/librechat:v0.8.7`     |
| MongoDB        | `mongo:7.0`                                                  |
| (init) chown   | `busybox:1.38` (digest-pinned in `mongodb.yaml`)             |

The image tag is pinned **explicitly** rather than inherited from the chart's
`appVersion`: an empty tag means "whatever appVersion this chart revision
happens to carry", so the running image could change with no diff here.
`v0.8.7` is chart 2.0.7's own `appVersion`, written out here so a chart bump
cannot move the running image with no diff. Bump the two together.

MongoDB is pinned to the **7.0 minor**, not the floating `7`. A silent minor
jump rewrites on-disk feature-compatibility metadata, and mongod refuses to
start against files written by a newer release — a one-way door for hostPath
data. Bump deliberately, setting `featureCompatibilityVersion` around it.

The namespace itself is **not** declared here — `platform-ai` lives with every
other platform namespace in
`kubernetes/cluster/namespaces.yaml`.

Both workloads run hardened container `securityContext`s
(`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
`seccompProfile: RuntimeDefault`); mongod additionally pins uid/gid **999**,
paired with a root `fix-perms` initContainer that chowns the root-owned
hostPath dir — pinning the uid bypasses the mongo entrypoint's own chown.
Same pattern as the app chart and OpenPanel's datastores.

## Where the data lives

Both volumes come from the **service chart's named-volume storage map**
declared in `platform.yaml` — `uploads` used to be a hand-written
`uploads.yaml`, now deleted. Object names and hostPath paths are unchanged.

| PVC / PV            | Size | Path (`/var/lib/k8s-data/...`) | Holds                                    |
| ------------------- | ---- | ------------------------------ | ---------------------------------------- |
| `librechat-data`    | 3Gi  | `librechat/mongo`              | users, logins, chat history (mongod)     |
| `librechat-uploads` | 5Gi  | `librechat/uploads`            | user uploads + generated images          |

Both are `manual` hostPath PVs with `Retain` — **not** the default
`local-path` SC, which is wiped on a `pulumi destroy` repave.
`/var/lib/k8s-data` is a symlink to the Mac on OrbStack, so the data survives
pod restarts, `helm uninstall`, and VM destruction alike.

One directory per app (repo convention): both volumes nest under
`librechat/`. `librechat-uploads` is mounted twice from the same PVC via
`subPath`, so on disk:

```
librechat/uploads/uploads    ← /app/uploads
librechat/uploads/images     ← /app/client/public/images
```

The chart's own `imageVolume` stays disabled — we provide persistence
ourselves.

## Secrets & config

**Secrets** — Infisical `/jterrazz-infrastructure/librechat` (env `prod`),
synced by the Infisical operator (`secret.yaml`) into Secret
**`librechat-credentials-env`**. That name is **mandatory**: the chart wires
`envFrom` to it via `existingSecretName`, so anything else means `CREDS_KEY`,
`CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET` never reach the container.

| Key                  | Purpose                              |
| -------------------- | ------------------------------------ |
| `CREDS_KEY`          | 32-byte hex — credential encryption   |
| `CREDS_IV`           | 16-byte hex                           |
| `JWT_SECRET`         | random                                |
| `JWT_REFRESH_SECRET` | random                                |

There is **no gateway API key** — see below. `GATEWAY_API_KEY` was removed
from this folder.

**Non-secret config** lives in `helm.yaml`: `configEnv` (host, `MONGO_URI`,
registration/login flags, `ANTHROPIC_REVERSE_PROXY`) and
`configYamlContent`, which is the full `librechat.yaml` (endpoints, model
lists, modelSpecs, interface).

## Gateway wiring

Three things make LibreChat talk to `gateway-intelligence`, and each exists
for a specific reason:

1. **In-cluster Service URL, not `gateway-intelligence.internal.jterrazz.com`.** Both the custom
   endpoint's `baseURL` and `ANTHROPIC_REVERSE_PROXY` point at
   `http://gateway-intelligence.prod-gateway-intelligence.svc.cluster.local`
   (`/v1` suffix on the custom endpoint; bare host for the Anthropic one,
   because the Anthropic SDK appends `/v1/messages` itself). The public
   hostname resolves to the node's own tailnet IP and a pod **cannot hairpin**
   to the node's ServiceLB — the connection just times out. Service port 80 →
   pod port 8317.

2. **`kubernetes/cluster/network-policies/prod-gateway-intelligence.yaml` —
   an additive NetworkPolicy.** The gateway is an
   app-chart workload; since chart 2.0 its ingress admits any pod stamped
   `platform-client.jterrazz.com/gateway-intelligence: "true"`, which
   consumers get by declaring `spec.platformServices`. LibreChat is not an
   app-chart workload (its pod labels come from the upstream chart), so it
   can't easily stamp that label. NetworkPolicies are additive, so a small
   policy in the **gateway's** namespace grants `platform-ai` → 8317 without
   touching the gateway's chart. It lives here, not in the gateway repo,
   because it exists solely for LibreChat. *(Deferred alternative: set the
   client label via the upstream chart's pod labels and delete this file.)*

   The `prod-gateway-intelligence` namespace is pre-declared in
   `kubernetes/cluster/namespaces.yaml` (applied by `cluster-manifests.yml`, which
   runs before this policy) — on a fresh cluster the gateway app doesn't exist
   yet, and Helm adopts the pre-created namespace when its CI deploys later.

3. **`ANTHROPIC_API_KEY: "gateway-noauth"` is a non-secret placeholder.**
   CLIProxyAPI (the gateway) runs with `api-keys: []`, which leaves its access
   provider unregistered and the auth middleware allowing everything. The
   security boundary is **NetworkPolicy + private-only ingress**, not a bearer
   token. The Anthropic/OpenAI SDKs merely require a non-empty string, so any
   constant works — there is no gateway API key in Infisical, anywhere, and
   there is nothing to rotate here.

The **native `anthropic` endpoint** (not just the custom OpenAI-shaped one)
is what unlocks Claude's server-side `web_search`; the Agent framework's own
web_search would be orchestrated/SearXNG instead, which we don't run.

## Common operations

```bash
export KUBECONFIG=./kubeconfig.yaml
kubectl get pods -n platform-ai
kubectl get certificate -n platform-ai
kubectl logs -n platform-ai deploy/librechat --tail=50
kubectl logs -n platform-ai deploy/librechat-mongodb --tail=50

# Mongo shell (no auth — namespace-local only)
kubectl exec -it -n platform-ai deploy/librechat-mongodb -- \
  mongosh LibreChat --quiet --eval 'db.users.countDocuments()'

# Re-deploy just this service
cd ansible && ansible-playbook playbooks/platform.yml \
  -i inventories/laptop.yml -e "@<extra-vars>" --tags librechat
```

Backup: the two hostPath dirs on the Mac are the whole state. For a
consistent Mongo dump instead of a file copy:

```bash
kubectl exec -n platform-ai deploy/librechat-mongodb -- \
  mongodump --db LibreChat --archive > librechat-$(date +%F).archive
```

### Upgrading the default model

There is **no auto-"latest Opus"**: model IDs are opaque and the gateway
exposes no `-latest` alias. To move the default agent to a newer Opus, edit
the `opus-full` modelSpec in `helm.yaml` and bump **all three** of `model`,
`label` and `description` (there's a boxed reminder in the file), then push to
main — `deploy-platform.yaml` redeploys on any change under
`kubernetes/services/**`.

Add the new model ID to both `endpoints.custom[0].models.default` and
`endpoints.anthropic.models` while you're there, so it's also reachable from
the raw model menu.

It's server-side config, so it applies to **every user automatically** — no
per-user migration. Existing conversations keep their original model; new
chats use the new default.

*(If this ever needs to be centralized across all gateway clients instead,
CLIProxyAPI supports a `claude-opus-latest` alias in
`gateway-intelligence/config.yaml` — deferred.)*

## Gotchas

- **`librechat-credentials-env` must exist before the app starts.** The
  Ansible task applies `secret.yaml` and then polls for the operator to
  materialize the Secret (30 × 5s) before installing the chart. Without it
  the first boot comes up with no `CREDS_KEY` and every stored credential
  fails to decrypt.
- **Mongo probes are TCP, not `mongosh --eval`.** mongosh is a heavy Node REPL
  whose cold start alone exceeds the 1s default probe timeout; the exec probe
  timed out on ~every check and produced 57 liveness kills / a crash loop (the
  storage engine also needs ~3s to open on the Mac hostPath). A listening
  27017 means mongod is accepting connections.
- **Mongo has no auth.** It listens only inside `platform-ai` and the cluster
  has no other tenant on it. Add auth (and a Secret-injected `MONGO_URI`)
  before this is anything but private.
- **`strategy: Recreate` on mongod** — never run two writers against one RWO
  hostPath volume.
- **Changing `pathSuffix` or a PV name in `platform.yaml` moves live data.**
  The paths are byte-identical to what the pre-2.0 manifests produced, on
  purpose. `hostPath.type` is an immutable PV field: delete and recreate the
  PV if it ever has to change.
