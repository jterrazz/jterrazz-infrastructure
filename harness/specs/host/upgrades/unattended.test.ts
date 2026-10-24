import { describe, expect, test } from 'vitest';

import { onHost } from '../__setup__/shell.ts';

describe('unattended', () => {
    test('unattended-upgrades runs, and apt schedules it daily', async () => {
        // Given - the service, and the periodic setting apt's timers read
        const service = await onHost(['systemctl', 'is-active', 'unattended-upgrades']);
        const periodic = await onHost(['apt-config', 'dump', 'APT::Periodic::Unattended-Upgrade']);

        // Then - the service is active and the schedule asks for an upgrade every day
        expect({ periodic: periodic.stdout.trim(), service: service.stdout.trim() }).toStrictEqual({
            periodic: 'APT::Periodic::Unattended-Upgrade "1";',
            service: 'active',
        });
    });
});
