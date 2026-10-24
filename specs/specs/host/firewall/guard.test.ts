import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { parse } from 'yaml';

import { REPOSITORY_ROOT } from '../../__setup__/kubectl.ts';
import { onHost } from '../__setup__/shell.ts';

// outside: the interface the guard is scoped to, where roles/security reads it.
function guardInterface(): string {
    const defaults: unknown = parse(
        readFileSync(`${REPOSITORY_ROOT}src/ansible/roles/security/defaults/main.yml`, 'utf8'),
    );
    const value: unknown =
        typeof defaults === 'object' && defaults !== null
            ? Reflect.get(defaults, 'security_guard_interface')
            : undefined;
    if (typeof value !== 'string') {
        throw new TypeError('roles/security/defaults/main.yml holds no security_guard_interface');
    }

    return value;
}

describe('guard', () => {
    test('the guard table drops every node port and the tailnet path to the unauthenticated metrics', async () => {
        // Given - the nftables guard roles/security installs, as the kernel holds it
        const table = await onHost(['nft', 'list', 'table', 'inet', 'jterrazz_guard']);
        const drops = table.stdout
            .split('\n')
            .map((line) => line.trim())
            .filter((line) => line.endsWith(' drop') && !line.includes('saddr'));

        // Then - NodePorts dropped from every source on the bridge, node-exporter and the collector's metrics never served over tailscale0 (docs/decisions/006-the-host-has-no-public-inbound-path.md)
        const bridge = guardInterface();
        expect({ code: table.code, drops }).toStrictEqual({
            code: 0,
            drops: [
                `iif "${bridge}" tcp dport 30000-32767 drop`,
                `iif "${bridge}" udp dport 30000-32767 drop`,
                'iifname "tailscale0" tcp dport { 2000, 9100 } drop',
            ],
        });
    });
});
