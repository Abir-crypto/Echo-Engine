import EchoCore
import SwiftUI
#if DEBUG
import EchoCoreFakes
#endif

/// Projects tab (SPEC § 14.1, mockups `Design/screens/Home*.dc.html`).
struct HomeView: View {
    let model: HomeModel
    let onImport: () -> Void
    let onRecord: () -> Void

    @State private var renaming: Project?
    @State private var newTitle = ""
    @State private var deleting: PendingDeletion?

    var body: some View {
        NavigationStack {
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
                        // The mockup's gear is grey, not tinted.
                        .tint(.token(.textSecondary))
                    }
                }
                .task { await model.load() }
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
                            ProjectCard(project: stored.project, now: .now)
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
        Button(action: onImport) {
            Label("Import audio or video", systemImage: "plus")
        }
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
        case .readOnly: String(localized: "This project was made with a newer version of Echo Engine. Update the app to change it.")
        }
    }
}

#if DEBUG
@MainActor
private func previewModel(_ projects: [Project]) -> HomeModel {
    HomeModel(repository: FakeProjectRepository(projects: projects))
}

private extension View {
    /// The gear opens Settings, whose debug menu reads the container.
    func previewContainer() -> some View {
        environment(AppContainer(projects: FakeProjectRepository()))
    }
}

#Preview("Dark") {
    HomeView(model: previewModel(PreviewProjects.all()), onImport: {}, onRecord: {})
        .previewContainer()
        .preferredColorScheme(.dark)
}

#Preview("Light, teal") {
    HomeView(model: previewModel(PreviewProjects.all()), onImport: {}, onRecord: {})
        .previewContainer()
        .environment(\.appTint, .teal)
        .tint(AppTint.teal.text)
        .preferredColorScheme(.light)
}

#Preview("Arabic RTL, XXL") {
    HomeView(model: previewModel(PreviewProjects.all()), onImport: {}, onRecord: {})
        .previewContainer()
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
        .dynamicTypeSize(.xxxLarge)
}

#Preview("Empty") {
    HomeView(model: previewModel([]), onImport: {}, onRecord: {})
        .previewContainer()
}
#endif
