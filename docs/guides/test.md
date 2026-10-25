# Testing

What proves a change here, and what nothing proves. The evidence is of three
kinds: tree-side checks, which read files and render templates with no cluster;
the upgrade test, which runs the real deploy against a throwaway cluster; and
the platform contract, a TypeScript suite run against the deployed state from
two vantages. The workflows that carry them are [CI](../reference/ci.md).

## The tree-side checks

`make check` (alias `make lint`) is the local form of `validate.yaml`:

| Check                                                                             | Proves                                                                                           |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `shellcheck src/scripts/*.sh src/scripts/lib/*.sh`                                | the shell is not quietly wrong: quoting, unset variables, word splitting                         |
| `ansible-lint -c src/ansible/.ansible-lint src/ansible/`                          | the whole Ansible tree, roles, templates and inventories                                         |
| `helm lint` of `common`, then `app` and `platform-service` against their fixtures | the charts render, and render something                                                          |
| `helm unittest --strict` on both charts                                           | what the templates computed; `--strict` makes a typo'd assertion an error                        |
| `actionlint`                                                                      | the workflow files                                                                               |
| `make check-docs`                                                                 | the repository as content: the manual's shape, the Markdown, the comments, the names, no secret  |
| `make check-specs`                                                                | the specs project against its own toolchain: types, lint, format, `@jterrazz/test`'s conventions |

actionlint, helm-unittest, `make check-docs` and `make check-specs` skip softly on a
machine without them, because CI runs every one unconditionally; any other
missing tool fails `make check`.

### What only CI runs

- **`ansible-playbook --syntax-check`** of both playbooks, each against the
  inventory that runs it.
- **kubeconform** over `src/kubernetes/cluster`, each chart rendered with its
  fixture, and every raw manifest under `src/kubernetes/services` (a file with
  a top-level `apiVersion:`). Never `-ignore-missing-schemas`: a CRD kind with no
  schema fails ([ADR-020](../decisions/020-validation-gates-fail-loudly-and-pin-what-they-run.md)).
- **`helmfile template`** over every declared release: a bad chart version, a
  moved values file or a dangling `needs:` fails here, not mid-deploy.
- **gitleaks** over the checked-out tree, never the history, which holds
  rotated credentials.

### The fixtures are the validation contract

Both charts render nothing with default values, so CI exercises only what
`ci/test-values.yaml` reaches; `charts/common` has no fixture and is reached
through the other two. Nothing can tell a new branch went unfixtured: adding a
branch means adding the values that reach it, in the same change. The snapshot
suites pin the whole render, and a failing snapshot is read before
`helm unittest -u` regenerates it.

## The upgrade test runs the deploy itself

`upgrade-test.yaml` creates a k3d cluster at the production k3s version and
runs the real `platform.yml` twice: from the base tree (the pull request's
base, the commit before a push, or a dispatched `base`; `HEAD` tests a re-run),
then from this one. It proves every release applies on top of the previous
tree: schemas, Pod Security, the two admission policies, immutable fields, a
task that breaks on a re-run. Each pass ends on `helm list --failed`. It then runs
`specs/specs/cluster` and `specs/specs/admission` against the cluster as admin,
never `specs/specs/health`. It does not prove pods start: with dummy secrets
most cannot, nothing syncs and no certificate issues, so
`platform_helm_wait: false` keeps helm from waiting
([ADR-021](../decisions/021-the-deploy-is-tested-on-a-throwaway-k3d-cluster.md)).

## What a deploy proves

A green playbook is not "the site loads". An apply can succeed and leave a
service unreachable, or leave a door open nothing reached for. The platform
contract closes both gaps, read from the live objects rather than from a list
([ADR-022](../decisions/022-the-platform-contract-is-a-typescript-suite-run-from-two-vantages.md)):
every IngressRoute carries its expectations as `smoke.jterrazz.com/*`
annotations, which the charts stamp, so a route an app added yesterday is
probed today with no edit here.

### The suite, file by file

`specs/` is a TypeScript project of its own, its suite under `specs/specs/`:

