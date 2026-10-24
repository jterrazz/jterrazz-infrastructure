# ADR-004: One OrbStack VM is the only target, and its existence is the state

**Status:** Accepted
**Date:** 2026-05-11

Written 2026-10-24 from the comments in `src/ansible/` (inventories, `site.yml`,
roles base, resolved and tailscale) that this record replaces. The Hetzner
target was destroyed on 2026-05-11 (a23066f, b29f250); Pulumi, which had
created the VM since, was deleted on 2026-08-30 (ab4917d).

## Context

The cluster used to run on a rented Hetzner host, provisioned by Terraform,
then Pulumi, with a `target` switch so the same code could drive a local
OrbStack VM. Once Hetzner was gone, the switch and the provisioning tool
guarded a second target that no longer existed: Pulumi kept a state file
about one `orbctl create`, and its DNS records still claimed Pulumi in the
Cloudflare dashboard long after.

The OrbStack Debian image also arrives with quirks a stock server does not
have: `orb create debian` resolves to bookworm, `orbctl create -u root` fails
since OrbStack 2.2.0, sshd is absent and socket-activated once installed,
`/dev/kmsg` may be missing, systemd-resolved ships masked, and DHCP hands out
a resolver (0.250.250.200) that silently drops queries.

## Decision

There is one target: an OrbStack VM on the Mac, created by
`src/scripts/deploy.sh` (`orbctl`) when absent and configured by Ansible. There is
no provisioning state and no `target` branch anywhere.

- **The image is pinned and repaired, not tolerated.** `debian:trixie` is
  spelled out; every role is Debian-13-native (deb822 sources, since apt-key
  is gone, which needs python3-debian). The base role installs sshd and
  switches it from socket activation to the always-listening daemon (with
  socket activation `Port` is ignored and a restart does not re-bind), and
  recreates `/dev/kmsg` via tmpfiles.d when the VM lacks it (kubelet
  crashloops without it). A raw-SSH play bootstraps Python before facts are
  gathered.
- **The resolver is repaired in its own role, before tailscale and k3s.**
  systemd-resolved with fixed upstreams (1.1.1.1, 9.9.9.9; fallbacks 1.0.0.1,
  8.8.8.8; LLMNR and mDNS off, since both open listeners any bridge peer can
  answer). `DNS=` sets the global resolver but keeps the per-link DHCP one,
  which resolved also writes into `/run/systemd/resolve/resolv.conf`, the
  file kubelet hands CoreDNS: a third of in-cluster upstream lookups went to
  a resolver that drops them.
- **The DHCP resolver is removed at its source.** A networkd drop-in sets `UseDNS=false` on
  the discovered `.network` file (asserted to exist, since a drop-in for a
  renamed file is inert), applied with `networkctl reload` and
  `reconfigure`, never a networkd restart, which could drop the very link the
  play runs over. Without the stub resolver, Tailscale writes
  `nameserver 100.100.100.100` itself and the deploy dies at
  `helm registry login`. Diagnosis on a live VM is
  [Operate](../guides/operate.md#dns-on-the-vm).
- **Three inventories, one group.** `laptop.yml` reaches the VM through
  OrbStack's SSH proxy (`root@<vm>@orb`; `orb` is an ssh-config alias no
  client can present, so anything needing an address uses the tailnet name);
  `ci.yml` reaches it over Tailscale by MagicDNS with the CI deploy key;
  `k3d.yml` targets the upgrade test's throwaway cluster. All three name the
  group `cluster` (not `production`, which collided with the environment
  concept), so group_vars and selectors stay portable.
- **Data lives on the Mac.** `/var/lib/k8s-data`, baked into every PV, is a
  symlink into OrbStack's share of the Mac home
  (`~/.jterrazz-infrastructure/data`), created by `deploy.sh` before the VM,
  so the data survives `make destroy`.
- **The records Pulumi made are converged by the platform deploy**
  (`dns_records`, see [the private-hostnames record](012-private-hostnames-are-wildcard-zones.md)).

## Consequences

- `make deploy` from the Mac is the only way to create or repave the VM; no
  runner can, so CI only ever applies the platform layer.
- A `target`, `manageDns` or `deployment_target` branch is never the answer;
  bringing a rented host back is a resurrection from git history
  ([Resurrect Hetzner](../guides/resurrect-hetzner.md)).
- Every OrbStack image change is a review of the base and resolved roles,
  whose asserts fail loudly rather than leave a repair inert.
