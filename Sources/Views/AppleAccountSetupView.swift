import SwiftUI

struct AppleAccountSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = AppleWebSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apple Account").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Sign in and select the same team as your publishing API key. Complete agreements, app setup, and App Privacy on Apple’s page. Your password and verification code stay with Apple.")
                .foregroundStyle(.secondary)
            AppleWebPage(session: session).frame(minWidth: 900, minHeight: 580)
            if let error = session.pageError { Text(error).foregroundStyle(.red) }
            Button("Reload Apple Sign-In") { session.openApps() }
        }.padding(20)
    }
}
