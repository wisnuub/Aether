import Foundation
import Combine

// Detects if a non-infrastructure Wine process (i.e. a game) is running.
@MainActor
final class GameMonitor: ObservableObject {
    @Published var isRunning: Bool = false
    private var timer: AnyCancellable?

    private static let infraPattern =
        "wineserver|winedevice|pluginhost|services.exe|svchost.exe|" +
        "explorer.exe|rpcss.exe|winemenubuilder|steam.exe|steamwebhelper|wineboot"

    func start() {
        check()
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.check() }
    }

    func stop() {
        timer = nil
        isRunning = false
    }

    private func check() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "pgrep -lf wine 2>/dev/null | grep -ivE '\(Self.infraPattern)' | head -1"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        isRunning = !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func killRunningGame() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "pgrep -lf wine 2>/dev/null | grep -ivE '\(Self.infraPattern)' | awk '{print $1}' | xargs kill -9 2>/dev/null; true"
        ]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        isRunning = false
    }
}

@MainActor
final class SteamMonitor: ObservableObject {
    @Published var isRunning: Bool = false

    private var timer: AnyCancellable?

    func start() {
        check()
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.check() }
    }

    func stop() {
        timer = nil
        isRunning = false
    }

    private func check() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "Steam.exe"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        isRunning = task.terminationStatus == 0
    }
}
