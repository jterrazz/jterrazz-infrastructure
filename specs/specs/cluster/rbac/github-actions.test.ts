import { describe, expect, test } from 'vitest';

import { kubectlList } from '../../__setup__/kubectl.ts';
import { review } from './__setup__/review.ts';
import type { Access } from './__setup__/review.ts';

// invariant: a repository that owns no namespace: what it may do is what the GROUP may, which every
// jterrazz repository's CI holds (src/ansible/roles/k3s/templates/authentication.yaml.j2).
const ANY_REPOSITORY = {
    groups: ['github-actions:jterrazz', 'system:authenticated'],
    user: 'github:jterrazz/platform-contract-probe',
};

describe('github-actions', () => {
    test('the github-actions group can create namespaces, and can neither list secrets nor exec into a pod anywhere', async () => {
        // Given - every namespace, and the cluster as a whole
        const namespaces = await kubectlList(['namespaces']);
        const questions: [string, Access][] = [
            ['create namespaces', { ...ANY_REPOSITORY, resource: 'namespaces', verb: 'create' }],
            [
                'list secrets in every namespace',
                { ...ANY_REPOSITORY, resource: 'secrets', verb: 'list' },
            ],
            ...namespaces.items.flatMap(({ metadata: { name } }): [string, Access][] => [
                [
                    `list secrets in ${name}`,
                    { ...ANY_REPOSITORY, namespace: name, resource: 'secrets', verb: 'list' },
                ],
                [
                    `exec into a pod in ${name}`,
                    {
                        ...ANY_REPOSITORY,
                        namespace: name,
                        resource: 'pods',
                        subresource: 'exec',
                        verb: 'create',
                    },
                ],
            ]),
        ];

        // When - the authorizer answers each question for the group
        const allowed = await review(questions.map(([, access]) => access));

        // Then - only the namespace creation app-deployer grants, which proves the reviewer answers at all
        expect(
            questions.filter((_, index) => allowed[index] === true).map(([label]) => label),
        ).toStrictEqual(['create namespaces']);
    });
});
