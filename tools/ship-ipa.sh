#!/usr/bin/env bash
# Build Madeira, upload it to the signing service and wait until it is signed.
#
# Usage: tools/ship-ipa.sh [--ipa PATH]
# Needs ~/.config/madeira-signer/env (mode 600) with SIGNER_URL and SIGNER_API_KEY
# (see docs/BUILDING.md). Prints the app's install page when done.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${MADEIRA_SIGNER_CONFIG:-$HOME/.config/madeira-signer}"
ENV_FILE="$CONFIG_DIR/env"
IPA=""

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
json() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null; }

while [ $# -gt 0 ]; do
	case "$1" in
	--ipa) IPA="${2:?--ipa needs a path}"; shift 2 ;;
	-h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

[ -f "$ENV_FILE" ] || die "missing $ENV_FILE (SIGNER_URL, SIGNER_API_KEY); see docs/BUILDING.md"
[ "$(stat -f %Lp "$ENV_FILE")" = 600 ] || die "$ENV_FILE holds an API key; run: chmod 600 $ENV_FILE"
# shellcheck source=/dev/null
. "$ENV_FILE"
[ -n "${SIGNER_URL:-}" ] || die "SIGNER_URL is not set in $ENV_FILE"
[ -n "${SIGNER_API_KEY:-}" ] || die "SIGNER_API_KEY is not set in $ENV_FILE"
SIGNER_URL="${SIGNER_URL%/}"
case "$SIGNER_URL" in https://* | http://localhost:* | http://127.0.0.1:*) ;; *) die "SIGNER_URL must use https" ;; esac

BODY="$(mktemp)"
REQUEST="$(mktemp)"
R2_BODY="$(mktemp)"
trap 'rm -f "$BODY" "$REQUEST" "$R2_BODY"' EXIT
# Calls the API with the key passed on stdin (never visible in ps). Extra curl args follow the path.
# The body goes to a file that curl truncates on every retry, so only the last attempt's body is kept.
# Returns non-zero (with the reason in $BODY or on stderr) on a curl failure or an HTTP status >= 400.
api_raw() {
	local method="$1" path="$2" code
	shift 2
	: >"$BODY"
	code="$(printf 'header = "x-api-key: %s"\n' "$SIGNER_API_KEY" | curl -sS -o "$BODY" -w '%{http_code}' --max-time 60 \
		--retry 3 --retry-delay 2 --retry-connrefused -K - -X "$method" -H 'content-type: application/json' "$@" "$SIGNER_URL/api$path")" || return 1
	[ "$code" -lt 400 ]
}
api() {
	if ! api_raw "$@"; then die "$1 $2 failed: $(json "$(cat "$BODY")" message || cat "$BODY")"; fi
	cat "$BODY"
}
# Like api, but quiet and never fatal: the poll loop uses it to ride out service restarts.
api_soft() {
	api_raw "$@" 2>/dev/null || return 1
	cat "$BODY"
}

[ -n "$IPA" ] || IPA="$("$ROOT/tools/build-unsigned-ipa.sh")"
[ -f "$IPA" ] || die "no such IPA: $IPA"
SIDECAR="${IPA%.ipa}.json"
[ -f "$SIDECAR" ] || die "missing $SIDECAR; build with tools/build-unsigned-ipa.sh"

cp "$SIDECAR" "$REQUEST"
plutil -insert size -integer "$(stat -f%z "$IPA")" "$REQUEST"
plutil -insert sha256 -string "$(shasum -a 256 "$IPA" | cut -d' ' -f1)" "$REQUEST"
plutil -convert json "$REQUEST"

log "Registering $(basename "$IPA")…"
created="$(api POST /builds --data-binary "@$REQUEST")"
BUILD_ID="$(json "$created" buildId)"
UPLOAD_URL="$(json "$created" uploadUrl)"
APP_URL="$(json "$created" appUrl)"

log "Uploading $(du -h "$IPA" | cut -f1 | tr -d ' ')…"
# The progress bar goes to stderr; R2's XML error body (e.g. bad credentials, expired URL) lands in R2_BODY.
if ! curl --fail-with-body --progress-bar -H 'Expect:' -T "$IPA" "$UPLOAD_URL" -o "$R2_BODY"; then
	die "upload to R2 failed: $(cat "$R2_BODY")"
fi
api POST "/builds/$BUILD_ID/complete" --data '{}' >/dev/null

log "Waiting for signing…"
last=""
outage=""
deadline=$(($(date +%s) + 1800))
while :; do
	status=""
	build="$(api_soft GET "/builds/$BUILD_ID")" && status="$(json "$build" status)" || status=""
	if [ -z "$status" ]; then
		if [ -z "$outage" ]; then log "  (service unreachable, retrying)"; outage=1; fi
	else
		outage=""
		if [ "$status" != "$last" ]; then log "  $status"; last="$status"; fi
		case "$status" in
		signed) break ;;
		failed) die "signing failed: $(json "$build" error)" ;;
		esac
	fi
	[ "$(date +%s)" -lt "$deadline" ] || die "timed out waiting for build $BUILD_ID (it may still finish; check $APP_URL)"
	sleep 3
done

log "Signed. Install from: $APP_URL"
if command -v qrencode >/dev/null; then qrencode -t ansiutf8 "$APP_URL" >&2; fi
printf '%s\n' "$APP_URL"
