import EchoCore

extension Preset {
    /// Built-ins have localized names (SPEC § 12); user presets show what the person typed.
    var displayName: String {
        switch id {
        case BuiltInPresetID.podcastVoice where isBuiltIn:
            String(localized: "Podcast Voice", comment: "Built-in preset: noise suppression, Voice Leveler, podcast loudness.")
        case BuiltInPresetID.outdoorVideo where isBuiltIn:
            String(localized: "Outdoor Video", comment: "Built-in preset: strong noise suppression, Clear Voice, YouTube loudness.")
        case BuiltInPresetID.singing where isBuiltIn:
            String(localized: "Singing", comment: "Built-in preset: light noise suppression, gentle compression, a little reverb.")
        default:
            name
        }
    }
}
