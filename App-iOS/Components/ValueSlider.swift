import EchoCore
import SwiftUI

/// A slider row: title and current value on one line, the slider below (SPEC § 18.3, § 18.4). Ranges spanning
/// decades (frequency, times, Q) use a log scale. `onEditingEnded` runs once per drag, or per VoiceOver step.
struct ValueSlider: View {
    enum Scale {
        case linear, logarithmic
    }

    let title: LocalizedStringKey
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float?
    var scale = Scale.linear
    let format: (Float) -> String
    /// What VoiceOver reads instead of `format` (e.g. "2 semitones higher").
    var spokenValue: ((Float) -> String)?
    let onEditingEnded: () -> Void

    @Environment(\.appTint) private var tint
    /// VoiceOver steps move the slider by this fraction of its travel.
    private static let accessibilityStep = 0.05

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title and value share a line; at large text sizes the value moves under the title.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer(minLength: 12)
                    valueText
                }
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    valueText
                }
            }
            Slider(value: position, in: 0...1) { editing in
                if !editing { onEditingEnded() }
            }
            .tint(tint.fill)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(spokenValue?(value) ?? format(value)))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep
            position.wrappedValue = min(max(position.wrappedValue + delta, 0), 1)
            onEditingEnded()
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(.token(.textPrimary))
    }

    private var valueText: some View {
        Text(format(value))
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.token(.textValue))
    }

    /// The slider's 0…1 position for `value`, through the scale, snapped to `step`.
    private var position: Binding<Double> {
        Binding(
            get: { Self.position(of: value, in: range, scale: scale) },
            set: { value = Self.value(at: $0, in: range, scale: scale, step: step) }
        )
    }

    static func position(of value: Float, in range: ClosedRange<Float>, scale: Scale) -> Double {
        let clamped = Double(min(max(value, range.lowerBound), range.upperBound))
        let low = Double(range.lowerBound), high = Double(range.upperBound)
        switch scale {
        case .linear: return (clamped - low) / (high - low)
        case .logarithmic: return log(clamped / low) / log(high / low)
        }
    }

    static func value(at position: Double, in range: ClosedRange<Float>, scale: Scale, step: Float?) -> Float {
        let low = Double(range.lowerBound), high = Double(range.upperBound)
        var value = switch scale {
        case .linear: low + (high - low) * position
        case .logarithmic: low * pow(high / low, position)
        }
        if let step { value = (value / Double(step)).rounded() * Double(step) }
        return Float(min(max(value, low), high))
    }
}
