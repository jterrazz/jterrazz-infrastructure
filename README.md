# @jterrazz/infrastructure

One cluster on one machine: single-node k3s on an OrbStack VM on the dev Mac.
Public traffic enters through an outbound Cloudflare tunnel, private traffic
over the tailnet, and nothing listens on a public address. Apps live in their
own repositories and deploy themselves, as their GitHub OIDC identity, through
the `app` chart published here.

## Why

A fleet of small apps does not need a cloud bill or a control plane to babysit.
One machine, rebuilt from this tree in one command, keeps the whole estate
reproducible: the VM's existence is the only state, Ansible configures it,
Helmfile deploys onto it, and an app joins by shipping one manifest rather than
by being registered here.

## In 30 seconds

An app repo declares itself in `.infrastructure/application.yaml` and its CI
renders the chart published from here:

```yaml
apiVersion: jterrazz.com/v1
kind: Application
metadata:
  name: my-app
spec:
  port: 3000
  resources:
    cpu: 100m
    memory: 256Mi
  health:
    path: /health
  ingress:
    - host: my-app.jterrazz.com
      public: true
```

The full schema is [the app chart's README](src/kubernetes/charts/app/README.md);
what an app owes the cluster is [the deploy contract](docs/reference/deploy-contract.md).

## Quick start

```bash
make deploy           # create the VM if absent, then Ansible site.yml: the whole machine
make deploy-platform  # Ansible platform.yml only: everything above k3s
make diff             # what a platform deploy would change (helmfile diff, needs the tailnet)
make smoke            # the platform contract from this Mac: routes, certificates, boundary, cluster
make test             # smoke, then the node itself (sshd, firewall, upgrades, k3s)
make redeploy-apps    # trigger every app's CI to rebuild and redeploy
make backup           # an encrypted snapshot of every persistent volume
make destroy          # delete the VM (the data directory on the Mac stays)
make check            # the checks CI runs on the tree (alias: make lint)
```

`make help` lists the rest. The deploy reads the Infisical identity in `.env`;
the playbook's first role fetches every other secret from Infisical and fails
on a missing one.

## Layout

`src/` holds what runs (`ansible/`, `kubernetes/`, `scripts/`), `specs/` what
proves it (the platform contract, a TypeScript suite), `docs/` what explains it.
[docs/README.md](docs/README.md) is the map of the manual; start at
[Architecture](docs/concepts/architecture.md), deploy an app with
[the deploy contract](docs/reference/deploy-contract.md), and open
[Operate](docs/guides/operate.md) when something is broken.
