import SwiftUI

struct PromptSuggestionView: View {
    @State private var text: String
    let accept: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    init(suggestion: String, accept: @escaping (String) -> Void) {
        _text = State(initialValue: suggestion); self.accept = accept
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Review Prompt", systemImage: "text.bubble").font(.title2.bold())
            Text("Edit Claude’s suggestion before sending it to your image provider.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).padding(8).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Keep Original") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Prompt") { accept(text); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560, height: 400)
            .background(PaperTexture.surface).preferredColorScheme(.light).tint(PaperTexture.accent)
    }
}
