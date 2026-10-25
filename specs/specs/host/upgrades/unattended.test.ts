import { describe, expect, test } from 'vitest';

import { onHost } from '../__setup__/shell.ts';

// value: daily timer plus its randomized delay; three days is a run missed twice, not a late one.
const STALE_AFTER_SECONDS = 3 * 24 * 60 * 60;

describe('unattended', () => {
    test('apt runs unattended-upgrades daily, and has run it within three days', async () => {
        // Given - the timer that starts the run, the setting it reads, and the stamp a finished run leaves
        const [timer, periodic, stamp, now] = await Promise.all([
            onHost(['systemctl', 'is-enabled', 'apt-daily-upgrade.timer']),
            onHost(['apt-config', 'dump', 'APT::Periodic::Unattended-Upgrade']),
            onHost(['stat', '-c', '%Y', '/var/lib/apt/periodic/upgrade-stamp']),
            onHost(['date', '+%s']),
        ]);
        const age = Number(now.stdout) - Number(stamp.stdout);

        // Then - scheduled, asked for every day, and the last run recent: a configured timer that never fires stays red
        expect({
            periodic: periodic.stdout.trim(),
            recent: stamp.code === 0 && age < STALE_AFTER_SECONDS,
            timer: timer.stdout.trim(),
        }).toStrictEqual({
            periodic: 'APT::Periodic::Unattended-Upgrade "1";',
            recent: true,
            timer: 'enabled',
        });
    });
});
