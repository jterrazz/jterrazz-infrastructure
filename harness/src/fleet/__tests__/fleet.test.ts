import { describe, expect, test } from 'vitest';

import type { KubeObject } from '../../cluster/kubectl.ts';
import { fleetOf, snapshotOf } from '../fleet.ts';

const KEY = 'app.jterrazz.com/repository';

const namespace = (name: string, owner?: string): KubeObject => ({
    metadata: owner === undefined ? { name } : { labels: { [KEY]: owner }, name },
});

const deployment = (inNamespace: string, name: string, repository?: string): KubeObject => ({
    metadata:
        repository === undefined
            ? { name, namespace: inNamespace }
            : { annotations: { [KEY]: repository }, name, namespace: inNamespace },
});

describe('fleet', () => {
    test('reads one repository per app, and names the app Deployments that state none', () => {
        // Given - two app namespaces of one repository, one of another, and a platform namespace
        const namespaces = {
            items: [
                namespace('prod-signews-api', 'signews-api'),
                namespace('staging-signews-api', 'signews-api'),
                namespace('prod-spwn-web', 'spwn-web'),
                namespace('platform-registry'),
            ],
        };
        const deployments = {
            items: [
                deployment('prod-signews-api', 'signews-api', 'jterrazz/signews-api'),
                deployment('staging-signews-api', 'signews-api', 'jterrazz/signews-api'),
                deployment('prod-spwn-web', 'spwn-web'),
                deployment('platform-registry', 'registry'),
            ],
        };

        // Then - the repository once, the unannotated app named, the platform service ignored
        expect(fleetOf(namespaces, deployments)).toStrictEqual({
            repositories: ['jterrazz/signews-api'],
            unannotated: ['prod-spwn-web/spwn-web'],
        });
    });

    test('reads a snapshot file, comments and blank lines dropped', () => {
        // Given - a snapshot written by --dry-run, annotated by hand
        const text =
            'jterrazz/jterrazz-web\n\n# the gateway, rebuilt last\njterrazz/gateway-intelligence  # prod\n';

        // Then - the repositories, in order
        expect(snapshotOf(text)).toStrictEqual([
            'jterrazz/jterrazz-web',
            'jterrazz/gateway-intelligence',
        ]);
    });
});
