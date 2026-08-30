#!/bin/bash
# Black-box smoke test: does every surface this cluster is supposed to serve
# actually answer, and are its certificates still valid?
#
# Nothing here talks to the Kubernetes API. That is the point — `kubectl get
# pods` being green has never been the same claim as "the site loads". These
# checks go in the front door: public hostnames through the Cloudflare tunnel,
# private hostnames over the tailnet, TLS from the wire.
#
# Usage:
#   ./scripts/smoke.sh                        # public surfaces only (default)
#   ./scripts/smoke.sh --private              # tailnet hosts too (needs tailnet)
#   ./scripts/smoke.sh --public --private --certs
#   ./scripts/smoke.sh --certs                # certs for the selected scopes
#
# Flags are additive; --public is implied when no scope flag is given. Exit
# status is 0 only if every check passed.
#
# --private and the private half of --certs require tailnet membership. On a
# GitHub runner that means the jterrazz-actions/actions/infra-connect step, the
# same one deploy-platform.yaml uses (.github/workflows/smoke.yaml does this).
# From the laptop it just means being logged into Tailscale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# THE TABLE — the only thing to edit when a surface is added or moved
# =============================================================================
# Format:  <method>|<url>|<accepted status codes, comma-separated>|<what it is>[|<expected Location>]
#
# The optional 5th field asserts the redirect TARGET. Use it on every redirect:
# a 301 to the wrong host is indistinguishable from a correct one by status.
#
# Accepted codes are a LIST because several of these surfaces have more than
# one legitimate answer (an app that redirects to a login page vs. one that
# serves it). Keep each list as narrow as the service genuinely allows: the
# whole value of this script is that a 502/503/000 can never be mistaken for
# "fine". Never add 000 (curl could not connect) or a 5xx to a list.
#
# No redirects are followed (`curl -L` is deliberately absent) — a 301 where a
# 200 belongs is exactly the kind of regression this should catch.

PUBLIC_CHECKS=(
    "GET|https://spwn.sh/|200|spwn-web landing page"
    "GET|https://sig.news/|200|signews-web landing page"
    "GET|https://clawssify.com/|200|clawssify-web landing page"
    "GET|https://clawrr.com/|200|clawrr web-landing"
    "GET|https://signews.jterrazz.com/api/|200|signews-api, prod"
    "GET|https://signews-next.jterrazz.com/api/|200|signews-api, next"
    "GET|https://signews-staging.jterrazz.com/api/|200|signews-api, staging"
    # OpenPanel event ingest. POST-only by design: only /api/track is routed on
    # this host (see kubernetes/services/openpanel/ingress.yaml), and a GET is
    # NOT a valid probe — it answers 404 whether op-api is healthy or not.
    # The POST below carries an empty JSON object, which reaches op-api and is
    # rejected for want of a client id: 401 is the proof the route is wired end
    # to end AND that ingest is not anonymous. (A body-less POST answers 400
    # and a non-JSON one 415 — both would also prove liveness, but 401 is the
    # only one that also asserts the auth check still runs.)
    "POST|https://analytics.jterrazz.com/api/track|401|OpenPanel ingest (unauthenticated POST must be rejected)"
    # jterrazz-web. www is canonical; the other two exist only to send callers
    # there, so each asserts its Location — a 301 to the wrong host is
    # indistinguishable from a correct one by status alone.
    "GET|https://www.jterrazz.com/|200|jterrazz-web (canonical host)"
    "GET|https://jterrazz.com/|301|jterrazz-web apex -> www|https://www.jterrazz.com/"
    "GET|https://blog.jterrazz.com/|301|jterrazz-web legacy blog subdomain -> articles|https://www.jterrazz.com/articles"
)

PRIVATE_CHECKS=(
    # Tailnet-only. Traefik's private-access / cluster-internal-access
    # ipAllowList sits in front of each, so a non-tailnet caller gets 403 and
    # this whole block fails — which is itself the correct answer to "is the
    # allow-list still doing its job".
    #
    # Grafana redirects an unauthenticated browser to /login (302). A 200 is
    # also acceptable: it is what an already-anonymous-allowed instance or a
    # future auth change would serve. Anything else means Grafana is down.
    "GET|https://grafana.internal.jterrazz.com/|302,200|Grafana"
    # The registry's own API root. 401 is the CORRECT answer — /v2/ demands a
    # bearer token, and containerd relies on that challenge to authenticate.
    # A 200 would mean the registry became anonymous-readable.
    "GET|https://registry.internal.jterrazz.com/v2/|401|Docker registry API"
    "GET|https://chat.internal.jterrazz.com/|200|LibreChat"
    # OpenPanel's dashboard SSRs and bounces an unauthenticated visitor to
    # /login or /onboarding, so 307 is the normal answer and 200 is the
    # already-rendered one.
    "GET|https://openpanel.internal.jterrazz.com/|307,200|OpenPanel dashboard"
    # gateway-intelligence is an OpenAI-compatible API with no route mounted at
    # `/`, so upstream answers 404 — which still proves DNS, the tailnet path,
    # Traefik and the pod are all alive. 200 is accepted in case a root handler
    # is ever added. The point of this entry is to exclude 000/502/503.
    "GET|https://gateway-intelligence.internal.jterrazz.com/|200,404|gateway-intelligence (root is unrouted; 404 = alive)"
)

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

usage() {
    cat <<'EOF'
Usage: scripts/smoke.sh [--public] [--private] [--certs] [--help]

  --public    Public hostnames through the Cloudflare tunnel. The default when
              no scope flag is given.
  --private   Tailnet-only hostnames. Requires tailnet membership.
  --certs     TLS expiry check for every host in the selected scopes.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --public) want_public=true ;;
        --private) want_private=true ;;
        --certs) want_certs=true ;;
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

host_of() {
    local url="${1#https://}"
    printf '%s' "${url%%/*}"
}

# ---------------------------------------------------------------------------

selected=()
$want_public && selected+=("${PUBLIC_CHECKS[@]}")
$want_private && selected+=("${PRIVATE_CHECKS[@]}")

section "HTTP checks"
for entry in "${selected[@]}"; do
    IFS='|' read -r method url codes label want_location <<<"$entry"
    run_http_check "$method" "$url" "$codes" "$label" "$want_location"
done

if $want_certs; then
    section "TLS expiry (fail under ${CERT_MIN_DAYS} days)"
    seen=""
    for entry in "${selected[@]}"; do
        IFS='|' read -r _ url _ _ <<<"$entry"
        host="$(host_of "$url")"
        # Several checks share a hostname (and several hostnames share one
        # certificate); probe each host once.
        case " $seen " in
            *" $host "*) continue ;;
        esac
        seen="$seen $host"
        run_cert_check "$host"
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
