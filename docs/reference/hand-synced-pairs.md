# Hand-synced pairs

Facts this repository writes down twice, because one side lives outside it or
cannot be read from the other. The goal is an empty table: a fact with two
homes drifts, so the first answer is always to give it one
([ADR-016](../decisions/016-every-fact-has-one-home.md)). Every row names what
catches a drift, or admits nothing does.

| A                                                       | B                                                       | Checked by                                   | Why they must match                                                                                                                |
| ------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| the `infisical` release's `version:` (helmfile)         | `src/kubernetes/schemas/infisicalsecret_v1alpha1.json`  | nothing: a stale schema still validates      | re-extract the CRD with the command in `src/kubernetes/schemas/README.md`, or CI validates against a CRD the cluster no longer has |
| `security_ci_deploy_pubkey` (`roles/security`)          | the GitHub secret `CI_DEPLOY_SSH_PRIVATE`               | nothing: B lives outside the repository      | a split keypair; a rotation changes both, then `make deploy`                                                                       |
| `k3s_oidc_audience` (group_vars)                        | `audience:` in `jterrazz-actions/actions/docker-deploy` | nothing: a mismatch refuses every app deploy | the apiserver accepts one audience; change both, the host layer first                                                              |
| `version:` in `charts/app/Chart.yaml`                   | the chart published to the registry                     | nothing at review time                       | apps pull it unversioned and the publisher never overwrites a version, so an unbumped template change ships nothing                |
| `ci/test-values.yaml` of each chart                     | that chart's templates                                  | nothing: there is no equality to assert      | a template branch no fixture reaches is a branch CI never renders                                                                  |
| `deploy`, `deploy-next` in `services/registry/app.yaml` | the push account's name in Infisical `jterrazz-ci`      | nothing: a third name can only read          | Zot grants write by name; a rotation alternates between the two                                                                    |
