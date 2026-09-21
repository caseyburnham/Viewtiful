import SwiftUI

/// Aligns the viewer's page numbers with the script's. A PDF whose first page is
/// marked "5" needs an offset of 4, after which the page readout, the page field,
/// and OSC page cues all speak in the script's numbering.
struct PageOffsetSheet: View {
    @Bindable var model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for front matter or an appendix, and bounded so the offset cannot
    /// be pushed somewhere no page can be reached.
    private static let offsetLimit = 999

    var body: some View {
        #if os(macOS)
        VStack(alignment: .trailing, spacing: 0) {
            form
                .formStyle(.grouped)
            Divider()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding()
        }
        .frame(width: 420, height: 300)
        #else
        NavigationStack {
            form
                .navigationTitle("Page Numbering")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Stepper(value: $model.pageOffset, in: -Self.offsetLimit...Self.offsetLimit) {
                    LabeledContent("Page Offset",
                                   value: model.pageOffset,
                                   format: .number.sign(strategy: .always()))
                }

                LabeledContent("First PDF Page Is Numbered") {
                    Text(model.firstPageNumber, format: .number)
                        .monospacedDigit()
                }

                if model.pageOffset != 0 {
                    Button("Use the PDF's Own Numbering") { model.pageOffset = 0 }
                }
            } header: {
                Text("Page Numbering")
            } footer: {
                Text("Shifts the page numbers Viewtiful shows and accepts so they match the numbers printed on the script. The offset is remembered for this document. MIDI Program Change recall keeps its own separate offset in Settings.")
            }
        }
    }
}
