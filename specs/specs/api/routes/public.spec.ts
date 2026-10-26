import { describe, expect, test } from 'vitest';

import { api, publicRoutes } from '../api.specification.ts';
import { contractGolden, exchange } from './__setup__/exchange.ts';

describe('public', () => {
    test.each(publicRoutes)(
        '$host$probe.path answers its contract ($origin, $contract)',
        async (route) => {
            // Given - a public route, asked what its studio.jterrazz.com/smoke-* annotations say, through the Cloudflare tunnel
            const result = await exchange(api, route);

            // Then - a status the contract accepts, and the Location it names; a redirect is the answer, never followed
            expect(result.response).toMatch(contractGolden(route, result.response.status));
        },
    );
});
