import { createMachine } from "./targets/orbstack";
import { createPrivateDnsRecords } from "./dns";

/**
 * The cluster's infrastructure: one OrbStack VM on the dev Mac, plus the
 * Cloudflare DNS records that point the private hostnames at it.
 *
 * SINGLE TARGET on purpose — do not reintroduce a `target` / `manageDns`
 * dispatch here. Adding a second stack means re-adding the `manageDns` guard
 * with it: with two stacks live and no guard, whichever one runs `pulumi up`
 * last silently owns every private CNAME. `docs/hetzner.md` has the recipe.
 *
 * No `sshHost` / `sshPrivateKey` output: OrbStack is reached through its own
 * SSH proxy (`root@jterrazz-infrastructure@orb`), so the Ansible inventory
 * needs nothing from Pulumi.
 */
const machine = createMachine();

createPrivateDnsRecords(machine.tailscaleHostname);
