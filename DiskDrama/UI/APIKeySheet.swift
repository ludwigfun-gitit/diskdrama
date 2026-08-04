import SwiftUI

/// Somewhere to put the Anthropic API key.
///
/// Deliberately minimal — Step 10 builds the real Settings surface and this
/// becomes one section of it. It exists now because the explanation layer is
/// otherwise unreachable: a feature with no way to configure it is a feature
/// nobody can use.
///
/// A02 resolves that a personal API key is acceptable for v1. Commercial
/// distribution changes that economics entirely and is flagged for later.
struct APIKeySheet: View {

    @Bindable var model: AppModel

    @State private var key: String = ""
    @State private var hasStoredKey = APIKeyStore.hasKey

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deeper explanations")
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.text)
                Text("DiskDrama sorts everything into tiers on its own, for free and offline. "
                     + "With an Anthropic API key it can also ask Claude for a closer look at whichever "
                     + "item you've selected — what it really contains and what deleting it costs you.")
                    .font(Theme.body(13.5))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                // `SecureField`, and stored in the Keychain rather than
                // UserDefaults — it's a credential that bills a real account.
                SecureField(hasStoredKey ? "A key is saved — paste a new one to replace it"
                                         : "sk-ant-…",
                            text: $key)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12.5))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(Theme.content, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.hairline2, lineWidth: 1)
                    )

                Text("Stored in your Keychain, on this Mac only. Nothing about your files is sent anywhere "
                     + "until you select an item — and then only that one folder's name, size and date.")
                    .font(Theme.body(12))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                if hasStoredKey {
                    Button("Remove key") {
                        APIKeyStore.delete()
                        hasStoredKey = false
                        key = ""
                    }
                    .buttonStyle(QuietButtonStyle(height: 32))
                }
                Spacer()
                Button("Done") { model.isShowingAPIKeySheet = false }
                    .buttonStyle(GhostButtonStyle(height: 32, horizontalPadding: 16, fontSize: 13.5))
                Button("Save") {
                    APIKeyStore.save(key)
                    hasStoredKey = APIKeyStore.hasKey
                    key = ""
                    model.isShowingAPIKeySheet = false
                }
                .buttonStyle(AccentButtonStyle(height: 32, horizontalPadding: 18, fontSize: 13.5))
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.panel)
    }
}
