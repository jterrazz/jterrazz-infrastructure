import { describe, expect, test } from 'vitest';

import { certificateOf, privateHosts, SOUND_CERTIFICATE } from '../api.specification.ts';

describe('private', () => {
    test.each(privateHosts)(
        '%s presents a trusted certificate that covers it, 15 days from expiry or more',
        async (host) => {
            // Given - the tailnet-only host, asked over TLS from the tailnet
            const certificate = await certificateOf(host);

            // Then - a certificate the system trusts, naming this host, with the margin
            expect(certificate).toStrictEqual(SOUND_CERTIFICATE);
        },
    );
});
