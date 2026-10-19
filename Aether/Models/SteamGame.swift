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
    var id: String { exePath }
    var name: String
    var exePath: String
    var config: GameConfig

    var stableID: Int {
        var h = Hasher()
        h.combine(exePath)
        let raw = h.finalize()
        return -(abs(raw % (Int.max / 2)) + 1)
    }

    enum CodingKeys: String, CodingKey { case name, exePath, config }
}

struct GameConfig: Codable, Equatable {
    var renderer: Renderer = .auto
    var dxVersion: DXVersion = .dx11
    var wineBuild: WineBuild = .stable
    var esync: Bool = true
    var metalHUD: Bool = false
    var extraEnvVars: [String: String] = [:]
    var launchArgs: String = ""
    var customExePath: String = ""
    var useDDrawWrapper: Bool = false
    var enableDComp: Bool = false
    /// Native runtime when Aether ships one for this game (see NativePortManager); Wine otherwise.
    var runtime: Runtime = .native

    enum Runtime: String, Codable, CaseIterable, Identifiable {
        case native = "Native (Apple Silicon)"
        case wine   = "Wine"
        var id: String { rawValue }
    }

    enum Renderer: String, Codable, CaseIterable, Identifiable {
        case auto     = "Auto (D3DMetal)"
        case dxvk     = "DXVK"
        case moltenVK = "MoltenVK"
        var id: String { rawValue }
    }

    enum WineBuild: String, Codable, CaseIterable, Identifiable {
        case stable = "Stable"
        case gptk   = "GPTK (D3DMetal)"
        case arm64  = "ARM64 + FEX"
        var id: String { rawValue }

        /// True for builds that use D3DMetal builtins and cannot use DXVK/MoltenVK.
        var usesD3DMetal: Bool { self == .gptk || self == .arm64 }
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
        runtime         = (try? c.decode(Runtime.self,   forKey: .runtime))         ?? .native
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
