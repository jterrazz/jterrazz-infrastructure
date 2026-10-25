# Resurrecting a Hetzner target

This repository used to drive a Hetzner cax21 VPS beside the OrbStack VM, and
Pulumi created both. Both are gone
([ADR-004](../decisions/004-one-orbstack-vm-is-the-only-target.md)), and both
are in git history:

- `dfc3c78^` is the last tree with both targets: the `deployment_target`
  branches, the Hetzner inventory, `deploy.sh`'s positional target. Verify the
  commit with `git log --diff-filter=D --name-only -- pulumi/src/targets/hetzner.ts`.
- `487f370` is the last tree with `pulumi/`; read any file of it with
  `git show 487f370:pulumi/src/targets/hetzner.ts`.

A resurrection is the smaller of two moves: drive the `hcloud` CLI from
`src/scripts/deploy.sh` the way it drives `orbctl` (one server, one SSH key,
one firewall, `image: debian-13`, never Hetzner's default, which is the
previous stable), or restore `pulumi/` whole. Either way it needs:

- a second inventory beside `laptop.yml`, group `cluster`, with the host's
  address and key;
- the OrbStack-only steps made conditional again: the `/dev/kmsg` backfill and
  the `/var/lib/k8s-data` symlink, which becomes a plain directory;
- the host's public address back among the k3s TLS SANs.

**DNS is the hazard.** The private wildcards follow `tailscale_dns_hostname`,
so with two hosts deployed, whichever ran its platform deploy last owns
`*.internal` and `*.staging`: run the other with `--skip-tags cloudflare`.
After a swap, `make redeploy-apps`: every image lives in the old cluster's
registry.
