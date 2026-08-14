import SwiftUI

/// Turning an emailed licence key into an activated copy.
///
/// Two steps, because the backend is: the key and email get a six-digit code
/// emailed back, and the code confirms. That is a real extra step for the user,
/// so the screen states up front that it is coming rather than springing a
/// second field once they think they are done.
///
/// The restore path is always reachable — this is the answer to the most common
/// support email in any licensed app, and hiding it behind a menu is how it
/// becomes one.
struct ActivationSheet: View {

    @Bindable var model: AppModel

    @State private var email = ""
    @State private var key = ""
    @State private var code = ""
    @State private var stage = Stage.credentials
    @State private var busy = false
    @State private var problem: String?

    private enum Stage { case credentials, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch stage {
            case .credentials: credentialFields
            case .code:        codeField
            }

            if let problem {
                Callout(text: problem, symbol: "exclamationmark.triangle")
            }

            footer
        }
        .padding(26)
        .frame(width: 500)
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stage == .credentials ? "Activate DiskDrama" : "Check your email")
                .font(Theme.display(19))
                .foregroundStyle(Theme.text)
            Text(stage == .credentials
                 ? "Your key arrived by email when you bought it. Enter it with the address you used, and I'll email a six-digit code to confirm it's you."
                 : "A six-digit code is on its way to \(email). It's good for fifteen minutes.")
                .font(Theme.body(13))
                .lineSpacing(3)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Email", text: $email, prompt: "you@example.com")
            field("Licence key", text: $key, prompt: "XXXXXXXX-XXXXXXXX-…", mono: true)
        }
    }

    private var codeField: some View {
        field("Six-digit code", text: $code, prompt: "000000", mono: true)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.ui(12.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(mono ? Theme.mono(12.5) : Theme.body(13))
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.hairline2, lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button("Cancel") { model.activeSheet = nil }
                .buttonStyle(QuietButtonStyle(height: 32))
                .disabled(busy)
            Spacer(minLength: 8)
            if stage == .code {
                Button("Back") { stage = .credentials; problem = nil }
                    .buttonStyle(GhostButtonStyle(height: 32, horizontalPadding: 14, fontSize: 13.5))
                    .disabled(busy)
            }
            Button(action: submit) {
                if busy {
                    HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Checking…") }
                } else {
                    Text(stage == .credentials ? "Email me a code" : "Activate")
                }
            }
            .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
            .disabled(busy || !isReady)
        }
    }

    private var isReady: Bool {
        switch stage {
        case .credentials: !email.trimmed.isEmpty && !key.trimmed.isEmpty
        case .code:        code.trimmed.count >= 6
        }
    }

    private func submit() {
        busy = true
        problem = nil
        Task {
            let outcome: LicenseStore.Outcome
            switch stage {
            case .credentials:
                outcome = await model.licence.requestCode(email: email.trimmed, key: key.trimmed)
            case .code:
                outcome = await model.licence.confirm(email: email.trimmed, key: key.trimmed, code: code.trimmed)
            }
            busy = false
            switch outcome {
            case .ok:
                if stage == .credentials {
                    stage = .code
                } else {
                    model.activeSheet = nil
                }
            case .failed(let message):
                problem = message
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
