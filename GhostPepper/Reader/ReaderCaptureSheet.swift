import SwiftUI

struct ReaderCaptureSheet: View {
    @Environment(\.appTheme) private var theme
    let archiveRoot: URL
    let onSaved: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput: String = ""
    @State private var isCapturing = false
    @State private var errorMessage: String?
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "newspaper")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.accent)
                Text("New Reader")
                    .font(.headline)
                Spacer()
            }

            Text("Paste a URL. The article will be saved as a note.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            TextField("https://example.com/article", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .focused($urlFieldFocused)
                .disabled(isCapturing)
                .onSubmit { capture() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.statusLive)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCapturing)

                Button {
                    capture()
                } label: {
                    HStack(spacing: 6) {
                        if isCapturing {
                            ProgressView().scaleEffect(0.6).controlSize(.small)
                        }
                        Text(isCapturing ? "Saving…" : "Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCapturing)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { urlFieldFocused = true }
    }

    private func capture() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCapturing else { return }
        isCapturing = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let result = try await ReaderCapture.capture(urlString: trimmed, archiveRoot: archiveRoot)
                isCapturing = false
                onSaved(result.fileURL)
                dismiss()
            } catch {
                isCapturing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
