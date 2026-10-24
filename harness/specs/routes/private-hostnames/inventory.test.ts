import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { parse } from 'yaml';

import { REPOSITORY_ROOT } from '../../../src/cluster/kubectl.ts';
import { discoverRoutes } from '../../__setup__/routes.ts';

// outside: the one private-hostname fact the cluster cannot supply: CoreDNS needs the name
// before any route exists (ADR-012).
function configuredPrivateHostnames(): string[] {
    const groupVars: unknown = parse(
        readFileSync(`${REPOSITORY_ROOT}ansible/inventories/group_vars/all.yml`, 'utf8'),
    );
    const value: unknown =
        typeof groupVars === 'object' && groupVars !== null
            ? Reflect.get(groupVars, 'private_hostnames')
            : undefined;
    if (!Array.isArray(value)) {
        throw new TypeError('group_vars/all.yml holds no `private_hostnames:` list');
    }

    return value.map(String);
}

describe('inventory', () => {
    test('private_hostnames names exactly the hosts the cluster serves tailnet-only', async () => {
        // Given - the hosts the live IngressRoutes serve behind the tailnet gate
        const routes = await discoverRoutes();
        const served = new Set(routes.filter((route) => route.private).map((route) => route.host));

        // Then - group_vars and the cluster name the same set: a missing name falls back to the public CNAME chain in-cluster, an extra one is a name CoreDNS answers and nothing routes
        expect(configuredPrivateHostnames().toSorted()).toStrictEqual([...served].toSorted());
    });
});
