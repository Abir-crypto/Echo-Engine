import EchoCore
import SwiftUI
import UniformTypeIdentifiers

/// Files and Share need the person (SPEC § 11.2 step 5): their destinations ask this presenter, the export screen
/// shows its request as the Files exporter or the share sheet (`presentsDeliveries`), and the delivery waits for how
/// that ended, so post-export actions run only after a confirmed save (step 6).
@MainActor
@Observable
final class DeliveryPresenter {
    struct Request: Identifiable, Equatable, Sendable {
        let id = UUID()
        let kind: DestinationKind
        let file: URL
    }

    private(set) var request: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<DeliveryOutcome, any Error>?

    /// Shows `file` for `kind` until the person saves, shares or closes it. A newer request closes this one
    /// (`.cancelled`), and so does cancelling the calling task.
    func present(_ file: URL, kind: DestinationKind) async throws -> DeliveryOutcome {
        finish(.cancelled)
        let request = Request(kind: kind, file: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                self.continuation = continuation
                self.request = request
            }
        } onCancel: {
            Task { @MainActor in self.complete(.success(.cancelled), ifShowing: request.id) }
        }
    }

    /// The person saved or shared (`.delivered`), or closed without doing so (`.cancelled`).
    func finish(_ outcome: DeliveryOutcome) {
        complete(.success(outcome), ifShowing: nil)
    }

    /// Saving to the chosen place failed.
    func fail() {
        complete(.failure(ExportError.deliveryFailed), ifShowing: nil)
    }

    private func complete(_ result: Result<DeliveryOutcome, any Error>, ifShowing id: UUID?) {
        guard let continuation, id == nil || id == request?.id else { return }
        self.continuation = nil
        request = nil
        continuation.resume(with: result)
    }
}

/// Files (`fileExporter`) or Share (activity sheet) through the presenter.
struct InteractiveDestination: ExportDestination {
    let kind: DestinationKind
    let presenter: DeliveryPresenter

    func deliver(_ file: URL) async throws -> DeliveryOutcome {
        try await presenter.present(file, kind: kind)
    }
}

extension View {
    /// Shows the presenter's request: the Files exporter or the share sheet.
    func presentsDeliveries(_ presenter: DeliveryPresenter) -> some View {
        modifier(DeliveryPresentation(presenter: presenter))
    }
}

private struct DeliveryPresentation: ViewModifier {
    let presenter: DeliveryPresenter

    func body(content: Content) -> some View {
        let files = presenter.request.flatMap { $0.kind == .files ? ExportedFile(url: $0.file) : nil }
        content
            .fileExporter(
                // Closing is reported through `onCompletion` / `onCancellation`; the setter has nothing to add.
                isPresented: Binding(get: { files != nil }, set: { _ in }),
                item: files,
                contentTypes: files.map { [$0.contentType] } ?? [],
                defaultFilename: files?.url.deletingPathExtension().lastPathComponent,
                onCompletion: { result in
                    switch result {
                    case .success: presenter.finish(.delivered)
                    case .failure: presenter.fail()
                    }
                },
                onCancellation: { presenter.finish(.cancelled) }
            )
            .sheet(item: shareRequest) { request in
                ActivityView(file: request.file) { completed in
                    presenter.finish(completed ? .delivered : .cancelled)
                }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
            }
    }

    private var shareRequest: Binding<DeliveryPresenter.Request?> {
        Binding(
            get: { presenter.request?.kind == .share ? presenter.request : nil },
            // Swiped away without choosing anything.
            set: { if $0 == nil { presenter.finish(.cancelled) } }
        )
    }
}

/// The export file, handed to the Files exporter as a file (never loaded into memory).
struct ExportedFile: Transferable {
    let url: URL

    var contentType: UTType {
        UTType(filenameExtension: url.pathExtension) ?? .data
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .quickTimeMovie) { SentTransferredFile($0.url) }
        FileRepresentation(exportedContentType: .mpeg4Movie) { SentTransferredFile($0.url) }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "m4v") ?? .movie) { SentTransferredFile($0.url) }
        FileRepresentation(exportedContentType: .mpeg4Audio) { SentTransferredFile($0.url) }
        FileRepresentation(exportedContentType: .wav) { SentTransferredFile($0.url) }
        FileRepresentation(exportedContentType: UTType(filenameExtension: "flac") ?? .audio) { SentTransferredFile($0.url) }
    }
}

/// The system share sheet; reports whether the person completed an action.
private struct ActivityView: UIViewControllerRepresentable {
    let file: URL
    let onFinish: (_ completed: Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
