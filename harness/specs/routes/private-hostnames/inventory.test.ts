import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { parse } from 'yaml';

import { REPOSITORY_ROOT } from '../../../src/cluster/kubectl.ts';
import { discoverRoutes } from '../../__setup__/routes.ts';

// outside: the one private-hostname fact the cluster cannot supply: CoreDNS needs the name
// before any route exists (docs/decisions/012-private-hostnames-are-wildcard-zones.md).
function configuredPrivateHostnames(): string[] {
    const groupVars: unknown = parse(
        readFileSync(`${REPOSITORY_ROOT}ansible/inventories/group_vars/all.yml`, 'utf8'),
    );
    const read = (key: string): string[] => {
        const value: unknown =
            typeof groupVars === 'object' && groupVars !== null
                ? Reflect.get(groupVars, key)
                : undefined;
        if (!Array.isArray(value)) {
            throw new TypeError(`group_vars/all.yml holds no \`${key}:\` list`);
        }

        return value.map(String);
    };

    return [...read('private_hostnames'), ...read('private_hostnames_via_traefik')];
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
