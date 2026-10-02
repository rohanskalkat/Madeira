#!/usr/bin/env bash
# Build an unsigned Madeira IPA for the signing service.
#
# The build number goes above every earlier build: the service's next number
# for this app, the last number used on this Mac + 1, or Info.plist + 1,
# whichever is highest. It is written into the built app only, so the project
# and the source Info.plist stay untouched.
#
# Usage: tools/build-unsigned-ipa.sh [--build-number N] [--out DIR]
# Prints the IPA path on stdout; progress goes to stderr. Works with macOS bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${MADEIRA_SIGNER_CONFIG:-$HOME/.config/madeira-signer}"
STATE="$CONFIG_DIR/state"
OUT="$ROOT/build/ipa"
DERIVED="$ROOT/build/DerivedData"
BUILD_NUMBER=""

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
is_int() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
	case "$1" in
	--build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
	--out) OUT="${2:?--out needs a directory}"; shift 2 ;;
	-h | --help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
done
if [ -n "$BUILD_NUMBER" ] && ! is_int "$BUILD_NUMBER"; then die "--build-number must be a positive integer"; fi

# The Xcode build fails if the bundled licence copies are missing or stale.
"$ROOT/build/stage-licenses.sh" >&2

# The project bundles the Microsoft VC++ runtime from this git-ignored folder.
if ! ls "$ROOT/app/Madeira/x86_64-vcruntime/"*.dll >/dev/null 2>&1; then
	die "app/Madeira/x86_64-vcruntime/ has no DLLs; run tools/fetch-vcruntime.sh (see tools/fetch-vcruntime.md)"
fi

log "Building Madeira (Debug, unsigned)…"
xcodebuild -quiet \
	-project "$ROOT/app/Madeira.xcodeproj" -scheme Madeira -configuration Debug \
	-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >&2

APP="$DERIVED/Build/Products/Debug-iphoneos/Madeira.app"
[ -d "$APP" ] || die "the build finished but $APP is missing"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/Madeira.app"
PLIST="$STAGE/Payload/Madeira.app/Info.plist"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

BUNDLE_ID="$(plist_get CFBundleIdentifier)"
VERSION="$(plist_get CFBundleShortVersionString)"
SOURCE_BUILD="$(plist_get CFBundleVersion)"
NAME="$(plist_get CFBundleDisplayName || plist_get CFBundleName)"
is_int "$SOURCE_BUILD" || die "CFBundleVersion in Info.plist is not an integer: $SOURCE_BUILD"

state_get() {
	if [ -f "$STATE" ]; then awk -F= -v k="$1" '$1 == k { v = $2 } END { print v }' "$STATE"; fi
}
state_set() {
	mkdir -p "$CONFIG_DIR"
	{
		if [ -f "$STATE" ]; then awk -F= -v k="$1" '$1 != k' "$STATE"; fi
		printf '%s=%s\n' "$1" "$2"
	} >"$STATE.tmp"
	mv "$STATE.tmp" "$STATE"
}
server_next() {
	if [ ! -f "$CONFIG_DIR/env" ]; then return 0; fi
	# shellcheck source=/dev/null
	. "$CONFIG_DIR/env"
	if [ -z "${SIGNER_URL:-}" ] || [ -z "${SIGNER_API_KEY:-}" ]; then return 0; fi
	local body
	# The key goes in via stdin (-K -), so it never appears in the process list.
	if ! body="$(printf 'header = "x-api-key: %s"\n' "$SIGNER_API_KEY" | curl -fsS --max-time 10 -K - --get \
		--data-urlencode "bundleId=$BUNDLE_ID" "${SIGNER_URL%/}/api/next-build-number" 2>/dev/null)"; then
		log "warning: could not reach the signing service; using local build numbers"
		return 0
	fi
	printf '%s' "$body" | plutil -extract buildNumber raw -o - - 2>/dev/null || true
}

if [ -z "$BUILD_NUMBER" ]; then
	BUILD_NUMBER=$((SOURCE_BUILD + 1))
	last="$(state_get "$BUNDLE_ID")"
	if is_int "$last" && [ $((last + 1)) -gt "$BUILD_NUMBER" ]; then BUILD_NUMBER=$((last + 1)); fi
	remote="$(server_next)"
	if is_int "$remote" && [ "$remote" -gt "$BUILD_NUMBER" ]; then BUILD_NUMBER="$remote"; fi
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
SUBJECT="$(git -C "$ROOT" log -1 --format=%s)"
SUBJECT="${SUBJECT:0:500}"
DIRTY=false
SUFFIX=""
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then DIRTY=true; SUFFIX="-dirty"; fi

mkdir -p "$OUT"
IPA="$OUT/Madeira-$VERSION-$BUILD_NUMBER-${GIT_SHA:0:9}$SUFFIX.ipa"
rm -f "$IPA"
log "Packaging $(basename "$IPA")…"
# No resource forks or extended attributes: otherwise ditto adds a __MACOSX/ tree.
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGE/Payload" "$IPA"

SIDECAR="${IPA%.ipa}.json"
rm -f "$SIDECAR"
# plutil can't insert into an empty "{}" file (it reads that as OpenStep); start from an empty XML plist.
plutil -create xml1 "$SIDECAR"
plutil -insert sourceBundleId -string "$BUNDLE_ID" "$SIDECAR"
plutil -insert name -string "$NAME" "$SIDECAR"
plutil -insert version -string "$VERSION" "$SIDECAR"
plutil -insert buildNumber -integer "$BUILD_NUMBER" "$SIDECAR"
plutil -insert gitSha -string "$GIT_SHA" "$SIDECAR"
plutil -insert gitBranch -string "$BRANCH" "$SIDECAR"
plutil -insert gitDirty -bool "$DIRTY" "$SIDECAR"
plutil -insert commitSubject -string "$SUBJECT" "$SIDECAR"
plutil -convert json "$SIDECAR"

state_set "$BUNDLE_ID" "$BUILD_NUMBER"
log "Built $VERSION ($BUILD_NUMBER)"
printf '%s\n' "$IPA"
