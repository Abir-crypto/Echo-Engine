import EchoCore
import SwiftUI
import UniformTypeIdentifiers

/// A project's details and what it takes on disk, by part (SPEC § 15): the original, working audio, recordings and
/// enhancements (renders, which can always be made again).
struct ProjectInfoSheet: View {
    let project: Project
    let model: HomeModel

    @Environment(\.dismiss) private var dismiss
    @State private var storage: (folder: ProjectStorage, renders: Int64)?
    @State private var isMeasured = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle(Text("Details", comment: "Project info section."))
                        GroupedRows {
                            row(Text("Duration", comment: "Project info row."), value: DisplayFormat.duration(project.sourceInfo.duration))
                            RowSeparator()
                            row(Text("Format"), value: format)
                            RowSeparator()
                            row(Text("Created", comment: "Project info row."), value: project.createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle(Text("Storage"))
                        GroupedRows {
                            if let storage {
                                if storage.folder.source > 0 {
                                    row(Text("Original", comment: "Project info: the imported file."), value: DisplayFormat.fileSize(storage.folder.source))
                                    RowSeparator()
                                }
                                row(Text("Working audio", comment: "Project info: the extracted audio being edited."), value: DisplayFormat.fileSize(storage.folder.working))
                                if storage.folder.takes > 0 {
                                    RowSeparator()
                                    row(Text("Recordings", comment: "Project info: the recorded takes."), value: DisplayFormat.fileSize(storage.folder.takes))
                                }
                                RowSeparator()
                                row(Text("Enhancements", comment: "Project info: cached renders of the AI steps."), value: DisplayFormat.fileSize(storage.renders))
                                RowSeparator()
                                row(Text("Total", comment: "Project info: everything the project takes."), value: DisplayFormat.fileSize(storage.folder.folder + storage.renders), isTotal: true)
                            } else if isMeasured {
                                row(Text("Total", comment: "Project info: everything the project takes."), value: "—")
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                        }
                        Text("Enhancements are made again when needed. Projects aren’t included in iCloud backup.")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Color.token(.ground).ignoresSafeArea())
            .navigationTitle(Text(verbatim: project.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            storage = await model.storage(of: project.id)
            isMeasured = true
        }
    }

    /// "QuickTime movie · Stereo, 48 kHz".
    private var format: String {
        let container = UTType(project.sourceInfo.container)?.localizedDescription ?? project.sourceInfo.container
        let channels: String = switch project.sourceInfo.channelCount {
        case 1: String(localized: "info.mono", defaultValue: "Mono", comment: "Project info: one audio channel.")
        case 2: String(localized: "info.stereo", defaultValue: "Stereo", comment: "Project info: two audio channels.")
        default: String(localized: "\(project.sourceInfo.channelCount) channels", comment: "Project info: number of audio channels (3 or more).")
        }
        let rate = (project.sourceInfo.sampleRate / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "\(container) · \(channels), \(rate) kHz", comment: "Project info format: container, channels and sample rate, e.g. QuickTime movie · Stereo, 48 kHz.")
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.token(.textSecondary))
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: Text, value: String, isTotal: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            title
                .font(.body.weight(.semibold))
                .foregroundStyle(.token(.textPrimary))
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(isTotal ? .subheadline.weight(.semibold) : .subheadline)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.token(.textValue))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}
