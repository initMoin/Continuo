import SwiftUI

struct IntelligenceSettingsView: View {
    let viewModel: ContinuoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: StitchIntelligenceMode

    init(viewModel: ContinuoViewModel) {
        self.viewModel = viewModel
        _selection = State(initialValue: viewModel.intelligenceMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Stitching assistance", selection: $selection) {
                        ForEach(StitchIntelligenceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .tint(ContinuoDesign.primaryAction)
                    .onChange(of: selection) { _, mode in
                        viewModel.setIntelligenceMode(mode)
                    }
                } footer: {
                    Text(selection.description)
                }

                Section("Privacy") {
                    Label(
                        "Vision runs on the device and is used only for image alignment.",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.secondary)
                    Text("Foundation Models receives screenshot metadata only. Full-resolution image pixels stay in Continuo and are never sent to a model.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
#if os(macOS)
            .formStyle(.grouped)
#endif
            .fontDesign(.rounded)
            .navigationTitle("Intelligence")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
#if os(macOS)
        .frame(width: 640, height: 480, alignment: .topLeading)
#endif
    }
}
