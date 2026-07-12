import Foundation

struct SteamGame: Identifiable, Hashable {
    let id: Int
    let name: String
    let installDir: String
    var config: GameConfig
    /// True for games added manually (non-Steam EXE files).
    var isCustom: Bool = false
    /// Absolute path to the EXE for custom (non-Steam) games.
    var customExeFullPath: String = ""

    var artworkURL: URL? {
        guard !isCustom else { return nil }
        return URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg")
    }

    var heroURL: URL? {
        guard !isCustom else { return nil }
        return URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_hero.jpg")
    }

    static func from(acfURL: URL) -> SteamGame? {
        guard let content = try? String(contentsOf: acfURL, encoding: .utf8) else { return nil }
        let fields = VDFParser.parseSimple(content)
        guard
            let appIDStr = fields["appid"], let appID = Int(appIDStr),
            let name = fields["name"],
            let installDir = fields["installdir"]
        else { return nil }
        return SteamGame(id: appID, name: name, installDir: installDir, config: GameConfig())
    }

    /// Build a SteamGame from a persisted CustomGameEntry.
    static func from(entry: CustomGameEntry) -> SteamGame {
        let exeURL = URL(fileURLWithPath: entry.exePath)
        return SteamGame(
            id: entry.stableID,
            name: entry.name,
            installDir: exeURL.deletingLastPathComponent().lastPathComponent,
            config: entry.config,
            isCustom: true,
            customExeFullPath: entry.exePath
        )
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SteamGame, rhs: SteamGame) -> Bool { lhs.id == rhs.id }
}

// MARK: - Custom game persistence

struct CustomGameEntry: Codable, Identifiable {
    /// Use the exe path as the stable identity so the derived integer ID never drifts.
    var id: String { exePath }
    var name: String
    var exePath: String
    var config: GameConfig

    /// Stable integer ID derived from the exe path.  Offset to a negative range
    /// so it never collides with real Steam app IDs (always positive).
    var stableID: Int {
        var h = Hasher()
        h.combine(exePath)
        let raw = h.finalize()
        // Map into [-Int.max/2 ... -1]
        return -(abs(raw % (Int.max / 2)) + 1)
    }

    // Custom Codable because `id` is computed.
    enum CodingKeys: String, CodingKey { case name, exePath, config }
}

struct GameConfig: Codable, Equatable {
    var renderer: Renderer = .auto
    var dxVersion: DXVersion = .dx11
    /// Which Wine build to launch with. Stable is the Wine 11.x bundle; GPTK is
    /// Apple's Game Porting Toolkit build with D3DMetal (best for DX11/DX12 games).
    var wineBuild: WineBuild = .stable
    var esync: Bool = true
    var metalHUD: Bool = false
    var extraEnvVars: [String: String] = [:]
    var launchArgs: String = ""
    /// Exe filename relative to the game's steamapps/common/<installDir>/ folder.
    /// When non-empty, Aether bypasses Steam's launcher and runs this executable directly.
    /// Steam is still started in the background so steam_api.dll DRM can connect.
    var customExePath: String = ""
    /// Add ddraw=n,b to WINEDLLOVERRIDES so cnc-ddraw intercepts DirectDraw calls.
    /// Required for old DDraw games (e.g. PvZ) that need cnc-ddraw to translate DDraw→D3D9.
    var useDDrawWrapper: Bool = false
    /// Enable DirectComposition (dcomp). Needed for games that use DComp-based
    /// transparency (e.g. taskbar overlay idle games). Off by default because it
    /// causes crashes in most games.
    var enableDComp: Bool = false

    enum Renderer: String, Codable, CaseIterable, Identifiable {
        case auto = "Auto (D3DMetal)"
        case dxvk = "DXVK"
        case moltenVK = "MoltenVK"
        var id: String { rawValue }
    }

    enum WineBuild: String, Codable, CaseIterable, Identifiable {
        case stable = "Stable"
        case gptk = "GPTK (D3DMetal)"
        var id: String { rawValue }
    }

    init() {}

    // Custom decoding with per-field defaults so configs saved by older versions
    // (missing newly added keys) never fail to decode and reset user settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        renderer        = (try? c.decode(Renderer.self,  forKey: .renderer))        ?? .auto
        dxVersion       = (try? c.decode(DXVersion.self, forKey: .dxVersion))       ?? .dx11
        wineBuild       = (try? c.decode(WineBuild.self, forKey: .wineBuild))       ?? .stable
        esync           = (try? c.decode(Bool.self,      forKey: .esync))           ?? true
        metalHUD        = (try? c.decode(Bool.self,      forKey: .metalHUD))        ?? false
        extraEnvVars    = (try? c.decode([String: String].self, forKey: .extraEnvVars)) ?? [:]
        launchArgs      = (try? c.decode(String.self,    forKey: .launchArgs))      ?? ""
        customExePath   = (try? c.decode(String.self,    forKey: .customExePath))   ?? ""
        useDDrawWrapper = (try? c.decode(Bool.self,      forKey: .useDDrawWrapper)) ?? false
        enableDComp     = (try? c.decode(Bool.self,      forKey: .enableDComp))     ?? false
    }

    enum DXVersion: String, Codable, CaseIterable, Identifiable {
        case dx9  = "DX9"
        case dx10 = "DX10"
        case dx11 = "DX11"
        case dx12 = "DX12"
        var id: String { rawValue }
        var apiArg: String { rawValue.lowercased() }
    }
}

enum VDFParser {
    static func parseSimple(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #""(\w+)"\s+"([^"]+)""#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(content.startIndex..., in: content)
        regex?.enumerateMatches(in: content, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: content),
                  let valRange = Range(match.range(at: 2), in: content)
            else { return }
            result[String(content[keyRange]).lowercased()] = String(content[valRange])
        }
        return result
    }
}
