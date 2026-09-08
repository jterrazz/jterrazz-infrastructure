# The corpus

Everything this repository knows about itself: one cluster on one machine, the
charts apps deploy through, and what breaks. Each chapter owns its subject;
nothing here is written twice.

| Chapter                                                | Holds                                                                             |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| [01-architecture.md](01-architecture.md)               | The machine, the four layers, the three charts, the traffic paths, the tree       |
| [02-developing.md](02-developing.md)                   | How a change is made: the gate, the five config rules, the conventions, DNS owners |
| [03-testing.md](03-testing.md)                         | What proves a change: the tree-side checks, the chart fixtures, the smoke probe    |
| [04-operating.md](04-operating.md)                     | Secrets, troubleshooting, repaving, backups, restores, adding a service or app     |
| [05-deploy-contract.md](05-deploy-contract.md)         | What an app repo owes the cluster and what it gets back                            |
| [06-ci.md](06-ci.md)                                   | The four workflows, what triggers each, and what a merge does not do               |
| [07-hand-synced-pairs.md](07-hand-synced-pairs.md)     | The facts written down twice, each with its checker or an admission it has none    |
| [08-platform-services.md](08-platform-services.md)     | What runs on the cluster that is not an app                                        |
| [09-hetzner.md](09-hetzner.md)                         | How to resurrect a rented target, from git history                                 |

The decisions this repository took alone stand in [decisions/](decisions/),
numbered and chronological, with the mold `_template.md` beside them.

Reference documentation for the charts lives beside them, in
`kubernetes/charts/<chart>/README.md`; a multi-part platform service keeps its
own README beside its values files.
