# Wine patches applied by Aether

Aether installs upstream Wine (Gcenx's `wine-devel` macOS builds) and then
replaces a few builtin DLLs with patched copies from this folder. The patched
DLLs are version-specific. `GPTKManager.applyWinePatches()` only installs
the files under `wine-<version>/` that match the installed Wine's
`CFBundleShortVersionString`.

## CW HACK 20760: wow64cpu Rosetta 2 mode-switch workaround

File: `wine-11.10/x86_64-windows/wow64cpu.dll`
Source change: `cw-hack-20760-wow64cpu.patch` (against `wine-11.10/dlls/wow64cpu/cpu.c`)

**Symptom.** 32-bit games under new-style WoW64 on Apple Silicon crash or hang
shortly after start. The Wine trace shows an access violation inside
`wow64cpu.dll` at a 64-bit RIP-relative `mov` (for example
`mov 0x2ec5(%rip),%edx`), which faults because the thread is still in 32-bit
mode and reads the absolute address instead. The next exception usually ends in
`virtual_setup_exception nested exception on signal stack`, and the thread is
then stuck. Plants vs. Zombies GOTY (Steam app 3590) hits this every launch.

**Cause.** Wine switches from 64-bit back to 32-bit code with `ljmp *(%r14)`,
and 32-bit code enters 64-bit with a far `ljmp` thunk. Under Rosetta 2 a
SIGUSR1 (which Wine uses to suspend threads and fetch contexts) can arrive in
the middle of that far jump and leave the thread running 64-bit code in 32-bit
mode.

**Fix.** CodeWeavers' CrossOver carries "CW HACK 20760": when the processor
brand string contains `VirtualApple` (Rosetta 2), use a far `lcall` into a small
64-bit trampoline for the 32-to-64 direction and `lretq` for the 64-to-32
direction. The patch here is that hack, taken unchanged from the CrossOver
26.3.0 source release and applied to Wine 11.10. Outside Rosetta the
original code path runs.

## Licence and source

Wine and CrossOver's Wine tree are LGPL-2.1-or-later. The complete source for
the change is `cw-hack-20760-wow64cpu.patch`. The original sources are:

- Wine 11.10: https://dl.winehq.org/wine/source/11.x/wine-11.10.tar.xz
- CrossOver 26.3.0 sources: https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz

## Rebuilding

```bash
tar -xJf wine-11.10.tar.xz
cd wine-11.10 && patch -p1 < ../cw-hack-20760-wow64cpu.patch && cd ..
mkdir build64 && cd build64
# bison >= 3 is required (brew install bison)
PATH="/opt/homebrew/opt/bison/bin:$PATH" arch -x86_64 ../wine-11.10/configure \
  --enable-archs=x86_64 --without-x --without-freetype --without-gnutls \
  --disable-tests CC="clang -arch x86_64"
PATH="/opt/homebrew/opt/bison/bin:$PATH" arch -x86_64 make -j8 \
  dlls/wow64cpu/x86_64-windows/wow64cpu.dll
x86_64-w64-mingw32-strip -o wow64cpu.dll dlls/wow64cpu/x86_64-windows/wow64cpu.dll
```

To support another Wine version, rebuild against that version's source and add
the result under `wine-<version>/x86_64-windows/`.
