import AppKit
import SwiftUI

struct ProjectsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<UUID> = []
    @State private var showsRemoveConfirmation = false
    @State private var settingsProject: ManagedProject?

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Managed applications")
                        .font(.title2.bold())
                    Text("Add an application, then open its settings to choose a scheme and installation devices.")
                        .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

                applicationTable
                    .padding(.horizontal)

                actionBar
                    .padding(.horizontal)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .top
            )
        }
        .sheet(item: $settingsProject) { project in
            ProjectSettingsSheet(projectID: project.id)
                .environmentObject(model)
        }
        .confirmationDialog(
            Text("Remove application?"),
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let selectedIDs = selection
                selectedIDs.forEach(model.removeProject(id:))
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The source folder and its files will not be deleted.")
        }
        .onAppear {
            model.refreshDeveloperTeams()
        }
    }

    private var applicationTable: some View {
        Table(model.projects, selection: $selection) {
            TableColumn("Application") { project in
                HStack(spacing: 9) {
                    ProjectIconView(
                        project: project,
                        iconURL: model.projectIconURL(for: project.id),
                        size: 30,
                        showsStatus: true
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(project.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 235, ideal: 320)

            TableColumn("Version") { project in
                Text(project.versionDisplay)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)

            TableColumn("Last installed") { project in
                Text(lastInstalledText(for: project))
                    .foregroundStyle(.secondary)
            }
            .width(min: 145, ideal: 170)

            TableColumn("Status") { project in
                Toggle(
                    isOn: Binding(
                        get: { project.isEnabled },
                        set: { model.setProjectEnabled($0, projectID: project.id) }
                    )
                ) {
                    Text(project.isEnabled ? L10n.text("Enabled") : L10n.text("Paused"))
                        .foregroundStyle(project.isEnabled ? .green : .secondary)
                }
                .toggleStyle(.switch)
                .help(
                    project.isEnabled
                        ? L10n.text("Pause application installations")
                        : L10n.text("Resume application installations")
                )
            }
            .width(min: 120, ideal: 145)

            TableColumn("Settings") { project in
                Button {
                    settingsProject = project
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }
            .width(100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 200, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            Button(action: chooseProjectFolder) {
                if model.isDiscoveringProject {
                    ProgressView().controlSize(.small).frame(width: 20)
                } else {
                    Image(systemName: "plus")
                }
            }
            .help("Add application…")
            .disabled(model.isDiscoveringProject)

            Divider().frame(height: 20).padding(.horizontal, 6)

            Button {
                showsRemoveConfirmation = true
            } label: {
                Image(systemName: "minus")
            }
            .help("Remove")
            .disabled(
                selection.isEmpty
                    || selection.contains(where: {
                        model.isInstalling(projectID: $0) || model.isPublishing(projectID: $0)
                    })
            )

            Divider().frame(height: 20).padding(.horizontal, 10)

            Button {
                model.installAll()
            } label: {
                Label("Install All Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.projects.filter(\.isEnabled).isEmpty || model.isGeneratingOfferCodes)

            if model.pendingInstallAllCount > 0 {
                Text(L10n.format("Waiting to install %d application(s)", model.pendingInstallAllCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }

            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an iOS or macOS application folder")
        panel.prompt = L10n.text("Add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task {
            await model.addProject(folderURL: folderURL)
            if let added = model.projects.first(where: { $0.folderPath == folderURL.standardizedFileURL.path }) {
                selection = [added.id]
            }
        }
    }

    private func lastInstalledText(for project: ManagedProject) -> String {
        guard let date = model.lastInstallation(for: project.id) else { return L10n.text("Never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
