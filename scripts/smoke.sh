#!/bin/bash
# Black-box smoke test: does every surface this cluster is supposed to serve
# actually answer, and are its certificates still valid?
#
# The PROBES go in the front door — public hostnames through the Cloudflare
# tunnel, private hostnames over the tailnet, TLS from the wire. `kubectl get
# pods` being green has never been the same claim as "the site loads".
#
# What comes from the API server is only the QUESTION LIST. Every IngressRoute
# in the cluster carries its own smoke contract as annotations (the charts stamp
# them; a hand-written route writes them), so this script holds no table of
# hostnames or status codes for services it does not deploy:
#
#   smoke.jterrazz.com/path      externally-visible path to probe
#   smoke.jterrazz.com/expect    accepted status codes, comma-separated
#   smoke.jterrazz.com/method    default GET
#   smoke.jterrazz.com/location  asserts the Location header (redirects)
#   smoke.jterrazz.com/probe     "false" opts the route out
#
# The contract is kubernetes/charts/common/templates/_smoke.tpl. A route with no
# annotation is still probed — GET / expecting 200 — and REPORTED, because an
# unannotated route is an app that has not redeployed onto the current chart,
# not a surface nobody cares about.
#
# Usage:
#   ./scripts/smoke.sh                        # public surfaces only (default)
#   ./scripts/smoke.sh --private              # tailnet hosts too (needs tailnet)
#   ./scripts/smoke.sh --public --private --certs
#   ./scripts/smoke.sh --certs                # certs for the selected scopes
#   ./scripts/smoke.sh --list                 # print the discovered checks, probe nothing
#
# Flags are additive; --public is implied when no scope flag is given. Exit
# status is 0 only if every check passed.
#
# HOW IT SEES THE CLUSTER: `cluster_kubectl` in scripts/lib/common.sh, shared
# with trigger-app-deploys.sh — CLUSTER_KUBECTL, CLUSTER_SSH_KEY, or a
# kubeconfig. No new secret either way.
#
# --private and the private half of --certs require tailnet membership. On a
# GitHub runner that means the jterrazz-actions/actions/infra-connect step, the
# same one deploy-platform.yaml uses. From the laptop it just means being
# logged into Tailscale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Fail a certificate that expires within this many days. Let's Encrypt renews
# at 30 days remaining via cert-manager, so 15 means "renewal has been failing
# for two weeks" — an alert, not a routine reminder.
CERT_MIN_DAYS=15

# Per-request ceiling. Generous: a cold Next.js pod can take a few seconds.
CURL_TIMEOUT=15

# =============================================================================

want_public=false
want_private=false
want_certs=false
list_only=false

usage() {
    cat <<'EOF'
Usage: scripts/smoke.sh [--public] [--private] [--certs] [--list] [--help]

  --public    Public hostnames through the Cloudflare tunnel. The default when
              no scope flag is given.
  --private   Tailnet-only hostnames. Requires tailnet membership.
  --certs     TLS expiry check for every host in the selected scopes.
  --list      Print the discovered check list and exit without probing.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --public) want_public=true ;;
        --private) want_private=true ;;
        --certs) want_certs=true ;;
        --list) list_only=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown flag: $arg"
            usage >&2
            exit 2
            ;;
    esac
done

# --certs on its own still needs something to check certificates FOR.
if ! $want_public && ! $want_private; then
    want_public=true
fi

passed=0
failed=0
declare -a failures=()

record_pass() {
    success "PASS  $1"
    passed=$((passed + 1))
}

