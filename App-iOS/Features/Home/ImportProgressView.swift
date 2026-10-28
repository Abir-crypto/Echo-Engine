import SwiftUI

/// The import sheet: progress with Cancel, then either closes (success) or explains a failure (SPEC § 10).
/// Failures show here rather than in an alert: an alert presented while this sheet dismisses is dropped.
struct ImportProgressView: View {
    let phase: ImportModel.Phase
    let failure: ImportModel.Failure?
    let onCancel: () -> Void
    let onDismissFailure: () -> Void
    @Environment(\.appTint) private var tint

    var body: some View {
        VStack(spacing: 18) {
            if let failure {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.token(.warning))
                    .accessibilityHidden(true)
                Text("Can’t import")
                    .font(.title3.bold())
                    .foregroundStyle(.token(.textPrimary))
                Text(ImportFailureMessage(failure: failure).text)
                    .font(.body)
                    .foregroundStyle(.token(.textSecondary))
                    .multilineTextAlignment(.center)
                Button("OK", action: onDismissFailure)
                    .buttonStyle(.primary)
            } else {
                Text("Importing")
                    .font(.title3.bold())
                    .foregroundStyle(.token(.textPrimary))
                switch phase {
                case .importing(let fraction):
                    ProgressView(value: fraction)
                        .tint(tint.fill)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.token(.textSecondary))
                case .preparing, .idle:
                    ProgressView()
                    Text("Preparing…")
                        .font(.subheadline)
                        .foregroundStyle(.token(.textSecondary))
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationBackground(.token(.surface))
        .interactiveDismissDisabled()
    }
}

/// What happened and what to do; never apologizes (SPEC § 4.7, § 10, § 15).
struct ImportFailureMessage {
    let failure: ImportModel.Failure

    var text: String {
        switch failure {
        case .unsupportedFormat:
            String(localized: "This file type isn’t supported. Import MOV, MP4 or M4V video, or M4A, AAC, MP3, WAV, AIFF, CAF or FLAC audio.")
        case .noAudio:
            String(localized: "This video has no audio. Choose a video with sound.")
        case .unreadable:
            String(localized: "This file can’t be read. Export it again from the app that made it, then import the new file.")
        case .needsSpace(let needed, let available):
            String(localized: "This project needs about \(DisplayFormat.fileSize(needed)). You have \(DisplayFormat.fileSize(available)) free. Free up space, then import again.")
        case .photosUnavailable:
            String(localized: "The video couldn’t be loaded from Photos. Make sure it’s downloaded from iCloud, then try again.")
        case .failed:
            String(localized: "The import couldn’t finish. Try again.")
        }
    }
}
