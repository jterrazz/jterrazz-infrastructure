import { describe, expect, test } from 'vitest';

import { certificateOf, publicHosts, SOUND_CERTIFICATE } from '../api.specification.ts';

describe('public', () => {
    test.each(publicHosts)(
        '%s presents a trusted certificate that covers it, 15 days from expiry or more',
        async (host) => {
            // Given - the host, asked over TLS from where the internet stands
            const certificate = await certificateOf(host);

            // Then - a certificate the system trusts, naming this host, with the margin
            expect(certificate).toStrictEqual(SOUND_CERTIFICATE);
        },
    );
});
