import EchoCore
import PhotosUI
import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

enum HomeRoute: Hashable {
    case project(UUID)
}

/// Projects tab (SPEC § 14.1, mockups `Design/screens/Home*.dc.html`). Import flow: SPEC § 10.
struct HomeView: View {
    let model: HomeModel
    let importModel: ImportModel
    let onRecord: () -> Void

    @State private var path: [HomeRoute] = []
    @State private var renaming: Project?
    @State private var newTitle = ""
    @State private var deleting: PendingDeletion?
    @State private var choosesPhotos = false
    @State private var choosesFiles = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Color.token(.ground).ignoresSafeArea())
                .navigationTitle("Projects")
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        // Circle-button glyphs use TextValue, not the tint (SPEC § 18.4).
                        .tint(.token(.textValue))
                    }
                }
                .task { await model.load() }
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .project(let id):
                        if let stored = model.projects.first(where: { $0.project.id == id }) {
                            EditorView(project: stored.project)
                        }
                    }
                }
                .alert("Rename project", isPresented: isPresented($renaming), presenting: renaming) { project in
                    TextField("Title", text: $newTitle)
                    Button("Cancel", role: .cancel) {}
                    Button("Rename") {
                        Task { await model.rename(project.id, to: newTitle) }
                    }
                }
                .confirmationDialog(
                    deleting.map { Text("Delete “\($0.title)”?") } ?? Text(verbatim: ""),
                    isPresented: isPresented($deleting),
                    titleVisibility: .visible,
                    presenting: deleting
                ) { deletion in
                    Button("Delete project", role: .destructive) {
                        Task { await model.delete(deletion.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { deletion in
                    if let bytes = deletion.bytes {
                        Text("This frees \(DisplayFormat.fileSize(bytes)). It can’t be undone.")
                    } else {
                        Text("It can’t be undone.")
                    }
                }
                .alert(isPresented: isPresented(failureBinding), error: model.failure.map(HomeFailureMessage.init)) {
                    Button("OK") {}
                }
        }
        .photosPicker(isPresented: $choosesPhotos, selection: $photoItem, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            importModel.importFromPhotos { try await item.loadTransferable(type: PickedMovie.self)?.url }
        }
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.movie, .audio]) { result in
            if case .success(let url) = result {
                importModel.importFile(at: url)
            }
        }
        .sheet(isPresented: .constant(importModel.phase != .idle || importModel.failure != nil)) {
            ImportProgressView(
                phase: importModel.phase,
                failure: importModel.failure,
                onCancel: importModel.cancel,
                onDismissFailure: { importModel.failure = nil }
            )
        }
        .onChange(of: importModel.importedProject?.id) { _, id in
            guard let id else { return }
            Task {
                await model.load()
                path.append(.project(id))
                importModel.didOpenImportedProject()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasLoaded && model.projects.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    importButton
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(model.projects, id: \.project.id) { stored in
                            NavigationLink(value: HomeRoute.project(stored.project.id)) {
                                ProjectCard(
                                    project: stored.project,
                                    thumbnail: model.thumbnails[stored.project.id],
                                    readiness: model.readiness[stored.project.id],
                                    now: .now
                                )
                            }
                            .task(id: stored.project.id) { await model.loadThumbnail(for: stored.project) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: stored) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var importButton: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { choosesPhotos = true }
            Button("Files", systemImage: "folder") { choosesFiles = true }
        } label: {
            Label("Import audio or video", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.primary)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.token(.iconMuted))
                .accessibilityHidden(true)
            Text("Import a video or audio file, or record something new.")
                .font(.body)
                .foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center)
            importButton
            Button(action: onRecord) {
                Label("Record", systemImage: "mic")
            }
            .buttonStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func menu(for stored: StoredProject) -> some View {
        if !stored.isReadOnly {
            Button("Rename", systemImage: "pencil") {
                newTitle = stored.project.title
                renaming = stored.project
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
                let bytes = await model.diskUsage(of: stored.project.id)
                deleting = PendingDeletion(id: stored.project.id, title: stored.project.title, bytes: bytes)
            }
        }
    }

    private var failureBinding: Binding<HomeModel.Failure?> {
        Binding(get: { model.failure }, set: { model.failure = $0 })
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct PendingDeletion {
    let id: UUID
    let title: String
    let bytes: Int64?
}

/// What happened and what to do; never apologizes (SPEC § 4.7).
private struct HomeFailureMessage: LocalizedError {
    let failure: HomeModel.Failure

    var errorDescription: String? {
        switch failure {
        case .load: String(localized: "Projects couldn’t be loaded. Restart Echo Engine to try again.")
        case .rename: String(localized: "The project couldn’t be renamed. Try again.")
        case .delete: String(localized: "The project couldn’t be deleted. Try again.")
        case .readOnly: String(localized: "Update Echo Engine to edit this project.")
        }
    }
}

#if DEBUG
@MainActor
private func previewModel(_ projects: [Project]) -> HomeModel {
    HomeModel(
        repository: FakeProjectRepository(projects: projects, overviewsByID: PreviewProjects.overviews(for: projects)),
        storage: FakeStorageEstimator(editBytes: 1_200_000_000, available: 1_000_000_000)
    )
}

@MainActor
private func previewImportModel() -> ImportModel {
    let sample = PreviewProjects.all()[0]
    return ImportModel(
        inspector: FakeMediaInspector(result: MediaInspection(mediaType: .video, sourceInfo: sample.sourceInfo, fileExtension: "mov")),
        importer: FakeMediaImporter(),
        storage: FakeStorageEstimator(),
        repository: FakeProjectRepository(),
        dateProvider: FakeClock()
    )
}

private extension View {
    /// The gear opens Settings, whose debug menu reads the container.
    func previewContainer() -> some View {
        environment(AppContainer(projects: FakeProjectRepository()))
    }
}

#Preview("Dark") {
    HomeView(model: previewModel(PreviewProjects.all()), importModel: previewImportModel(), onRecord: {})
        .previewContainer()
        .preferredColorScheme(.dark)
}

#Preview("Light, teal") {
    HomeView(model: previewModel(PreviewProjects.all()), importModel: previewImportModel(), onRecord: {})
        .previewContainer()
        .environment(\.appTint, .teal)
        .tint(AppTint.teal.text)
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    HomeView(model: previewModel(PreviewProjects.all()), importModel: previewImportModel(), onRecord: {})
        .previewContainer()
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}

#Preview("Empty") {
    HomeView(model: previewModel([]), importModel: previewImportModel(), onRecord: {})
        .previewContainer()
}
#endif
