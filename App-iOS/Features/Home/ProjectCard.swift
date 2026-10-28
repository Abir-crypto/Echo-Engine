import EchoCore
import SwiftUI

/// A Home grid card: thumbnail with type and duration badges, title, last-changed date (SPEC § 14.1).
struct ProjectCard: View {
    let project: Project
    let now: Date
    @Environment(\.appTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                Text(DisplayFormat.projectDate(project.updatedAt, now: now))
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.token(.surface))
            .aspectRatio(169 / 104, contentMode: .fit)
            .overlay {
                PlaceholderWaveform(seed: project.id, color: project.isProcessed ? tint.wave : .token(.waveformIdle))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 30)
            }
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
}

/// Stand-in bars until real waveform thumbnails exist (F03.T05); stable per project. Forced left-to-right.
private struct PlaceholderWaveform: View {
    let seed: UUID
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(Array(Self.levels(seed: seed).enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(height: max(2, geometry.size.height * level))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    /// 24 levels in 0.3...0.95 from the UUID's bytes.
    private static func levels(seed: UUID) -> [Double] {
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        return (0..<24).map { index in
            let byte = bytes[index % bytes.count] &+ UInt8(truncatingIfNeeded: index &* 37)
            return 0.3 + Double(byte) / 255 * 0.65
        }
    }
}
