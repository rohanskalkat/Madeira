# Obtaining the Microsoft Visual C++ runtime DLLs

Games built with MSVC need the Visual C++ runtime. Those DLLs are authored by
Microsoft and are **not** redistributable under this project's license, so they
are not committed here. You supply them yourself.

Twelve files are expected in `app/Madeira/x86_64-vcruntime/`:

```
concrt140.dll              msvcp140_codecvt_ids.dll   vcruntime140.dll
msvcp140.dll               vcamp140.dll               vcruntime140_1.dll
msvcp140_1.dll             vccorlib140.dll            vcruntime140_threads.dll
msvcp140_2.dll             vcomp140.dll
msvcp140_atomic_wait.dll
```

## How to get them

Run the fetch script. It downloads the official x64 redistributable from
Microsoft (`VC_redist.x64.exe`) and extracts the twelve DLLs into
`app/Madeira/x86_64-vcruntime/`:

```sh
brew install sevenzip
tools/fetch-vcruntime.sh
```

Current installers are WiX bundles: the DLLs sit in a cabinet inside a
container appended to the executable, stored under keys like
`vcruntime140.dll_amd64`. The script carves out the embedded cabinets,
unpacks them, and copies each `<name>.dll_amd64` to `<name>.dll` without
changing a byte.

Exact layout varies by redistributable version; the goal is simply the twelve
files above, **byte-for-byte as Microsoft shipped them**.

## Do not modify them

Microsoft's redistribution permission covers the eligible files *unmodified*.
In particular, do not strip Authenticode signatures. You can check that a file
still carries its signature payload:

```sh
python3 - app/Madeira/x86_64-vcruntime/*.dll <<'EOF'
import struct, sys
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    off, size = struct.unpack_from('<II', d, pe + 24 + 112 + 4*8)
    ok = size and off + size <= len(d)
    print(('signed  ' if ok else 'UNSIGNED'), path)
EOF
```

A file whose certificate offset equals its own length has had the signature
truncated off and is no longer an unmodified Microsoft binary.
