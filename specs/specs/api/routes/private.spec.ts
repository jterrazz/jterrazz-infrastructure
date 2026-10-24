import { describe, expect, test } from 'vitest';

import { api, privateRoutes } from '../api.specification.ts';
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
});
