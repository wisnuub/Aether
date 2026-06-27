import SwiftUI
import UniformTypeIdentifiers

struct SoftwareView: View {
    @EnvironmentObject var appState: AppState

    @State private var launchError: String?
    @State private var isRunningInstaller = false
    @State private var pendingInstallerPath = ""
    @State private var pendingAppName = ""
    @State private var showNameSheet = false
    @State private var renamingApp: InstalledApp?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                Divider()
                actionsSection
                Divider()
                installedSection
            }
            .padding(28)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.15),
                         Color(red: 0.04, green: 0.04, blue: 0.08)],
                startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
        .alert("Error", isPresented: .constant(launchError != nil)) {
            Button("OK") { launchError = nil }
        } message: { Text(launchError ?? "") }
        .sheet(isPresented: $showNameSheet) {
            NameInstallerSheet(name: $pendingAppName) {
                appState.addInstalledApp(name: pendingAppName, installerPath: pendingInstallerPath)
                showNameSheet = false
            } onCancel: {
                showNameSheet = false
            }
        }
        .sheet(item: $renamingApp) { app in
            RenameSheet(text: $renameText) {
                appState.renameInstalledApp(id: app.id, name: renameText)
                renamingApp = nil
            } onCancel: {
                renamingApp = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Software")
                .font(.title.bold())
            Text("Run Windows installers and manage installed programs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Actions")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    pickAndRunInstaller()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title2)
                        Text("Run Installer")
                            .font(.subheadline.bold())
                        Text("Pick an .exe or .msi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isRunningInstaller || appState.bottle == nil)

                Button {
                    launchDesktop()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                        Text("Desktop")
                            .font(.subheadline.bold())
                        Text("Wine explorer window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(appState.bottle == nil)
            }

            if appState.bottle == nil {
                Label("No Wine bottle configured.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed Software")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !appState.installedApps.isEmpty {
                    Text("\(appState.installedApps.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if appState.installedApps.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray")
                        .foregroundStyle(.tertiary)
                    Text("No installers run yet. Use Run Installer to track what you've installed.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 2) {
                    ForEach(appState.installedApps) { app in
                        appRow(app)
                    }
                }
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.blue.opacity(0.7))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                Text(app.installedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Menu {
                Button {
                    guard let bottle = appState.bottle else { return }
                    do { try WineProcess.launchInstaller(bottle: bottle, path: app.installerPath) }
                    catch { launchError = error.localizedDescription }
                } label: {
                    Label("Run Installer Again", systemImage: "arrow.clockwise")
                }
                Button {
                    renameText = app.name
                    renamingApp = app
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    appState.removeInstalledApp(id: app.id)
                } label: {
                    Label("Remove from List", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pickAndRunInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Select Installer"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe")!,
            UTType(filenameExtension: "msi")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        let suggested = url.deletingPathExtension().lastPathComponent
        pendingInstallerPath = path
        pendingAppName = suggested
        showNameSheet = true

        guard let bottle = appState.bottle else { return }
        isRunningInstaller = true
        DispatchQueue.global().async {
            do { try WineProcess.launchInstaller(bottle: bottle, path: path) }
            catch { DispatchQueue.main.async { launchError = error.localizedDescription } }
            DispatchQueue.main.async { isRunningInstaller = false }
        }
    }

    private func launchDesktop() {
        guard let bottle = appState.bottle else { return }
        do { try WineProcess.launchDesktop(bottle: bottle) }
        catch { launchError = error.localizedDescription }
    }
}

private struct NameInstallerSheet: View {
    @Binding var name: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Track Installation")
                .font(.title2.bold())
            Text("Give this software a name to track it in the list.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Adobe Reader", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Skip", role: .cancel, action: onCancel)
                Spacer()
                Button("Add to List") { onAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct RenameSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename").font(.title2.bold())
            TextField("Name", text: $text).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}