record_fail() {
    error "FAIL  $1"
    failed=$((failed + 1))
    failures+=("$1")
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# Every IngressRoute in the cluster, as JSON. Fails loudly rather than returning
# nothing: an empty list would report "0 failures" about a cluster that is
# entirely down, which is the worst answer this script could give.
ingressroutes_json() {
    cluster_kubectl get ingressroute.traefik.io -A -o json
}

# JSON in, one PIPE-separated check per line out:
#   scope|method|url|codes|location|source|origin
# Pipe, not tab: bash `read` collapses runs of IFS *whitespace*, so a tab-
# separated line with an empty `location` would silently shift every field after
# it. No URL or status list contains a pipe.
# where `source` is annotated | fallback | skipped and `origin` is
# <namespace>/<name>. Also emits `!<message>` lines for the private-hostname
# cross-check, which replaces the static assertion this script used to need.
#
# Inline rather than a scripts/*.py of its own: it has exactly one caller, and a
# separate file would need adding to the two python-syntax lists (Makefile and
# validate.yaml) — one more pair to keep in sync, which is what this whole
# change is removing.
# shellcheck disable=SC2016  # this is a Python program, not a shell string
DISCOVER_PY='
import json, re, sys

HOST = re.compile(r"Host\(`([^`]+)`\)")
ACCESS = {"private-access", "cluster-internal-access"}
A = "smoke.jterrazz.com/"

doc = json.load(sys.stdin)
if not doc.get("items"):
    sys.exit("the cluster returned no IngressRoutes at all")
private_hosts = set()

for item in doc.get("items", []):
    meta = item.get("metadata", {})
    origin = "%s/%s" % (meta.get("namespace", "?"), meta.get("name", "?"))
    ann = meta.get("annotations") or {}
    hosts, gated = [], False
    for route in (item.get("spec") or {}).get("routes", []):
        for h in HOST.findall(route.get("match", "")):
            if h not in hosts:
                hosts.append(h)
        for mw in route.get("middlewares") or []:
            if mw.get("name") in ACCESS:
                gated = True
    if not hosts:
        print("!%s matches no Host() — nothing to probe" % origin)
        continue

    if str(ann.get(A + "probe", "")).lower() == "false":
        source = "skipped"
    elif A + "expect" in ann or A + "path" in ann:
        source = "annotated"
    else:
        source = "fallback"

    path = ann.get(A + "path", "/")
    codes = ann.get(A + "expect", "200")
    method = ann.get(A + "method", "GET")
    location = ann.get(A + "location", "")

    for host in hosts:
        # An ipAllowList in front of the route, or the private zone: either way
        # a non-tailnet caller cannot reach it. The middleware is the actual
        # enforcement; the suffix catches a route whose gate was dropped.
        scope = "private" if (gated or ".internal." in host) else "public"
        if scope == "private":
            private_hosts.add(host)
        if source == "skipped":
            print("|".join(["skip", "", host, "", "", source, origin]))
            continue
        url = "https://%s%s" % (host, path if path.startswith("/") else "/" + path)
        print("|".join([scope, method, url, codes, location, source, origin]))

# The one fact group_vars must hold that the cluster cannot supply: CoreDNS
# needs a private name before any route exists. Checked against reality here
# instead of against a second copy of the table in another file.
gv = open(sys.argv[1], encoding="utf-8").read().splitlines()
configured = set()
for key in ("private_hostnames", "private_hostnames_via_traefik"):
    if key + ":" not in gv:
        print("!cannot read the `%s:` list from %s" % (key, sys.argv[1]))
        continue
    # Blank and comment lines are skipped, not treated as the end of the block:
    # the entries carry per-entry comments, and a parser that stopped at the
    # first one would silently see a shorter list.
    for line in gv[gv.index(key + ":") + 1:]:
        entry = line.strip()
        if not entry or entry.startswith("#"):
            continue
        if not entry.startswith("- "):
            break
        configured.add(entry[2:].split("#")[0].strip())

for host in sorted(private_hosts - configured):
    print("!%s is served tailnet-only but is missing from private_hostnames "
          "(group_vars) — in-cluster lookups fall back to the public CNAME chain" % host)
for host in sorted(configured - private_hosts):
    print("!%s is in private_hostnames (group_vars) but no IngressRoute serves "
          "it — CoreDNS answers for a name nothing routes" % host)
'

section "Discovering surfaces from the cluster"

routes_json=""
if ! routes_json="$(ingressroutes_json 2>&1)"; then
    error "could not read IngressRoutes from the cluster:"
    printf '%s\n' "$routes_json" >&2
    cluster_access_hint
    exit 1
fi

discovered=""
if ! discovered="$(printf '%s' "$routes_json" |
    python3 -c "$DISCOVER_PY" "$REPO_DIR/ansible/inventories/group_vars/all.yml")"; then
    error "could not parse the IngressRoute list"
    exit 1
fi

declare -a checks=() notes=() fallbacks=() skips=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        '!'*) notes+=("${line#!}") ;;
        "skip|"*) skips+=("$line") ;;
        *)
            checks+=("$line")
            case "$line" in
                *"|fallback|"*) fallbacks+=("$line") ;;
            esac
            ;;
    esac
done <<<"$discovered"

