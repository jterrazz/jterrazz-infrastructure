# The deploy contract

What an app repo owes this repo, and what it gets back. The chart is owned
here; the workflows that execute the contract are
[jterrazz/studio-actions](https://github.com/jterrazz/studio-actions).

## What an app repo owes

- **One manifest**, `.infrastructure/application.yaml`, an `Application` the
  app chart renders: port, resources, ingress, storage, secrets, per
  environment. The schema, its merge semantics, `uses`/`serves` and storage
  are [src/kubernetes/charts/app/README.md](../../src/kubernetes/charts/app/README.md).
- **`deploy:` on every environment**, or at the root of a shared app:
  `push` deploys it on every push to main and on the weekly rebuild,
  `release` on a `v*` tag, with the image built for that tag. The workflow
  refuses an environment that names neither, so nothing deploys by default.
- **An image that starts the app and nothing else**: distroless, `USER
  1000:1000`, an exec-form `ENTRYPOINT`, its migration declared as the
  manifest's `migrate:` ([the Dockerfile standard](dockerfile.md),
  [ADR-030](../decisions/030-an-image-runs-the-app-and-the-chart-runs-its-startup-task.md)).
- **One universal CI interface**: `make build`, `make lint`, `make test`,
  whatever the toolchain.
- **Dashboards named by their kind**, `.infrastructure/dashboards/service.json`
  (is it broken, and where), `business.json` (does it produce what it should),
  or a subsystem's name; never `overview`. The chart derives the uid
  (`<app>-<kind>`), title, tags, folder and links, so the file holds panels
  only, and the CPU, memory and log panels every workload shares are
  `studio-infrastructure / Workload`'s, linked rather than copied
  ([ADR-027](../decisions/027-a-dashboard-answers-one-audience-and-its-identity-is-derived.md)).
  An alert rule carries `__dashboardUid__` and `__panelId__` for the panel
  that explains it.
- **No secret at all.** The calling job grants
  `permissions: { contents: read, id-token: write }`; Infisical, Tailscale and
  the cluster each accept the job's GitHub OIDC token.

## How a deploy authenticates

With nothing stored. The deploy job's GitHub OIDC token, audience
`studio-infrastructure`, is accepted by the apiserver for any
`jterrazz/<repo>` workflow running on `main` or a `v*` tag, as user
`github:jterrazz/<repo>`
([authentication.yaml.j2](../../src/ansible/roles/k3s/templates/authentication.yaml.j2),
[ADR-017](../decisions/017-app-repositories-deploy-as-their-github-oidc-identity.md)).

What the identity may do is
[`charts/cluster/templates/rbac/app-deployers.yaml`](../../src/kubernetes/charts/cluster/templates/rbac/app-deployers.yaml) and
[`charts/cluster/templates/admission/app-deployer-ownership.yaml`](../../src/kubernetes/charts/cluster/templates/admission/app-deployer-ownership.yaml), and
there is no list of apps in it. A repo:

1. creates one namespace per environment on its first deploy, `<app>-<env>`
   (`<app>` for a shared app), labelled `studio.jterrazz.com/tier: app`,
   `studio.jterrazz.com/app: <app>`, `studio.jterrazz.com/environment: <env>`
   (or `studio.jterrazz.com/scope: shared`) and
   `studio.jterrazz.com/repository: <repo>`, and from then on owns them and
   nothing else (the `app-deployer-ownership` admission policy, which also
   holds the name to what the labels state, and the app to the repository's
   own name or an app its allowlist pairs with the repository);
2. grants itself `app-namespace-admin` inside each of them with a RoleBinding,
   which is the only way it reads or writes anything namespaced;
3. may create a hostPath volume only at `/var/lib/k8s-data/<pv name minus -data>`,
   labelled with its name, and may not opt a namespace out of Pod Security;
4. may sync only its own Infisical folder `/<app>`, in its namespace's own
   environment (`prod` for a shared app), or the registry pull pair.

`studio-actions/actions/docker-deploy` does the first three before `helm upgrade`,
and deploys the image by digest. The environments stay the app's choice, in
its own manifest. One residual risk is written down in the policy: nothing
owns a hostname, so a repo could declare a route or certificate for any name
in our zones from inside its own namespace.

## What the app repo gets

- **A first deploy that needs no change here.** Namespace, RoleBinding and
  certificate are created by the deploy itself; this repo does not know an app
  exists until its namespace shows up.
- **The chart, pulled unversioned** from
  `oci://registry.internal.jterrazz.com/charts/app`. An app never pins a chart
  version, which is why a template edit must bump `version:` in
  `charts/app/Chart.yaml`; see [Hand-synced pairs](hand-synced-pairs.md).
- **Discovery instead of registration.** Its routes are probed from their own
  `studio.jterrazz.com/smoke-*` annotations and its repository is read back for a
  repave, so nothing here lists hostnames, status codes or repositories
  ([Test](../guides/test.md#what-a-deploy-proves)).

## Consequences worth knowing

Renaming an app creates a new release in a new namespace, and the old one
keeps running: `helm uninstall <old>-<env> -n <old>-<env> && kubectl delete ns
<old>-<env>`. Its volume's directory, `/var/lib/k8s-data/<old>-<env>`, is moved
to the new name by hand before the first deploy under it, or the app starts
empty.

Node and Next.js packaging traps (pnpm `--ignore-scripts`, `output:
'standalone'`, `mkdir -p public`) are the shared workflows' business, in
`studio-actions`.
