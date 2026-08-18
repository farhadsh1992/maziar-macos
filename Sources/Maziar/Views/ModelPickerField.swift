import SwiftUI

/// A model-version text field with a quick-fill menu of known versions for the given provider —
/// "select version" as a list, without losing the ability to type a model that isn't on the list
/// yet (provider lineups change often, so the text field stays the source of truth).
struct ModelPickerField: View {
    let provider: AIProviderKind
    @Binding var modelText: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("Model", text: $modelText, prompt: Text(provider.suggestedModel))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Menu {
                ForEach(provider.knownModelVersions, id: \.self) { version in
                    Button(version) { modelText = version }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a known \(provider.displayName) model version")
        }
    }
}
