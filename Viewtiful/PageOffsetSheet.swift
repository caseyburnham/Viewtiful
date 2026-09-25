import SwiftUI

/// Aligns the viewer's page numbers with the script's. A PDF whose first page is
/// marked "5" is given that number here, after which the page readout, the page
/// field, and OSC and MIDI page cues all speak in the script's numbering.
struct PageOffsetSheet: View {
    @Bindable var model: ViewerModel
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for front matter or an appendix, and bounded so the numbering
    /// cannot be pushed somewhere no page can be reached.
    private static let numberRange = -998...1_000

    /// Clamped on the way in, since the field accepts whatever is typed.
    private var firstPageNumber: Binding<Int> {
        Binding(
            get: { model.firstPageNumber },
            set: { model.firstPageNumber = min(max($0, Self.numberRange.lowerBound), Self.numberRange.upperBound) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("First Page Is Numbered") {
                        HStack {
                            TextField("First Page Number", value: firstPageNumber, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(maxWidth: 80)
                                #if !os(macOS)
                                .keyboardType(.numbersAndPunctuation)
                                #endif
                            Stepper("First Page Number", value: firstPageNumber, in: Self.numberRange)
                                .labelsHidden()
                        }
                    }

                    if model.lastPageNumber > 0 {
                        LabeledContent("Pages", value: "\(model.firstPageNumber)–\(model.lastPageNumber)")
                            .monospacedDigit()
                    }

                    if model.pageOffset != 0 {
                        Button("Use the PDF’s Own Numbering") { model.pageOffset = 0 }
                    }
                } footer: {
                    Text("Enter the number printed on the script’s first page. It’s remembered for this document.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Page Numbering")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationSizing(.form)
        #if !os(macOS)
        .presentationDetents([.medium])
        #endif
    }
}
