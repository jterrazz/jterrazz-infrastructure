import { kubectl } from '../../../__setup__/kubectl.ts';

/** One question put to the authorizer: may this identity do this verb on this resource, in this namespace or (none) all of them. */
export type Access = {
    groups: string[];
    namespace?: string;
    resource: string;
    subresource?: string;
    user: string;
    verb: string;
};

/** Asks the API server's authorizer every question in one SubjectAccessReview batch, and answers them in order. */
export async function review(questions: readonly Access[]): Promise<boolean[]> {
    const reviews = questions.map(({ groups, user, ...attributes }) => ({
        apiVersion: 'authorization.k8s.io/v1',
        kind: 'SubjectAccessReview',
        spec: { groups, resourceAttributes: attributes, user },
    }));
    const outcome = await kubectl(
        ['create', '-f', '-', '-o', String.raw`jsonpath={.status.allowed}{"\n"}`],
        JSON.stringify({ apiVersion: 'v1', items: reviews, kind: 'List' }),
    );
    const answers = outcome.stdout.split('\n').filter((line) => line !== '');
    if (outcome.code !== 0 || answers.length !== questions.length) {
        throw new Error(
            `the SubjectAccessReview batch answered ${String(answers.length)} of ${String(questions.length)} questions: ${outcome.stderr.trim()}`,
        );
    }

    return answers.map((answer) => answer === 'true');
}
