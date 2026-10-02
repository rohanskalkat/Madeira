#!/usr/bin/env bash
# Fetch the Microsoft Visual C++ x64 runtime DLLs into app/Madeira/x86_64-vcruntime/.
#
# Downloads Microsoft's official VC_redist.x64.exe and extracts the twelve DLLs
# byte-for-byte (they are only renamed from Microsoft's "<name>_amd64" cabinet
# keys). The files stay git-ignored; see tools/fetch-vcruntime.md for why.
#
# Usage: tools/fetch-vcruntime.sh            Needs: curl, python3, 7zz (brew install sevenzip)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/app/Madeira/x86_64-vcruntime"
URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
DLLS="concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids
vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1 vcruntime140_threads"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v 7zz >/dev/null || die "7zz not found; install it with: brew install sevenzip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'Downloading %s…\n' "$URL" >&2
curl -fsSL -o "$WORK/vc_redist.x64.exe" "$URL"

# The installer is a WiX bundle: a small UI cabinet followed by an attached
# container of cabinets. Carve out every embedded cabinet, then unpack them.
python3 - "$WORK/vc_redist.x64.exe" "$WORK/cabs" <<'PY'
import os, struct, sys
data = open(sys.argv[1], "rb").read()
out = sys.argv[2]
os.makedirs(out)
i = n = 0
while (i := data.find(b"MSCF\0\0\0\0", i)) >= 0:
    size = struct.unpack_from("<I", data, i + 8)[0]
    if 0 < size <= len(data) - i:
        open(os.path.join(out, f"c{n}.cab"), "wb").write(data[i:i + size])
        n += 1
    i += 4
PY
for cab in "$WORK"/cabs/*.cab; do 7zz x -y "$cab" -o"${cab%.cab}" >/dev/null 2>&1 || true; done
find "$WORK/cabs" -type f ! -name '*.cab' | while read -r f; do
	if file "$f" | grep -q 'Microsoft Cabinet'; then 7zz x -y "$f" -o"$f.x" >/dev/null 2>&1 || true; fi
done

mkdir -p "$DEST"
for name in $DLLS; do
	src="$(find "$WORK/cabs" -type f -name "$name.dll_amd64" | head -n 1)"
	[ -n "$src" ] || die "$name.dll not found in the installer; its layout may have changed (see tools/fetch-vcruntime.md)"
	cp "$src" "$DEST/$name.dll"
done
printf 'Installed %s DLLs into %s\n' "$(find "$DEST" -maxdepth 1 -name '*.dll' | wc -l | tr -d ' ')" "$DEST" >&2
