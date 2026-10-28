import EchoCore
import SwiftUI

/// What a card shows in its thumbnail well.
enum ProjectThumbnail {
    /// Video frame at 10% (`thumbnail.jpg`).
    case frame(UIImage)
    /// Waveform overview levels (`waveform-overview.json`).
    case levels([Float])
}

/// A Home grid card: thumbnail with type and duration badges, title, and the last-changed date or a storage
/// warning (SPEC § 14.1).
struct ProjectCard: View {
    let project: Project
    let thumbnail: ProjectThumbnail?
    let readiness: ProjectReadiness?
    let now: Date
    @Environment(\.appTint) private var tint

    private static let barCount = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailWell
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                subtitle
                    .font(.footnote)
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch readiness {
        case .needsSpaceToEdit(let bytes):
            Text("Needs \(DisplayFormat.fileSize(bytes)) to edit")
                .foregroundStyle(.token(.warning))
        case .needsSpaceToExport(let bytes):
            Text("Needs \(DisplayFormat.fileSize(bytes)) to export")
                .foregroundStyle(.token(.warning))
        case .ready, nil:
            Text(DisplayFormat.projectDate(project.updatedAt, now: now))
                .foregroundStyle(.token(.textSecondary))
        }
    }

    private var thumbnailWell: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.token(.surface))
            .aspectRatio(169 / 104, contentMode: .fit)
            .overlay { thumbnailContent }
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .topLeading) {
                Image(systemName: project.mediaType == .video ? "video" : "mic")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.token(.textValue))
                    .frame(width: 26, height: 26)
                    .background(.token(.badgeFill), in: .rect(cornerRadius: 8))
                    .padding(10)
                    .accessibilityLabel(project.mediaType == .video ? Text("Video") : Text("Audio"))
            }
            .overlay(alignment: .bottomTrailing) {
                Text(DisplayFormat.duration(project.sourceInfo.duration))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.token(.textPrimary))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(.token(.badgeFill), in: .rect(cornerRadius: 7))
                    .padding(10)
            }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch thumbnail {
        case .frame(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        case .levels(let levels):
            bars(WaveformBars.bars(from: levels, count: Self.barCount))
        case nil:
            bars(WaveformBars.placeholder(seed: project.id, count: Self.barCount))
        }
    }

    /// Processed audio is tinted, untouched audio is grey (SPEC § 18.1).
    private func bars(_ levels: [Double]) -> some View {
        WaveformBars(levels: levels, color: project.isProcessed ? tint.wave : .token(.waveformIdle))
            .padding(.horizontal, 14)
            .padding(.vertical, 30)
    }
}
