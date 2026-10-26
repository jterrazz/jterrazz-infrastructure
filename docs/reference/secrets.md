# Secrets

Every secret this system reads, where it lives and who reads it. None is in
this repository; Infisical holds them, and `.env` holds only the identity that
reads Infisical. Rotating one is [Operate](../guides/operate.md#rotating-credentials).

## Read by the deploy

`src/ansible/roles/secrets`, the first role of both playbooks, fetches the list
`infisical_secrets` in group_vars on the controller (the Mac or the runner),
each folder explicitly, and stops on a missing key before anything deploys
([ADR-015](../decisions/015-deploy-secrets-are-fetched-once-by-ansible.md)).

| Project, path                                  | Keys                                                                            | Read by                      |
| ---------------------------------------------- | ------------------------------------------------------------------------------- | ---------------------------- |
| `studio-infrastructure`, `/studio-infrastructure`         | `CLOUDFLARE_DNS01_TOKEN`, `CLOUDFLARE_RECORDS_TOKEN`, `CLOUDFLARE_TUNNEL_TOKEN` | both playbooks               |
|                                                | `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`                    | `site.yml` only              |
|                                                | `BACKUP_AGE_IDENTITY`                                                           | `make backup` only           |
| `studio-infrastructure`, `/studio-infrastructure/grafana` | `ADMIN_PASSWORD`                                                                | both playbooks               |
| `studio-ci`, `/`                             | `DOCKER_REGISTRY_USERNAME`, `DOCKER_REGISTRY_PASSWORD`: the push account        | both playbooks, app CI       |
|                                                | `REGISTRY_PULL_USERNAME`, `REGISTRY_PULL_PASSWORD`: the read-only account       | both playbooks, the operator |

The Infisical identity itself (`INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`)
comes from `.env` locally and from the repository's GitHub secrets in CI; the
deploy writes it into `platform-secrets/infisical-credentials` for the
operator.

`studio-ci` is a project of its own because CI reads it over GitHub OIDC:
the machine identity `github-actions` (subject
`repo:jterrazz@18480834/*:ref:refs/heads/main`, audience
`https://github.com/jterrazz`) is a Viewer of that project and of nothing else.

## Synced into the cluster

The operator syncs an `InfisicalSecret` rendered by the release that needs it
(a `service.yaml`'s `secrets:`, an app's `spec.secrets`):

| Infisical path                            | Secret                                       | Keys                                                                                             |
| ----------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `/studio-infrastructure`                | `cloudflared-secrets`                        | `CLOUDFLARE_TUNNEL_TOKEN`                                                                        |
| `/studio-infrastructure`                | `external-dns-secrets`                       | `CF_API_TOKEN`, from `CLOUDFLARE_RECORDS_TOKEN`                                                  |
| `/studio-infrastructure/openpanel`      | `op-{api,worker,dashboard,postgres}-secrets` | the keys each release names                                                                      |
| `/studio-infrastructure/otel-collector` | `otel-collector-secrets`                     | `LANGFUSE_BASIC_AUTH`                                                                            |
| `/studio-infrastructure/grafana`        | `grafana-alerting`                           | `contact-point-slack.yaml`, from the optional `SLACK_WEBHOOK_URL`                                |
| `studio-ci`, `/`                        | `registry-credentials`                       | `.dockerconfigjson` from the read-only account, in every app namespace pulling from our registry |
| `/<app>`                                  | `<app>-secrets`                              | the app's `spec.secrets.env`                                                                     |

## GitHub and local secrets

| Where                              | Secrets                                                                                                                      |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `jterrazz/studio-infrastructure` | `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`, `CI_DEPLOY_SSH_PRIVATE` (whose public half is `security_ci_deploy_pubkey`) |
| every app repository               | none: an app deploy authenticates with its job's OIDC token                                                                  |
| `.env` (gitignored)                | `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`                                                                             |

A repave needs nothing new in Infisical: an app job reads the CA from k3s'
`/cacerts` and its identity from GitHub.
