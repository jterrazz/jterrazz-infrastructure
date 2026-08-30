# Vendored kubeconform schemas

Overrides for CRD schemas whose copy in the
[datreeio CRDs-catalog](https://github.com/datreeio/CRDs-catalog) is behind the
chart version this repo actually installs. `.github/workflows/validate.yaml`
lists this directory **first** in `KUBECONFORM_SCHEMA_ARGS`, so a file here wins;
kinds with no file here fall through to `default` and then to the catalog.

This exists only because the alternative was worse. The other two ways out of a
stale catalog schema are `-ignore-missing-schemas` (which silently stops
validating the kind) and `-skip <Kind>` (same, but explicit) — both trade a real
check for a green tick. Vendoring keeps the check and makes the divergence a
reviewable file.

## Layout

`<group>/<lowercased kind>_<version>.json`, matching kubeconform's
`{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json` template.

## What is here, and why

| File | Chart it tracks | How the catalog copy differs |
| ---- | --------------- | -------------------------------- |
| `secrets.infisical.com/infisicalsecret_v1alpha1.json` | `infisical/secrets-operator`, pinned by the `infisical` release in `kubernetes/helmfile.yaml.gotmpl` | The catalog copy sets `additionalProperties: false` at every object level; the operator's own CRD does not, because the API server *prunes* unknown fields rather than refusing the object. That is the only remaining divergence — see "One difference from the catalog" below, and "Deleting a file here". |

## Regenerating

Run this whenever the `infisical` release's `version:` moves — that is the
**hand-synced pair** this directory creates, and it is in the table in
[CLAUDE.md](../../CLAUDE.md). Nothing checks it automatically: a stale file here
validates against a CRD the cluster no longer has, and the failure surfaces at
`kubectl apply` time instead of at PR time.

```bash
VERSION=$(awk '/chart: infisical\/secrets-operator/ {found=1} \
  found && /^ *version:/ {gsub(/"/,"",$2); print $2; exit}' \
  kubernetes/helmfile.yaml.gotmpl)

helm repo add infisical \
  https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
helm repo update infisical
helm template infisical infisical/secrets-operator \
  --version "$VERSION" --include-crds \
  | python3 -c '
import collections, json, sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get("kind") != "CustomResourceDefinition":
        continue
    if doc["metadata"]["name"] != "infisicalsecrets.secrets.infisical.com":
        continue
    for version in doc["spec"]["versions"]:
        out = collections.OrderedDict()
        out["$schema"] = "http://json-schema.org/draft-07/schema#"
        out.update(version["schema"]["openAPIV3Schema"])
        path = ("kubernetes/schemas/secrets.infisical.com/"
                f"infisicalsecret_{version[\"name\"]}.json")
        with open(path, "w") as fh:
            json.dump(out, fh, indent=2)
            fh.write("\n")
        print("wrote", path)
'
```

The transform is deliberately trivial — the CRD's `openAPIV3Schema` **is** a JSON
Schema; the only addition is the `$schema` line kubeconform wants. Do not
hand-edit the result.

## One difference from the catalog, on purpose

The vendored schema does **not** reject unknown properties under `spec`, because
the upstream CRD's structural schema does not either — the API server *prunes*
unknown fields rather than refusing the object. That makes kubeconform agree with
what `kubectl apply` would actually do, at the cost of not catching a typo'd key
(a typo'd key is silently dropped by the cluster too, so the check was never the
thing protecting against it). Type and shape errors are still caught: verified
that `managedKubeSecretReferences` as a map and `syncConfig.resyncInterval` as an
integer both fail.

This is now the **whole** difference. A field-by-field diff of the vendored file
against the catalog copy at operator 0.11.5 finds no other divergence: same
properties (`syncConfig` included), same `required` lists, same types. Neither
schema requires the deprecated flat `spec.resyncInterval`, and no manifest in
this repo sets `syncConfig` at all — they use `managedKubeSecretReferences`.

## Deleting a file here

Once the catalog catches up, drop the file and re-run the raw-manifest
validation. If it still passes, the override was load-bearing for nothing and the
directory shrinks. That is the goal — this directory should never grow a second
entry that nobody has re-checked.
