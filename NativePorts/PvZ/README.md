# Native Plants vs. Zombies runtime (Apple Silicon)

Aether runs Plants vs. Zombies: Game of the Year Edition (Steam app 3590) as a
native arm64 app instead of through Wine. The runtime uses the game data from
your own Steam copy (`main.pak` and `properties/`). None of the game's assets
are in this repository.

## How Aether uses it

- **Build.** Xcode's "Build Native Ports" phase runs `build-macos.sh`, which
  compiles the runtime and bundles its libraries into
  `Aether.app/Contents/Resources/NativePorts/PvZ`.
- **First launch.** `NativePortManager` copies the runtime to
  `~/Library/Application Support/Aether/Native/PvZ`. It copies `main.pak` and
  `properties/` from the game's folder in Aether's bottle and writes
  `aether-launch.sh`.
- **Steam for macOS.** The game's Mac entry is installed in Steam for macOS. Its
  Launch Options are set to `"<install>/aether-launch.sh" %command%`, so pressing
  Play in Steam, or in Aether, starts the native runtime.

## Steam integration (`src/Aether/SteamBridge.*`)

- **Steam Cloud.** `users.dat` and `user<N>.dat` sync in both directions under
  the same cloud names the Windows Steam build uses. Progress moves between
  this runtime and the Windows game. Steam downloads saves before launch and
  uploads them after exit.
- **Achievements.** All 21 Steam achievements unlock on your account, including
  "Disco is Undead".
- **Save format.** User files use the Steam 1.2.0.1096 layout with 21
  achievement slots, so the Windows build reads them unchanged.
- **Mid-level saves** are not synced. The Windows build stores them as raw
  32-bit memory dumps.
- **Steam library.** `libsteam_api.dylib` (Valve's redistributable) is loaded
  at runtime and fetched by `build-macos.sh`. No Steamworks SDK is needed to
  build.

Saves live in `~/Library/Application Support/Aether/PvZ/`.

## Building by hand

```bash
brew install cmake ninja sdl2 libopenmpt libpng jpeg-turbo dylibbundler
NativePorts/PvZ/build-macos.sh /path/to/output
```

## License

The runtime is derived from LGPL-3.0-or-later community code. The original
copyright notices are kept in the source files, and Aether's changes are
marked in the files they touch. See `LICENSE` and `COPYING`. Any copy of the
runtime must ship with those two files, which `build-macos.sh` does.
