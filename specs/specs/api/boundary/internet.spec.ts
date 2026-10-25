import { describe, expect, test } from 'vitest';

import { api, privateHosts, publicHosts } from '../api.specification.ts';

// invariant: an outsider's request to a private host must never complete: its name resolves to
// a tailnet name no public resolver answers, or to an address only the tailnet routes.
const NEVER_ANSWERED = new Set(['dns', 'timeout', 'refused', 'no route']);

// invariant: the edge judges a request by its zone, not its host: one public front door per zone is every case.
const zoneOf = (host: string): string => host.split('.').slice(-2).join('.');
const doors = [...new Map(publicHosts.map((host) => [zoneOf(host), host])).values()];
const smuggled = doors.flatMap((entry) => privateHosts.map((asked) => ({ asked, entry })));

describe('internet', () => {
    test.each(privateHosts)('%s never answers a request from the internet', async (host) => {
        // Given - the private host, asked from a machine that is not on the tailnet
        const result = await api.get(`https://${host}/`);

        // Then - unresolvable or unreachable, never an answer of any status
        const reason = result.response.unreachable ?? '';
        expect(result.response).toMatch(
            `unreachable: ${NEVER_ANSWERED.has(reason) ? reason : 'dns'}`,
        );
    });

    test.each(smuggled)('$entry refuses a request that names $asked', async ({ asked, entry }) => {
        // Given - the public front door, asked for a private host in the Host header (the TLS name stays the public one)
        const result = await api.headers({ Host: asked }).get(`https://${entry}/`);

        // Then - Cloudflare refuses it at the edge: the tunnel never sees a private name
        expect(result.response).toMatch('HTTP/1.1 403 Forbidden');
    });
});
