# Vendored kubeconform schemas

Overrides for CRD schemas whose copy in the
[datreeio CRDs-catalog](https://github.com/datreeio/CRDs-catalog) differs from the
CRD this repo installs. `validate.yaml` tries this directory first, then the core
kinds, then the catalog. Vendoring keeps the check that `-ignore-missing-schemas`
or `-skip` would drop. Layout: `<kind>_<version>.json`, kubeconform's
`{{.ResourceKind}}_{{.ResourceAPIVersion}}.json`.

| File                            | Tracks                                                           | Why it is here                                                                                                                                             |
| ------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infisicalsecret_v1alpha1.json` | the `infisical` release in `src/kubernetes/helmfile.yaml.gotmpl` | the catalog sets `additionalProperties: false` everywhere; the operator's CRD does not, and the API server prunes unknown fields rather than refusing them |

## Regenerating

Run it whenever the `infisical` release's `version:` moves; nothing checks the
pair ([Hand-synced pairs](../../../docs/reference/hand-synced-pairs.md)), and a stale
file validates against a CRD the cluster no longer has. Do not hand-edit the
result: the CRD's `openAPIV3Schema` is the schema, plus kubeconform's `$schema`.

```bash
VERSION=$(awk '/chart: infisical\/secrets-operator/ {found=1} \
  found && /^ *version:/ {gsub(/"/,"",$2); print $2; exit}' \
  src/kubernetes/helmfile.yaml.gotmpl)

helm repo add infisical https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
helm repo update infisical
helm template infisical infisical/secrets-operator --version "$VERSION" --include-crds \
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
        name = version["name"]
        path = f"src/kubernetes/schemas/infisicalsecret_{name}.json"
        with open(path, "w") as fh:
            json.dump(out, fh, indent=2)
            fh.write("\n")
        print("wrote", path)
'
```

Once the catalog matches, delete the file; if validation still passes, the
override held nothing.
