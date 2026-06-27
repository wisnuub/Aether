import Foundation

enum GPTKManager {
    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/Wine")

    // Gcenx builds extract as an app bundle: Wine.app/Contents/Resources/wine/bin/wine
    private static let bundledWinePaths: [String] = [
        appSupport.appendingPathComponent("Contents/Resources/wine/bin/wine64").path,
        appSupport.appendingPathComponent("Contents/Resources/wine/bin/wine").path,
        appSupport.appendingPathComponent("bin/wine64").path,
        appSupport.appendingPathComponent("bin/wine").path,
    ]

    static let searchPaths: [String] = bundledWinePaths + [
        "/usr/local/bin/wine64",
        "/usr/local/bin/wine",
        "/opt/homebrew/bin/wine64",
        NSHomeDirectory() + "/.local/share/CrossOver/wine/bin/wine64",
    ]

    static var winePath: URL? {
        searchPaths.compactMap { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { winePath != nil }

    static func baseEnvironment(for bottle: Bottle) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.path.path
        env["WINEDEBUG"] = "-all"
        env["WINE_CROSSOVER_HACK"] = "1"
        env["WINEESYNC"] = "1"
        // Use GPTK builtins for D3D. d3d9=b routes D3D9 games (e.g. PvZ) through GPTK's
        // Metal translation instead of WineD3D's OpenGL renderer (broken on macOS).
        env["WINEDLLOVERRIDES"] = "steamservice=d;winemenubuilder.exe=d;dxgi=b;d3d11=b;d3d10core=b;d3d9=b;dcomp=n"
        env["STEAM_RUNTIME"] = "0"
        // MoltenVK debug logging to os_log — capture with:
        // sudo log stream --predicate 'subsystem contains "moltenVK"' --level debug
        env["MVK_CONFIG_LOG_LEVEL"] = "3"

        let libPath = appSupport.appendingPathComponent("Contents/Resources/wine/lib").path
        if FileManager.default.fileExists(atPath: libPath) {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libPath
        }
        return env
    }
}
