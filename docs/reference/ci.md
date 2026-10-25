# CI

Four workflows: what triggers each and what it does. What the checks inside
them prove is [Test](../guides/test.md).

| Workflow               | Trigger                                                                                                                                    | Does                                                                                                                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `validate.yaml`        | a pull request to main, a push to main                                                                                                     | the tree-side checks: shellcheck, ansible-lint and syntax checks, kubeconform, the charts against their fixtures, helm-unittest, `helmfile template`, gitleaks, `make check-docs` and the specs project's check |
| `upgrade-test.yaml`    | a pull request or push touching `src/ansible/`, `src/kubernetes/`, `.infrastructure/`, `specs/` or the workflow itself; or manual (`base`) | deploys a k3d cluster from the base tree, upgrades it with this one, then runs `specs/specs/{cluster,admission}` against it                                                                                     |
| `deploy-platform.yaml` | a successful `upgrade-test.yaml` on a push to main, once the same commit's `validate.yaml` passed; or manual                               | runs `platform.yml` over the tailnet, which also publishes the app chart, then the host specs over the same SSH connection                                                                                      |
| `smoke.yaml`           | a successful `deploy-platform.yaml`, daily at 07:17 UTC, or manual                                                                         | the platform contract against the live cluster, from the tailnet and from the internet                                                                                                                          |

A merge deploys only after its checks, and only what the upgrade test's path filter names; a change
to the manual, the specs or a workflow merges and stops there. CI never runs
the host layer: that is `make deploy` from the Mac.
