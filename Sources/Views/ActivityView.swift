import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity log")
                        .font(.headline)
                    Text("The latest build, installation, and device events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { model.clearActivity() }
                    .disabled(model.activity.isEmpty)
            }
            .padding()

            Divider()

            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Device checks and installations will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.activity) { entry in
                            activityRow(entry)
                            Divider().padding(.leading, 36)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: entry.level))
                .foregroundStyle(color(for: entry.level))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                    Spacer()
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let details = entry.details, !details.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView(.horizontal) {
                            Text(details)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.vertical, 5)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func symbol(for level: ActivityLevel) -> String {
        switch level {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func color(for level: ActivityLevel) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
