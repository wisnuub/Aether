import SwiftUI

struct GameDetailView: View {
    @Binding var game: SteamGame
    @EnvironmentObject var appState: AppState
    @StateObject private var gameMonitor = GameMonitor()
    @State private var isLaunching = false
    @State private var launchError: String?
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                configSection
            }
        }
        .background(backgroundGradient)
        .onAppear { gameMonitor.start() }
        .onDisappear { gameMonitor.stop() }
        .onChange(of: game.config) { _, newConfig in
            appState.saveConfig(newConfig, for: game.id)
        }
        .alert("Launch Error", isPresented: .constant(launchError != nil)) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { appState.removeCustomGame(id: game.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from Aether only. The files on disk are not deleted.")
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            if game.isCustom {
                Rectangle().fill(Color.white.opacity(0.04))
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .overlay {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.08))
                    }
            } else {
                AsyncImage(url: game.heroURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.04))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipped()
            }

            LinearGradient(
                colors: [.clear, Color(red: 0.04, green: 0.04, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 240)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if game.isCustom {
                            Label("Custom", systemImage: "doc.badge.plus")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Text(game.name)
                            .font(.title.bold())
                            .shadow(radius: 8)
                    }
                    if game.isCustom {
                        Text(game.customExeFullPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("App ID \(game.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        let dir: URL
                        if game.isCustom {
                            dir = URL(fileURLWithPath: game.customExeFullPath)
                                .deletingLastPathComponent()
                        } else if let bottle = appState.bottle {
                            dir = bottle.steamLibraryPath
                                .appendingPathComponent("common/\(game.installDir)")
                        } else { return }
                        NSWorkspace.shared.open(dir)
                    } label: {
                        Label("Browse Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!game.isCustom && appState.bottle == nil)

                    if game.isCustom {
                        Button {
                            confirmRemove = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.large)
                    }

                    Button {
                        if gameMonitor.isRunning {
                            gameMonitor.killRunningGame()
                        } else {
                            launch()
                        }
                    } label: {
                        if isLaunching {
                            HStack {
                                ProgressView().scaleEffect(0.7)
                                Text("Launching...")
                            }
                        } else if gameMonitor.isRunning {
                            Label("Stop", systemImage: "stop.fill")
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(gameMonitor.isRunning ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(isLaunching || appState.bottle == nil)
                }
            }
            .padding(20)
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Graphics")
                .font(.headline)
                .foregroundStyle(.secondary)

            Picker("Renderer", selection: $game.config.renderer) {
                ForEach(GameConfig.Renderer.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)

            if game.config.renderer == .dxvk {
                HStack {
                    Text("DX Version")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("DX Version", selection: $game.config.dxVersion) {
                        ForEach(GameConfig.DXVersion.allCases) { v in
                            Text(v.rawValue).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                if game.config.dxVersion == .dx12 {
                    Text("DX12 via DXVK requires VKD3D-Proton (d3d12.dll) in the game folder.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            Text("Options")
                .font(.headline)
                .foregroundStyle(.secondary)

            Toggle("ESync (better CPU performance)", isOn: $game.config.esync)
            Toggle("Performance HUD", isOn: $game.config.metalHUD)
            Toggle("DirectDraw Wrapper (cnc-ddraw)", isOn: $game.config.useDDrawWrapper)
            Toggle("DirectComposition (window transparency)", isOn: $game.config.enableDComp)

            Divider()

            Text("Launch Arguments")
                .font(.headline)
                .foregroundStyle(.secondary)

            TextField("e.g. -windowed -noborder", text: $game.config.launchArgs)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Custom Executable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !game.config.customExePath.isEmpty {
                        Label("Direct launch active", systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                TextField("e.g. PlantsVsZombies.exe", text: $game.config.customExePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Bypasses Steam's launcher and runs this exe directly (Steam still starts for DRM). Use when Steam's applaunch silently fails.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            EnvVarEditor(vars: $game.config.extraEnvVars)
        }
        .padding(24)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.08, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.08)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func launch() {
        guard let bottle = appState.bottle else { return }
        isLaunching = true
        launchError = nil
        let snapshot = game
        Task.detached(priority: .userInitiated) {
            var err: String?
            do {
                if snapshot.isCustom {
                    try WineProcess.launchCustomExe(
                        bottle: bottle,
                        exePath: snapshot.customExeFullPath,
                        config: snapshot.config
                    )
                } else {
                    try WineProcess.launchSteam(
                        bottle: bottle,
                        gameID: snapshot.id,
                        config: snapshot.config,
                        installDir: snapshot.installDir
                    )
                }
            } catch {
                err = error.localizedDescription
            }
            await MainActor.run {
                self.launchError = err
                self.isLaunching = false
            }
        }
    }
}

private struct EnvVarEditor: View {
    @Binding var vars: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment Variables")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(vars.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text("=").foregroundStyle(.tertiary)
                    Text(vars[key] ?? "").font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button { vars.removeValue(forKey: key) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("KEY", text: $newKey)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("=").foregroundStyle(.secondary)
                TextField("value", text: $newValue)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !newKey.isEmpty else { return }
                    vars[newKey] = newValue
                    newKey = ""; newValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .disabled(newKey.isEmpty)
            }
        }
    }
}
