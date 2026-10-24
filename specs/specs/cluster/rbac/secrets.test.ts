import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import { review } from './__setup__/review.ts';

// invariant: who may read every Secret of the cluster, and why; anyone else is a leak whatever admission
// says, since admission never sees a read (docs/decisions/017-app-repositories-deploy-as-their-github-oidc-identity.md).
const MAY_LIST_EVERY_SECRET: Record<string, string> = {
    'kube-system:generic-garbage-collector':
        'the garbage collector deletes the dependents of every object',
    'kube-system:helm-gateway-api-crd':
        "k3s' helm-controller installs the bundled charts as cluster-admin",
    'kube-system:helm-traefik': "k3s' helm-controller installs the bundled charts as cluster-admin",
    'kube-system:helm-traefik-crd':
        "k3s' helm-controller installs the bundled charts as cluster-admin",
    'kube-system:namespace-controller':
        'the namespace controller empties a namespace being deleted',
    'kube-system:resourcequota-controller':
        'the quota controller counts every object a quota covers',
    'kube-system:storage-version-migrator-controller':
        'the migrator rewrites stored objects to the current version',
    'kube-system:traefik':
        'Traefik reads the TLS Secret each IngressRoute names, in every namespace',
    'platform-networking:cert-manager':
        'cert-manager writes each certificate into the namespace that asked',
    'platform-networking:cert-manager-cainjector':
        'the cainjector reads CA Secrets to patch webhook configurations',
    'platform-secrets:infisical-secre-controller-manager':
        'the Infisical operator writes the Secrets of every app namespace',
    'platform-telemetry:kube-state-metrics':
        "kube-state-metrics' secrets collector exports each Secret's metadata",
};

describe('secrets', () => {
    test('no service account outside the allow-list can list secrets cluster-wide', async () => {
        // Given - every service account of the cluster
        const accounts = await kubectlList(['serviceaccounts', '--all-namespaces']);
        const names = accounts.items.map(
            (account) => `${account.metadata.namespace ?? ''}:${account.metadata.name}`,
        );

        // When - each is asked whether it may list Secrets across all namespaces
        const allowed = await review(
            accounts.items.map((account) => {
                const namespace = account.metadata.namespace ?? '';

                return {
                    groups: [
                        'system:serviceaccounts',
                        `system:serviceaccounts:${namespace}`,
                        'system:authenticated',
                    ],
                    resource: 'secrets',
                    user: `system:serviceaccount:${namespace}:${account.metadata.name}`,
                    verb: 'list',
                };
            }),
        );

        // Then - the accounts that may are exactly the allow-listed ones this cluster runs: one more is a leak, one fewer an entry to delete
        expect(names.filter((_, index) => allowed[index] === true).toSorted()).toStrictEqual(
            Object.keys(MAY_LIST_EVERY_SECRET)
                .filter((name) => names.includes(name))
                .toSorted(),
        );
    });
});
