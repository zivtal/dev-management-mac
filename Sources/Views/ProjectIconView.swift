import AppKit
import SwiftUI

struct ProjectIconView: View {
    @EnvironmentObject private var model: AppModel

    let project: ManagedProject
    let size: CGFloat
    var showsStatus = false

    var body: some View {
        Group {
            if let url = model.projectIconURL(for: project.id),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(.secondary)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if showsStatus {
                Circle()
                    .fill(project.isEnabled ? Color.green : Color.gray)
                    .frame(width: max(7, size * 0.28), height: max(7, size * 0.28))
                    .overlay { Circle().stroke(.background, lineWidth: 1.5) }
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}