if [ ${#checks[@]} -eq 0 ]; then
    error "discovery returned ZERO probeable routes. That is a broken cluster or a broken query, never 'nothing to check'."
    exit 1
fi

info "${#checks[@]} check(s) from $(printf '%s\n' "${checks[@]}" | cut -d'|' -f7 | sort -u | wc -l | tr -d ' ') IngressRoute(s)"

for entry in "${checks[@]}"; do
    IFS='|' read -r scope method url codes location _ origin <<<"$entry"
    printf '    %-7s %-4s %-58s %-9s %s\n' "$scope" "$method" "$url" "[$codes]" "$origin"
    [ -z "$location" ] || printf '    %-7s %-4s   -> %s\n' "" "" "$location"
done

if [ ${#fallbacks[@]} -gt 0 ]; then
    warn "${#fallbacks[@]} route(s) carry NO smoke annotation and were probed with the fallback (GET / -> 200):"
    for entry in "${fallbacks[@]}"; do
        IFS='|' read -r _ _ url _ _ _ origin <<<"$entry"
        warn "  - $origin ($url) — redeploy the app so its chart stamps the contract"
    done
fi

if [ ${#skips[@]} -gt 0 ]; then
    info "${#skips[@]} route(s) opted out (smoke.jterrazz.com/probe: \"false\"):"
    for entry in "${skips[@]}"; do
        IFS='|' read -r _ _ host _ _ _ origin <<<"$entry"
        info "  - $origin ($host)"
    done
fi

if $list_only; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

# curl's %{http_code} is 000 when the connection never completed (DNS failure,
# refused, timeout). That is always a failure — it can never be in an accepted
# list — but it is worth naming separately in the output, because "000" and
# "503" point at completely different things.
# Prints "<status> <location>" — the Location header is what makes a redirect
# check meaningful. A 301 to the WRONG place is still a 301, so asserting the
# status alone proves the host answers, not that it sends anyone anywhere useful.
http_status() {
    local method="$1" url="$2"
    local -a args=(
        -sS -o /dev/null
        --max-time "$CURL_TIMEOUT"
        --write-out '%{http_code} %{redirect_url}'
        --request "$method"
    )
    # A POST probe sends an empty JSON object. Without a JSON content type the
    # ingest endpoint answers 415 before it ever looks at credentials, which
    # would make the check pass for the wrong reason.
    if [ "$method" = "POST" ]; then
        args+=(--header 'Content-Type: application/json' --data '{}')
    fi
    curl "${args[@]}" "$url" 2>/dev/null || true
}

run_http_check() {
    local method="$1" url="$2" codes="$3" label="$4" want_location="${5:-}"
    local out status location

    out="$(http_status "$method" "$url")"
    status="${out%% *}"
    status="${status:-000}"
    location="${out#* }"

    if [[ ",$codes," != *",$status,"* ]]; then
        if [ "$status" = "000" ]; then
            record_fail "$method $url -> no response (DNS, connection or timeout after ${CURL_TIMEOUT}s)  ($label)"
        else
            record_fail "$method $url -> $status, expected one of [$codes]  ($label)"
        fi
        return
    fi

    if [ -n "$want_location" ] && [ "$location" != "$want_location" ]; then
        record_fail "$method $url -> $status but Location is '${location:-<none>}', expected '$want_location'  ($label)"
        return
    fi

    if [ -n "$want_location" ]; then
        record_pass "$method $url -> $status -> $location  ($label)"
    else
        record_pass "$method $url -> $status  ($label)"
    fi
}

# `openssl x509 -checkend` does the date arithmetic itself and exits non-zero
# when the certificate expires within the window — no date(1) parsing, which
# would need two different incantations for BSD and GNU.
run_cert_check() {
    local host="$1" chain enddate
    chain="$(echo | openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null)" || true

    if [ -z "$chain" ] || [[ "$chain" != *"BEGIN CERTIFICATE"* ]]; then
        record_fail "cert $host -> no certificate returned (TLS handshake failed)"
        return
    fi

    enddate="$(printf '%s' "$chain" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if printf '%s' "$chain" | openssl x509 -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1; then
        record_pass "cert $host -> valid past ${CERT_MIN_DAYS}d (notAfter ${enddate:-unknown})"
    else
        record_fail "cert $host -> expires within ${CERT_MIN_DAYS}d (notAfter ${enddate:-unknown}) — check cert-manager and the DNS-01 solver"
    fi
}

in_scope() {
    case "$1" in
        public) $want_public ;;
        private) $want_private ;;
        *) false ;;
    esac
}

section "HTTP checks"
for entry in "${checks[@]}"; do
    IFS='|' read -r scope method url codes location _ origin <<<"$entry"
    in_scope "$scope" || continue
    run_http_check "$method" "$url" "$codes" "$origin" "$location"
done

if $want_certs; then
    section "TLS expiry (fail under ${CERT_MIN_DAYS} days)"
    seen=""
    for entry in "${checks[@]}"; do
        IFS='|' read -r scope _ url _ _ _ _ <<<"$entry"
        in_scope "$scope" || continue
        host="${url#https://}"
        host="${host%%/*}"
        # Several checks share a hostname (and several hostnames share one
        # certificate); probe each host once.
        case " $seen " in
            *" $host "*) continue ;;
        esac
        seen="$seen $host"
        run_cert_check "$host"
    done
fi

# The live replacement for the static "every private hostname is probed"
# assertion: group_vars and the cluster are compared to each other, not to a
# third copy of the list.
if [ ${#notes[@]} -gt 0 ]; then
    section "Cluster vs. configuration"
    for note in "${notes[@]}"; do
        record_fail "$note"
    done
fi

section "Summary"
echo "  passed: $passed"
echo "  failed: $failed"

if [ "$failed" -gt 0 ]; then
    echo ""
    error "$failed check(s) failed:"
    for line in "${failures[@]}"; do
        error "  - $line"
    done
    exit 1
fi

success "All $passed checks passed."
