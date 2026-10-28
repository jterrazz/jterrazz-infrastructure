# CI

Three workflows, one per intent (Check, Deploy, Watch): what triggers each and what it does. What the checks inside
them prove is [Test](../guides/test.md).

| Workflow      | Trigger                                                                           | Does                                                                                                                                                                                                                                                                                                                            |
| ------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check.yaml`  | a pull request to main, a push to main, or manual (`base`)                        | the tree-side checks (shellcheck, ansible-lint and syntax checks, kubeconform, the charts against their fixtures, helm-unittest, `helmfile template`, gitleaks, `make check-docs`, the specs project's check), and the Upgrade test when the change touches `src/ansible/`, `src/kubernetes/`, `.infrastructure/`, `specs/` or the workflow itself: a k3d cluster deployed from the base tree, upgraded with this one, then `specs/specs/{cluster,admission}` against it |
| `deploy.yaml` | a successful Check of a push to main whose Upgrade test ran, or manual            | runs `platform.yml` over the tailnet, which also publishes the app chart, then the host specs over the same SSH connection, then Verify: the jobs of `watch.yaml`                                                                                                                                                                |
| `watch.yaml`  | daily at 07:17 UTC, manual, or called by Deploy as its Verify                     | the platform contract against the live cluster, from the tailnet and from the internet                                                                                                                                                                                                                                          |

A merge deploys only after its checks, and only what the Upgrade test's path filter names; a change
to the manual, the specs or a workflow merges and stops there. CI never runs
the host layer: that is `make deploy` from the Mac.
