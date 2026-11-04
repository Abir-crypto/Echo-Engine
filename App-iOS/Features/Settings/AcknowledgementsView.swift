import SwiftUI

/// Third-party software in the app and its licenses (SPEC § 14.2). License texts stay in English, as written.
struct AcknowledgementsView: View {
    private struct Acknowledgement: Identifiable {
        let name: String
        let license: Text
        let fileName: String
        var id: String { name }
    }

    private let acknowledgements = [
        Acknowledgement(
            name: "RNNoise", license: Text("Noise suppression. BSD 3-Clause License.", comment: "Acknowledgements: what RNNoise is for and its license."),
            fileName: "RNNoise"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(acknowledgements) { acknowledgement in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: acknowledgement.name)
                            .font(.title3.bold())
                            .foregroundStyle(.token(.textPrimary))
                        acknowledgement.license
                            .font(.subheadline)
                            .foregroundStyle(.token(.textSecondary))
                        Text(verbatim: Self.text(named: acknowledgement.fileName))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.token(.textValue))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.token(.surface), in: .rect(cornerRadius: 14))
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.token(.ground).ignoresSafeArea())
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func text(named name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

#Preview {
    NavigationStack { AcknowledgementsView() }
}
