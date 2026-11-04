import EchoCore
import SwiftUI

/// Creates the presets model once per visit.
struct PresetsScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var model: PresetsModel?

    var body: some View {
        if let model {
            PresetsView(model: model)
        } else {
            Color.token(.ground)
                .ignoresSafeArea()
                .task { model = PresetsModel(repository: container.presets) }
        }
    }
}

/// Settings → Presets (SPEC § 12, § 14.2): rename or delete your presets (swipe, or touch and hold); built-ins are
/// listed read-only.
struct PresetsView: View {
    let model: PresetsModel

    @State private var renaming: Preset?
    @State private var newName = ""
    @State private var deleting: Preset?

    var body: some View {
        List {
            Section {
                if model.userPresets.isEmpty, model.isLoaded {
                    Text("Presets you save in the editor appear here. Use Save as preset in the Enhance menu.")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .listRowBackground(Color.token(.surface))
                }
                ForEach(model.userPresets) { preset in
                    row(preset)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { deleting = preset }
                            Button("Rename") { startRenaming(preset) }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { startRenaming(preset) }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = preset }
                        }
                }
            } header: {
                sectionHeader("Your presets")
            }
            Section {
                ForEach(model.builtIns) { preset in
                    row(preset)
                }
            } header: {
                sectionHeader("Built-in")
            } footer: {
                Text("Built-in presets can’t be changed. Apply one, then save it as your own.")
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.token(.ground).ignoresSafeArea())
        .crashReportScreen("presets")
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .alert("Rename preset", isPresented: isPresented($renaming), presenting: renaming) { preset in
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await model.rename(preset.id, to: newName) } }
        }
        .confirmationDialog(
            deleting.map { Text("Delete “\($0.displayName)”?") } ?? Text(verbatim: ""),
            isPresented: isPresented($deleting),
            titleVisibility: .visible,
            presenting: deleting
        ) { preset in
            Button("Delete", role: .destructive) { Task { await model.delete(preset.id) } }
        } message: { _ in
            Text("Projects made with it keep their settings.")
        }
        .alert(isPresented: isPresented(failureBinding), error: model.failure.map(PresetsFailureMessage.init)) {
            Button("OK") {}
        }
    }

    private func row(_ preset: Preset) -> some View {
        Text(preset.displayName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
            .frame(minHeight: 44)
            .listRowBackground(Color.token(.surface))
            .listRowSeparatorTint(Color.token(.separator))
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.token(.textSecondary))
            .textCase(nil)
    }

    private func startRenaming(_ preset: Preset) {
        newName = preset.name
        renaming = preset
    }

    private var failureBinding: Binding<PresetsModel.Failure?> {
        Binding(get: { model.failure }, set: { model.failure = $0 })
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// What happened and what to do (SPEC § 4.7).
private struct PresetsFailureMessage: LocalizedError {
    let failure: PresetsModel.Failure

    var errorDescription: String? {
        switch failure {
        case .load: String(localized: "Presets couldn’t be read. Try again later.")
        case .rename: String(localized: "The preset couldn’t be renamed. Free up some space, then try again.")
        case .delete: String(localized: "The preset couldn’t be deleted. Try again.")
        }
    }
}
