import SwiftUI

/// A grouped container: `Surface`, radius 14, rows separated by `Separator` (SPEC § 18.4). Put `RowSeparator()`
/// between rows.
struct GroupedRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.token(.surface), in: .rect(cornerRadius: 14))
    }
}

struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.token(.separator))
            .frame(height: 1)
            .padding(.leading, 14)
            .accessibilityHidden(true)
    }
}

/// A switch with a title and a one-line explanation; toggles use `Success` (SPEC § 18.4).
struct ToggleRow: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
        .tint(.token(.success))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
    }
}
