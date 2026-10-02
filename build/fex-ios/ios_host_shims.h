/* Force-included into the iOS-host FEXCore build (build/fex-ios/build.sh).
 *
 * The fork's CompileBlock reporter (FEXCore/Source/Interface/Core/Core.cpp,
 * [ffs-bypass]/[cb-entry]) reads two diagnostic counters unconditionally, but
 * declares and defines them only for its Windows modules (FEX_IOS_HOST, set by
 * build/fex-arm64ec and build/fex-wow64). Nothing writes them in the native
 * iOS library, so zero-filled copies keep the reporter silent here. Defining
 * FEX_IOS_HOST instead is wrong for this target: it selects Windows-only code. */
#pragma once
#if defined(__cplusplus) && !defined(FEX_IOS_HOST)
#include <cstddef>
#include <cstdint>
[[maybe_unused]] static uint64_t IosCbEntryLog[8] {};
[[maybe_unused]] static uint64_t IosFfsBypassLog[4] {};
#endif

/* CompileBlock's [rpm-cas] diagnostic (Core.cpp) calls rpm_cas_snapshot_take
 * from FEX's rpmalloc fork unconditionally. This build has the FEX allocator
 * off (ENABLE_FEX_ALLOCATOR=OFF), so rpmalloc is not linked; report "no
 * snapshot" and the diagnostic stays silent. */
#ifdef __cplusplus
struct rpm_cas_snapshot;
extern "C" inline int rpm_cas_snapshot_take(struct rpm_cas_snapshot*) {
  return 0;
}
#endif

/* Utils/ArchHelpers/Arm64.cpp's [caspal128] diagnostic queries the faulting
 * address with the Win32 VirtualQuery outside any _WIN32 guard. On the native
 * iOS target there is no Win32 memory API: these stand-ins make the query
 * report nothing, so the diagnostic prints its "?" region type. */
#if defined(__cplusplus) && !defined(_WIN32)
typedef const void* LPCVOID;
typedef struct {
  void* BaseAddress;
  void* AllocationBase;
  uint32_t AllocationProtect;
  size_t RegionSize;
  uint32_t State;
  uint32_t Protect;
  uint32_t Type;
} MEMORY_BASIC_INFORMATION;
enum : uint32_t { MEM_IMAGE = 0x1000000, MEM_MAPPED = 0x40000 };
[[maybe_unused]] static inline size_t VirtualQuery(LPCVOID, MEMORY_BASIC_INFORMATION*, size_t) {
  return 0;
}
#endif
