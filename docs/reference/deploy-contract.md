# The deploy contract

What an app repo owes this repo, and what it gets back. The chart is owned
here; the workflows that execute the contract are
[jterrazz/jterrazz-actions](https://github.com/jterrazz/jterrazz-actions).

## What an app repo owes

- **One manifest**, `.infrastructure/application.yaml`, an `Application` the
  app chart renders: port, resources, ingress, storage, secrets, per
  environment. The schema, its merge semantics, `platformServices` and storage
  are [src/kubernetes/charts/app/README.md](../../src/kubernetes/charts/app/README.md).
- **`tag:` on every environment.** Without it the workflow takes a legacy
  branch that deploys "staging" and leaves prod silently stale.
- **One universal CI interface**: `make build`, `make lint`, `make test`,
  whatever the toolchain.
- **No secret at all.** The calling job grants
  `permissions: { contents: read, id-token: write }`; Infisical, Tailscale and
  the cluster each accept the job's GitHub OIDC token.

## How a deploy authenticates

With nothing stored. The deploy job's GitHub OIDC token, audience
`jterrazz-infrastructure`, is accepted by the apiserver for any
`jterrazz/<repo>` workflow running on `main` or a `v*` tag, as user
`github:jterrazz/<repo>`
([authentication.yaml.j2](../../src/ansible/roles/k3s/templates/authentication.yaml.j2),
[ADR-017](../decisions/017-app-repositories-deploy-as-their-github-oidc-identity.md)).

What the identity may do is
[`charts/cluster/templates/rbac/app-deployers.yaml`](../../src/kubernetes/charts/cluster/templates/rbac/app-deployers.yaml) and
[`charts/cluster/templates/admission/app-deployer-ownership.yaml`](../../src/kubernetes/charts/cluster/templates/admission/app-deployer-ownership.yaml), and
there is no list of apps in it. A repo:

1. creates one namespace per environment on its first deploy, `<app>-<env>`,
   labelled `app.jterrazz.com/tier: app`, `app.jterrazz.com/environment: <env>`
   and `app.jterrazz.com/repository: <repo>`, and from then on owns them and
   nothing else (the `app-deployer-ownership` admission policy);
2. grants itself `app-namespace-admin` inside each of them with a RoleBinding,
   which is the only way it reads or writes anything namespaced;
3. may create a hostPath volume only at `/var/lib/k8s-data/<pv name minus -data>`,
   labelled with its name, and may not opt a namespace out of Pod Security.

`jterrazz-actions/actions/docker-deploy` does all three before `helm upgrade`,
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
  `smoke.jterrazz.com/*` annotations and its repository is read back for a
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
`jterrazz-actions`.
