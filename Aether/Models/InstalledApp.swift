import Foundation

struct InstalledApp: Codable, Identifiable {
    var id: String          // stable: path-based hash or UUID for manual entries
    var name: String
    var installerPath: String   // original installer used
    var launchExePath: String   // exe to launch (may be empty if unknown)
    var installedAt: Date

    init(name: String, installerPath: String, launchExePath: String = "") {
        self.id = installerPath.isEmpty ? UUID().uuidString : installerPath
        self.name = name
        self.installerPath = installerPath
        self.launchExePath = launchExePath
        self.installedAt = Date()
    }
}