| Specs                                             | Proves                                                                                                                        | Runs from                |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `api/routes/public.spec.ts`                       | every public route answers its contract through the tunnel, a redirect its `Location`                                         | either vantage           |
| `api/routes/private.spec.ts`                      | every tailnet-only route answers its contract                                                                                 | the tailnet              |
| `api/certificates/{public,private}`               | every host presents a trusted certificate that covers it, 15 days or more from expiry                                         | the host's vantage       |
| `api/boundary/internet.spec.ts`                   | a private host never answers, and a public host refuses a request naming a private one                                        | the internet only        |
| `cluster/rbac/secrets.test.ts`                    | exactly the allow-listed service accounts may list Secrets cluster-wide                                                       | the API server           |
| `cluster/rbac/github-actions.test.ts`             | the app deployers may create namespaces, and neither list Secrets nor exec anywhere                                           | the API server           |
| `cluster/traefik/service.test.ts`                 | no Service holds a nodePort, and Traefik admits `100.64.0.0/10` alone                                                         | the API server           |
| `cluster/namespaces/ownership.test.ts`            | every namespace states its tier; a platform one is `platform-*`, an app one `<app>-<env>` with its repository and environment | the API server           |
| `cluster/network-policies/`                       | every NetworkPolicy selects pods some controller creates, and every peer it names exists                                      | the API server           |
| `health/workloads/ready.test.ts`                  | every controller runs as many ready pods as it asks for, and every CronJob's last run succeeded                               | the API server           |
| `health/services/endpoints.test.ts`               | every Service that selects pods has a ready one behind it                                                                     | the API server           |
| `health/certificates/ready.test.ts`               | every Certificate is Ready (the two wildcards)                                                                                | the API server           |
| `health/secrets/synced.test.ts`                   | every InfisicalSecret syncs from its folder                                                                                   | the API server           |
| `health/volumes/bound.test.ts`                    | every PersistentVolume is Bound and `Retain`                                                                                  | the API server           |
| `admission/app-deployer-ownership/policy.test.ts` | the ownership policy's cases, admitted and denied, as an app's identity, its InfisicalSecrets included                        | k3d, in the upgrade test |
| `admission/host-access/policy.test.ts`            | only kube-system and the two named telemetry agents may touch the host                                                        | k3d, in the upgrade test |
| `host/`                                           | sshd takes keys alone, the nft guard, unattended-upgrades, Secret encryption, the Pod Security default                        | the node, as root        |

A status outside the annotated set fails (a 502, a 503 and `unreachable` never
are in it), and so does a certificate within 15 days of expiry: cert-manager
renews at 30, so 15 means renewal has failed for two weeks.

### The two vantages

- **The tailnet** (`smoke.yaml`'s first job): routes and certificates of both
  scopes, `specs/specs/cluster` and `specs/specs/health`, reading the cluster as
  `github:jterrazz/jterrazz-infrastructure` through the read-only
  `platform-reader` role. It snapshots the IngressRoutes for the second job.
- **The internet** (the second job, never on the tailnet): the public routes
  and `api/boundary`, against that snapshot.

The host specs run from `deploy-platform.yaml` after the play, over its SSH
connection. `smoke.yaml` runs after every successful platform deploy, every
Monday at 07:17 UTC (the only uptime monitor) and on demand.

### Running it from the Mac

The Mac is the internet vantage unless its Tailscale is up, and reaches the
cluster and the node through OrbStack:

```bash
make smoke                   # public routes and certificates, boundary, cluster, inventory
make smoke VANTAGE=tailnet   # with Tailscale up: the private routes instead of the boundary
make test-host               # the node, as root through orb
make test-admission KUBECONFIG=<a k3d kubeconfig>   # a throwaway cluster only
```

`make smoke CLUSTER_KUBECTL=` reads `$KUBECONFIG`, then `./kubeconfig.yaml`,
instead of `orb`; `cd specs && npx vitest --run <path>` runs any subset.

## What nothing proves

- **That a deploy changes only what it should.** `make diff` previews it from a
  tailnet client; it is a habit before a deploy, not a gate.
- **The admission policies on the live cluster.** Their cases impersonate apps
  and offer host-touching pods, so they run on k3d against the same manifests.
- **A template branch no fixture reaches** ([above](#the-fixtures-are-the-validation-contract)).
- **A stale vendored CRD schema** still validates
  ([Hand-synced pairs](../reference/hand-synced-pairs.md)).
