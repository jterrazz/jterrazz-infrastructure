import { describe, expect, test } from 'vitest';

import { api, privateHosts, privateRoutes } from '../api.specification.ts';
import { contractGolden, exchange } from './__setup__/exchange.ts';

describe('private', () => {
    test.each(privateRoutes)(
        '$host$probe.path answers its contract from the tailnet ($origin, $contract)',
        async (route) => {
            // Given - a tailnet-only route, asked what its smoke.jterrazz.com/* annotations say, from a machine on the tailnet
            const result = await exchange(api, route);

            // Then - a status the contract accepts, and the Location it names
            expect(result.response).toMatch(contractGolden(route, result.response.status));
        },
    );

    test.each(privateHosts)('%s routes nothing that crossed Cloudflare', async (host) => {
        // Given - the private host, asked from the tailnet as the tunnel would deliver it: with the Cf-Ray header Cloudflare's edge stamps
        const result = await api
            .headers({ 'Cf-Ray': '0000000000000000-CDG' })
            .get(`https://${host}/`);

        // Then - no route matches: Traefik's own 404, never the app behind it
        expect(result.response).toMatch('HTTP/1.1 404 Not Found');
    });
});
