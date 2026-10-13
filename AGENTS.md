# Agent brief

One k3s cluster on one machine, deployed by one script. This file routes; the
knowledge is in [docs/README.md](docs/README.md).

## Mental model

`scripts/deploy.sh` creates an OrbStack VM on the Mac, Ansible configures it,
Helmfile deploys onto it. Above the machine there are four layers — host,
cluster, platform services, apps — and three Helm charts, one of them a library
the other two share. Apps are not deployed from here: they render through the
`app` chart this repo publishes, and the cluster is discovered from annotations
rather than from a list.

Two properties explain most of the tree. There is no provisioning state: the
VM's existence is the state. And there is no second target: Hetzner was
removed, so a `target` / `manageDns` / `deployment_target` branch is never the
answer.

## Where to read

| Question                                                 | Page                                                                                |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| How does the system fit together? What is the layout?    | [docs/concepts/architecture.md](docs/concepts/architecture.md)                      |
| I am editing a values file, manifest, template or role   | [docs/guides/develop.md](docs/guides/develop.md)                                    |
| What proves this change? What does a deploy prove?       | [docs/guides/test.md](docs/guides/test.md)                                          |
| Secrets, troubleshooting, repave, restore, add a service | [docs/guides/operate.md](docs/guides/operate.md)                                    |
| I am deploying or configuring an app                     | [docs/reference/deploy-contract.md](docs/reference/deploy-contract.md)              |
| What does CI run, and what does a merge trigger?         | [docs/reference/ci.md](docs/reference/ci.md)                                        |
| I am changing a version, a digest or a shared value      | [docs/reference/hand-synced-pairs.md](docs/reference/hand-synced-pairs.md)          |
| What runs on the cluster, and where is its detail?       | [docs/reference/platform-services.md](docs/reference/platform-services.md)          |
| How do I bring a rented target back?                     | [docs/guides/resurrect-hetzner.md](docs/guides/resurrect-hetzner.md)                |
| Why was a choice made?                                   | [docs/decisions/](docs/decisions/)                                                  |
| The `application.yaml` schema                            | [kubernetes/charts/app/README.md](kubernetes/charts/app/README.md)                  |
| What the two charts share                                | [kubernetes/charts/common/README.md](kubernetes/charts/common/README.md)            |
| One service's versions, data paths and quirks            | `kubernetes/services/<svc>/README.md`                                               |

## Gestures

```bash
make check      # everything CI runs on the tree (alias: make lint)
make deploy     # create the VM if absent + ansible site.yml
make diff       # what a platform deploy would change, without changing it
make smoke      # probe the deployed public surfaces
```

What each one proves is [docs/guides/test.md](docs/guides/test.md); what a change
owes before it is committed is
[docs/guides/develop.md](docs/guides/develop.md#before-you-commit).
