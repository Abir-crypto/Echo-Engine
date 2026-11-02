import EchoCore
import SwiftUI

extension AIFeature {
    /// The feature's name in the stack and the Add sheet (SPEC § 7, § 9).
    var displayName: LocalizedStringKey {
        switch self {
        case .noiseSuppression: "Noise Suppression"
        case .clearVoice: "Clear Voice"
        case .voiceLeveler: "Voice Leveler"
        case .unknown: "Enhancement from a newer version"
        }
    }

    /// The same name as a string, for lists such as a preset's steps (same catalog keys as `displayName`).
    var localizedName: String {
        switch self {
        case .noiseSuppression: String(localized: "Noise Suppression")
        case .clearVoice: String(localized: "Clear Voice")
        case .voiceLeveler: String(localized: "Voice Leveler")
        case .unknown: String(localized: "Enhancement from a newer version")
        }
    }

    /// One line for the Add enhancement sheet.
    var summary: LocalizedStringKey {
        switch self {
        case .noiseSuppression: "Removes background noise such as fans, traffic and hum."
        case .clearVoice: "Removes noise and makes speech crisper and more even."
        case .voiceLeveler: "Evens out loud and quiet speakers."
        case .unknown: "Update Echo Engine to use it."
        }
    }
}
