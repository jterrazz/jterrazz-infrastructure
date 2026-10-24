# ADR-006: The host has no public inbound path, and OrbStack peers are walled off

**Status:** Proposed
**Date:** 2026-07-26

Written 2026-10-24 from the comments in `ansible/roles/{security,tailscale}`
and the k3s templates (commit 2885ec2, extended by the 2026-10-24 audit) that
this record replaces.

## Context

Nothing on the host faces the internet: public traffic arrives through the
Cloudflare tunnel, everything else over Tailscale or OrbStack's SSH proxy.
The neighbours are the threat. OrbStack puts every machine on one bridge
(192.168.139.0/24) and mounts every other machine's rootfs at
`/mnt/machines/<name>/`, readable as root, so file modes are no boundary: a
plain `orb create` machine could read the datastore and the kubeconfig. And
UFW was not the gate it looked like: k3s inserts iptables rules ahead of
UFW's INPUT filter, so `ufw default deny incoming` did not stop a peer from
reaching node-exporter:9100, cloudflared:2000 or kubelet:10250; all three
answered a neighbouring machine.

## Decision

- **An nftables guard** (`table inet jterrazz_guard`, input hook at priority
  -10, ahead of k3s and UFW, scoped to eth0 so pod traffic via cni0 and
  tailnet traffic via tailscale0 pass): accept the hypervisor host (how
  `orb`, Ansible and every Mac tool reach the VM); drop the peer subnet on
  22, 2000, 6443, 9100, 10250 and udp 5355; drop the NodePort range from
  every source, the Mac included, because a NodePort answers on the node
  address and bypasses the tailnet gate (audit 2026-10-24); drop 9100 and
  2000 on tailscale0, unauthenticated metrics scraped over the pod network
  only. It loads after UFW so a `ufw reload` cannot flush it.
- **UFW stays as the second gate**: 22 from anywhere (no public path exists,
  and a source rule could lock the Mac out), 80/443 and 6443 from
  100.64.0.0/10 only, IPv6 off (nothing listens on it). The first gate for
  80/443 is Traefik's `loadBalancerSourceRanges`.
- **Secrets encrypted at rest** (`secrets-encryption: true`): without it every
  Secret sits in plaintext in `state.db`, readable through `/mnt/machines`.
  Enabling encrypts only new writes, so the role runs
  `k3s secrets-encrypt reencrypt --force` once. Verify by value (decode a
  real Secret, grep `state.db` for it), never by counting `password`, which
  CRD schemas and ConfigMaps dominate.
- **An API audit log** at Metadata level (never bodies, which would put
  Secret contents in a plaintext file), with `None` rules for the
  control plane's own reads, leases and health endpoints, which are no
  evidence and would fill the datastore's volume; rotated 30 days, 3 backups,
  64MB.
- **The kubeconfig is written 0600**, as defence in depth; the guard is what
  closes the cross-machine read.
- **sshd is hardened by a drop-in** with `Include` forced to the top of
  `sshd_config` (the first occurrence of a keyword wins, so an Include at the
  bottom is inert) and two-stage validation: the candidate file before it
  moves, then `sshd -t` on the effective config, with a rescue that removes
  the drop-in rather than restart into a lockout. The CI deploy key's public
  half is installed here (rotation:
  [Operate](../guides/operate.md#rotating-credentials)).
- **Tailscale is joined by one script**, `tailscale-autoauth.sh`, run by a
  unit at every boot (a node-key expiry leaves tailscaled "Logged out" after
  a reboot, and a logged-out node NXDOMAINs the registry, so every pod
  ImagePullBackOffs and Cloudflare 503s) and by the play. It is the only
  spelling of `tailscale up`: `--accept-dns=true` is load-bearing (MagicDNS
  resolves the `*.ts.net` targets), and `--snat-subnet-routes=false`
  overrides a default that tailscaled 1.102 started applying to every
  forwarded packet, which made klipper-lb see 10.42.0.1 instead of a tailnet
  source and drop every SYN (seen 2026-09-19).
- **fail2ban and auditd are absent on purpose**: fail2ban would guard a public
  SSH port that does not exist, and auditd needs `CAP_AUDIT_*`, which the
  hypervisor withholds.

## Consequences

- Dev machines beside the cluster should be created with `--isolated`;
  `--isolate-network` does not block peers, despite the docs, which is why
  the guard exists. The node itself cannot be `--isolated` (kubelet's
  `noswap` tmpfs is refused and k3s restart-loops).
- Tailnet reachability must be tested from a peer, never from the node,
  whose own traffic takes the OUTPUT path
  ([Operate](../guides/operate.md#the-two-things-that-will-bite)).
- Comments inside the rendered host files (nftables, k3s config) are file
  content: editing them re-renders the file and fires its handler.
