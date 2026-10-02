#!/usr/bin/env bash
# Build Madeira, upload it to the signing service and wait until it is signed.
#
# Usage: tools/ship-ipa.sh [--ipa PATH | --clean]
# --clean deletes the IPAs in build/ipa/ (and their .json files) and exits without building.
# Needs ~/.config/madeira-signer/env (mode 600) with SIGNER_URL and SIGNER_API_KEY
# (see docs/BUILDING.md). Prints the app's install page when done.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${MADEIRA_SIGNER_CONFIG:-$HOME/.config/madeira-signer}"
ENV_FILE="$CONFIG_DIR/env"
IPA=""
CLEAN=""

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
json() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null; }

while [ $# -gt 0 ]; do
	case "$1" in
	--ipa) IPA="${2:?--ipa needs a path}"; shift 2 ;;
	--clean) CLEAN=1; shift ;;
	-h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done

if [ -n "$CLEAN" ]; then
	[ -z "$IPA" ] || die "--clean and --ipa cannot be combined"
	shopt -s nullglob
	files=("$ROOT"/build/ipa/*.ipa "$ROOT"/build/ipa/*.json)
	[ ${#files[@]} -gt 0 ] || { log "No IPAs in build/ipa/."; exit 0; }
	ipas=("$ROOT"/build/ipa/*.ipa)
	rm -f "${files[@]}"
	log "Deleted ${#ipas[@]} IPA(s) from build/ipa/."
	exit 0
fi

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
# Returns 0 on success; 1 on a curl failure (no HTTP response); 2 on a client error (4xx other than 408/429);
# 3 on a transient status (5xx, 408, 429). The reason is in $BODY or on stderr.
api_raw() {
	local method="$1" path="$2" code
	shift 2
	: >"$BODY"
	code="$(printf 'header = "x-api-key: %s"\n' "$SIGNER_API_KEY" | curl -sS -o "$BODY" -w '%{http_code}' --max-time 60 \
		--retry 3 --retry-delay 2 --retry-connrefused -K - -X "$method" -H 'content-type: application/json' "$@" "$SIGNER_URL/api$path")" || return 1
	case "$code" in
	[23]??) return 0 ;;
	408 | 429 | 5??) return 3 ;;
	*) return 2 ;;
	esac
}
api_die() { die "$1 $2 failed: $(json "$(cat "$BODY")" message || cat "$BODY")"; }
# Calls the API and prints the body. Rides out a deploy: transient failures (no response, 5xx, 408, 429)
# are retried for about 2 minutes. A client error (e.g. 409) still dies at once.
api_retry() {
	local rc deadline warned=""
	deadline=$(($(date +%s) + 120))
	while :; do
		rc=0
		api_raw "$@" 2>/dev/null || rc=$?
		case "$rc" in
		0) cat "$BODY"; return 0 ;;
		2) api_die "$@" ;;
		esac
		if [ "$(date +%s)" -ge "$deadline" ]; then
			[ -s "$BODY" ] || die "$1 $2 failed: service unreachable"
			api_die "$@"
		fi
		if [ -z "$warned" ]; then log "  (service unavailable, retrying)"; warned=1; fi
		sleep 5
	done
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
created="$(api_retry POST /builds --data-binary "@$REQUEST")"
BUILD_ID="$(json "$created" buildId)"
UPLOAD_URL="$(json "$created" uploadUrl)"
APP_URL="$(json "$created" appUrl)"

log "Uploading $(du -h "$IPA" | cut -f1 | tr -d ' ')…"
# The progress bar goes to stderr; R2's XML error body (e.g. bad credentials, expired URL) lands in R2_BODY.
if ! curl --fail-with-body --progress-bar -H 'Expect:' -T "$IPA" "$UPLOAD_URL" -o "$R2_BODY"; then
	die "upload to R2 failed: $(cat "$R2_BODY")"
fi
api_retry POST "/builds/$BUILD_ID/complete" --data '{}' >/dev/null

log "Waiting for signing…"
last=""
outage=""
deadline=$(($(date +%s) + 1800))
while :; do
	rc=0
	api_raw GET "/builds/$BUILD_ID" 2>/dev/null || rc=$?
	# Only transient failures (no response, 5xx, 408, 429) are retried; a client error dies at once.
	[ "$rc" -ne 2 ] || api_die GET "/builds/$BUILD_ID"
	status=""
	note="service unreachable"
	if [ "$rc" -eq 0 ]; then
		build="$(cat "$BODY")"
		status="$(json "$build" status)" || status=""
		note="unexpected response"
	fi
	if [ -z "$status" ]; then
		if [ "$outage" != "$note" ]; then log "  ($note, retrying)"; outage="$note"; fi
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
