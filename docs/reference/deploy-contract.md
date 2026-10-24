# The deploy contract

What an app repo owes this repo, and what it gets back. The chart is owned
here; the workflows that execute the contract are
[jterrazz/jterrazz-actions](https://github.com/jterrazz/jterrazz-actions).

## What an app repo owes

- **One manifest**, `.infrastructure/application.yaml`, an `Application` the
  app chart renders: port, resources, ingress, storage, secrets, per
  environment. The schema, its merge semantics, `platformServices` and storage
  are [kubernetes/charts/app/README.md](../../kubernetes/charts/app/README.md).
- **`tag:` on every environment.** Without it the workflow takes a legacy
  branch that deploys "staging" and leaves prod silently stale.
- **One universal CI interface**: `make build`, `make lint`, `make test`,
  whatever the toolchain.
- **Two GitHub secrets**, `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET`,
  set on the repo before its first deploy; see
  [Operate](../guides/operate.md#github-secrets-every-app-repo).

## How a deploy authenticates

With nothing stored. The deploy job's GitHub OIDC token, audience
`jterrazz-infrastructure`, is accepted by the apiserver for any
`jterrazz/<repo>` workflow running on `main`, as user
`github:jterrazz/<repo>` ([authentication.yaml.j2](../../ansible/roles/k3s/templates/authentication.yaml.j2)).
That is why a calling job grants `permissions: id-token: write`.

What the identity may do is
[kubernetes/cluster/app-deployers/](../../kubernetes/cluster/app-deployers/), and
there is no list of apps in it. A repo:

1. creates its namespaces on its first deploy, labelled
   `app.jterrazz.com/repository: <repo>`, and from then on owns them and nothing
   else (the `app-deployer-ownership` admission policy);
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
- **Discovery instead of registration.** Smoke probes and redeploys read the
  live cluster: `scripts/smoke.sh` probes what each IngressRoute's
  `smoke.jterrazz.com/*` annotations say, and `scripts/trigger-app-deploys.sh`
  reads `app.jterrazz.com/repository` off every app Deployment. No list of
  hostnames, status codes or repos lives here.

## Consequences worth knowing

Renaming an app creates a new Helm release, and the old one keeps running:
`helm uninstall <env>-<old> -n <env>-<old> && kubectl delete ns <env>-<old>`.

Node and Next.js packaging traps (pnpm `--ignore-scripts`, `output:
'standalone'`, `mkdir -p public`) are the shared workflows' business, in
`jterrazz-actions`.
