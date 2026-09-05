# The corpus

Everything this repository knows about itself: one cluster on one machine, the
charts apps deploy through, and what breaks. Each chapter owns its subject;
nothing here is written twice.

| Chapter                                              | Holds                                                                          |
| ---------------------------------------------------- | ------------------------------------------------------------------------------ |
| [01-architecture.md](01-architecture.md)             | The machine, the four layers, the three charts, the traffic paths, the tree    |
| [02-deploy-contract.md](02-deploy-contract.md)       | What an app repo owes the cluster and what it gets back                        |
| [03-ci.md](03-ci.md)                                 | The four workflows, and why the chart fixtures are the validation contract     |
| [04-conventions.md](04-conventions.md)               | Rules the layout implies but does not state, including the three owners of DNS |
| [05-config-discipline.md](05-config-discipline.md)   | The five rules for editing any values file, manifest or template               |
| [06-hand-synced-pairs.md](06-hand-synced-pairs.md)   | The facts written down twice, each with its checker or an admission it has none |
| [07-gotchas.md](07-gotchas.md)                       | Behaviour the tree does not show, each paid for at least once                  |
| [08-platform-services.md](08-platform-services.md)   | What runs on the cluster that is not an app                                    |
| [09-runbook.md](09-runbook.md)                       | Secrets, troubleshooting, repaving, backups, restores, adding a service or app |
| [10-hetzner.md](10-hetzner.md)                       | How to resurrect a rented target, from git history                             |

Reference documentation for the charts lives beside them, in
`kubernetes/charts/<chart>/README.md`; a multi-part platform service keeps its
own README beside its values files.
