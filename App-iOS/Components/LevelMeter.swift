import EchoCore
import SwiftUI

/// The 30-segment level meter (SPEC § 18.5, Record mockup): lit segments in the tint, the last 4 in `Clip`, unlit ones
/// `Separator`. Always left to right (SPEC § 17); VoiceOver reads the level in dB.
struct LevelMeter: View {
    /// 0…1 on `MeterScale`.
    let level: Double
    var height: CGFloat = 10

    @Environment(\.appTint) private var tint

    var body: some View {
        let lit = MeterScale.litSegments(level)
        HStack(spacing: 3) {
            ForEach(0..<MeterScale.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(of: index, lit: lit))
            }
        }
        .frame(height: height)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(Text("Level", comment: "Accessibility label of the recording level meter."))
        .accessibilityValue(DisplayFormat.meterLevel(level))
    }

    private func color(of index: Int, lit: Int) -> Color {
        guard index < lit else { return .token(.separator) }
        return MeterScale.isClipSegment(index) ? .token(.clip) : tint.fill
    }
}

#Preview {
    VStack(spacing: 14) {
        LevelMeter(level: 0.63)
        LevelMeter(level: 0.95)
        LevelMeter(level: 0)
    }
    .padding(20)
    .background(Color.token(.ground))
}
