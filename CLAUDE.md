# Agent brief

One k3s cluster on one machine, deployed by one script. This file routes; the
knowledge is in [docs/README.md](docs/README.md).

## Mental model

`src/scripts/deploy.sh` creates an OrbStack VM on the Mac, Ansible
(`src/ansible/`) configures it, and Helmfile deploys `src/kubernetes/` onto it.
Above the machine there are four layers (host, cluster, platform services,
apps) and two Helm charts with the library they share. Apps deploy
from their own repositories through the `app` chart published here, as their
GitHub OIDC identity; the cluster is discovered from annotations, never listed.
`specs/` is the platform contract, a TypeScript suite on `@jterrazz/test` run
against the live cluster.

Two properties explain most of the tree. There is no provisioning state: the
VM's existence is the state. And there is no second target: a `target`,
`manageDns` or `deployment_target` branch is never the answer. Prometheus,
Loki, Tempo, Alloy, n8n, Portainer and LibreChat were removed with their data;
a list that names one is stale, never a cue to bring it back.

## Layout

| Path              | Holds                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| `src/ansible/`    | the playbooks and roles: host layer, then the platform layer            |
| `src/kubernetes/` | the helmfile, the three charts, cluster manifests, service values       |
| `src/scripts/`    | `deploy.sh`, `helmfile.sh`, `backup.sh`, `redeploy-apps.sh`             |
| `specs/`          | the platform contract (`specs/specs/`), a TypeScript project of its own |
| `docs/`           | the manual and the decisions                                            |

## Where to read

| Question                                                | Page                                                                                                 |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| How does the system fit together? How are things named? | [docs/concepts/architecture.md](docs/concepts/architecture.md)                                       |
| What keeps a request out, and what proves it?           | [docs/concepts/security.md](docs/concepts/security.md)                                               |
| I am editing a values file, manifest, template or role  | [docs/guides/develop.md](docs/guides/develop.md)                                                     |
| What proves this change? What does a deploy prove?      | [docs/guides/test.md](docs/guides/test.md)                                                           |
| Troubleshooting, repave, restore, rotate, add a service | [docs/guides/operate.md](docs/guides/operate.md)                                                     |
| Where does a secret live, and who reads it?             | [docs/reference/secrets.md](docs/reference/secrets.md)                                               |
| I am deploying or configuring an app                    | [docs/reference/deploy-contract.md](docs/reference/deploy-contract.md)                               |
| What does CI run, and what does a merge trigger?        | [docs/reference/ci.md](docs/reference/ci.md)                                                         |
| I am changing a version, a digest or a shared value     | [docs/reference/hand-synced-pairs.md](docs/reference/hand-synced-pairs.md)                           |
| What runs on the cluster?                               | [docs/reference/platform-services.md](docs/reference/platform-services.md)                           |
| How do I bring a rented target back?                    | [docs/guides/resurrect-hetzner.md](docs/guides/resurrect-hetzner.md)                                 |
| Why was a choice made?                                  | [docs/decisions/](docs/decisions/)                                                                   |
| The `application.yaml` schema                           | [src/kubernetes/charts/app/README.md](src/kubernetes/charts/app/README.md)                           |
| A platform service's `service.yaml`                     | [src/kubernetes/charts/platform-service/README.md](src/kubernetes/charts/platform-service/README.md) |
| What the two charts share                               | [src/kubernetes/charts/common/README.md](src/kubernetes/charts/common/README.md)                     |

## Gestures

```bash
make check      # everything CI runs on the tree (alias: make lint)
make deploy     # create the VM if absent, then Ansible site.yml
make diff       # what a platform deploy would change, without changing it
make smoke      # the platform contract from this Mac: routes, certificates, boundary, cluster
make test       # smoke, then the node itself (sshd, nft guard, upgrades, k3s)
```

What each one proves is [docs/guides/test.md](docs/guides/test.md); what a change
owes before it is committed is
[docs/guides/develop.md](docs/guides/develop.md#before-you-commit).
