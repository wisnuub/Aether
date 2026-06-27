import Foundation

actor SteamManager {
    static let shared = SteamManager()

    func discoverGames(in bottle: Bottle) -> [SteamGame] {
        let steamapps = bottle.steamLibraryPath
        guard FileManager.default.fileExists(atPath: steamapps.path) else { return [] }

        let additionalLibraries = parseLibraryFolders(steamapps: steamapps)
        let allLibraries = [steamapps] + additionalLibraries

        return allLibraries.flatMap { libPath -> [SteamGame] in
            let contents = (try? FileManager.default.contentsOfDirectory(at: libPath, includingPropertiesForKeys: nil)) ?? []
            return contents.compactMap { url -> SteamGame? in
                guard url.lastPathComponent.hasPrefix("appmanifest_"),
                      url.pathExtension == "acf"
                else { return nil }
                return SteamGame.from(acfURL: url)
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseLibraryFolders(steamapps: URL) -> [URL] {
        let vdfPath = steamapps.appendingPathComponent("libraryfolders.vdf")
        guard let content = try? String(contentsOf: vdfPath, encoding: .utf8) else { return [] }

        var results: [URL] = []
        let pattern = #""path"\s+"([^"]+)""#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(content.startIndex..., in: content)
        regex?.enumerateMatches(in: content, range: range) { match, _, _ in
            guard let match, let pathRange = Range(match.range(at: 1), in: content) else { return }
            let rawPath = String(content[pathRange])
            let url = URL(fileURLWithPath: rawPath).appendingPathComponent("steamapps")
            if FileManager.default.fileExists(atPath: url.path) {
                results.append(url)
            }
        }
        return results
    }
}
