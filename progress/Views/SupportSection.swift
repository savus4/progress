import SwiftUI

struct SupportSection: View {
    @Environment(\.openURL) private var openURL
    @State private var showsMailUnavailable = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Need a hand?")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        Text("If you need help, you can contact the developer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button(action: contactDeveloper) {
                    Label("Contact Developer", systemImage: "envelope")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .accessibilityHint("Opens your email app with a draft that includes app and device details.")
                .accessibilityIdentifier("contactDeveloper")
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(LinearGradient(
                                colors: [Color.accentColor.opacity(0.08), Color.accentColor.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .alert("Couldn’t Open Email", isPresented: $showsMailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up a mail app to send your message, or contact the developer at \(SupportEmail.recipient).")
        }
    }

    private func contactDeveloper() {
        guard let url = SupportEmail.makeURL() else {
            showsMailUnavailable = true
            return
        }

        openURL(url) { accepted in
            showsMailUnavailable = !accepted
        }
    }
}

#Preview {
    Form {
        SupportSection()
    }
}
