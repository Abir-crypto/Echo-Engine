# SPEC.md — Echo Engine v1

Audience: Claude Code. Terse and normative. "MUST" = required. Anything not covered: ask the user (see CLAUDE.md).

Contents: 1 Product · 2 Scope · 3 Platform · 4 Architecture · 5 Data model & storage · 6 Audio pipeline ·
7 AI features · 8 Manual controls · 9 Editor · 10 Import · 11 Export · 12 Presets · 13 Record ·
14 Home & Settings · 15 Storage management · 16 Analytics & crash reporting · 17 Localization & accessibility ·
18 Design system & screens · 19 Testing · 20 Decision log

---

## 1. Product

- Name (working): **Echo Engine**. Publisher: AppLab Ltd.
- Purpose: enhance audio for content creators, on-device.
- Personas:
  - **Video creators**: edit video elsewhere (CapCut, Premiere), import into Echo Engine, clean the audio,
    export back. Video stream MUST remain untouched (passthrough).
  - **Singers and podcasters**: record inside the app with live enhancement (noise reduction, leveling,
    auto-tune, backing track, multi-mic), then polish in the Editor.
- Positioning: professional, minimal, private. "Your audio never leaves your device."
- Two halves: **Editor** (import → enhance → export) and **Record** (capture with live processing).
- Also usable as a video-to-audio converter (export audio only, no effects).

## 2. Scope

### 2.1 v1 (build this)

- Import audio/video (copied into project), whole-file processing, trim start/end.
- AI features: Noise Suppression, Clear Voice, Voice Leveler (user-ordered stack), Auto Level (fixed final stage).
- Manual live chain: EQ, gain, gate, compressor, de-esser, limiter, reverb, pitch shift.
- Per-step rendering with cache, unified undo/redo, A/B listening.
- Export: video (passthrough), audio only, both; formats AAC/WAV/FLAC/ALAC; Photos/Files/share sheet.
- Presets: built-in + user presets, iCloud KVS sync of presets only.
- Record: audio only; any input device; multi-channel from one device (mixdown + per-channel raw files);
  suppression tiers Off/Standard/High; input gain; gentle live leveling + clip limiter; live auto-tune;
  backing track (user-imported instrumental) with latency compensation; background recording.
- Home: list/open/rename/delete projects. Settings: appearance, tint, privacy toggles, storage, acknowledgements.
- Firebase Analytics + Crashlytics with consent. 11 languages. iPhone + iPad.

### 2.2 Later (DO NOT build; only the hooks named in this spec)

Dereverb · Wind Removal · Isolate/Remove Vocals (stem separation) · "Voice Only" recording tier ·
DeepFilterNet upgrade · clips/splitting · multi-track editing · transcripts · captions (dropped) ·
speed change · MP3 export · paid tiers (StoreKit) · rewarded ads · early-adopter grandfathering ·
server processing · preset sharing files · project duplicate/folders · project sync · Mac app ·
AUv3 plugin distribution · hum removal / silence trim (rejected).

Hooks to prepare in v1: `Project.clips` (exactly one clip), `EntitlementProvider` (all unlocked),
`DeviceCapabilityChecking` (all supported), `AIProcessing` protocol (swappable backend),
`AudioDeviceManaging` protocol (Mac later), per-channel raw recording files, `schemaVersion` everywhere.

## 3. Platform

- iOS 26.0+, iPadOS 26.0+. iPhone 11 and later. No fallback code for older OS.
- iPad: same layouts as iPhone, adaptive (resizable windows, Split View, Stage Manager). No fixed screen sizes.
- Mac: future native SwiftUI target. v1 MUST keep `EchoCore` free of UIKit/AppKit.
- Orientation: iPhone portrait; iPad all orientations.
- Project generation: **XcodeGen** (`project.yml` in repo root is the source of truth; never hand-edit
  `.pbxproj`). If `xcodegen` is not installed, ask the user to run `brew install xcodegen`.
- Bundle ID: `akumatech.Echo-Engine`. Display name (`CFBundleDisplayName`): "Echo Engine".
- Apple team ID: not set yet; leave `DEVELOPMENT_TEAM` out of `project.yml` (simulator builds only). Ask the user
  for it before the first task that needs a real device (F10 checkpoint).
- The Xcode template project from the initial commit (`Echo Engine/`, `Echo Engine.xcodeproj`, incl. tracked
  `xcuserdata`) is deleted in F01.T02 and replaced by the XcodeGen layout (§ 4.2).

## 4. Architecture

### 4.1 Principles

- SwiftUI everywhere. Bridges only for `AVPlayerLayer` (video preview) and, if needed, Metal/`Canvas` waveforms.
- State: Observation (`@Observable`). Concurrency: async/await, actors. No Combine.
- Pattern: MVVM-lite. One `@Observable` model per screen. Models depend on protocols only.
- SOLID: single-purpose types, protocol-first, constructor injection, no service locators, no singletons
  (wrap Apple singletons such as `AVAudioSession`, `FileManager`, `NSUbiquitousKeyValueStore`).
- One composition root: `AppContainer` (only place that names concrete types). Injected into SwiftUI via environment.
- Fakes for every protocol in tests and previews, all in the `EchoCoreFakes` package target (one copy per fake).

### 4.2 Modules

```
EchoEngine/
├── project.yml
├── App-iOS/
│   ├── EchoEngineApp.swift          # @main, AppContainer, appearance/tint, consent gate
│   ├── Features/Home/  Editor/  Record/  Export/  Presets/  Settings/  Onboarding/
│   ├── Components/                  # Waveform, TrimStrip, LevelMeter, SegmentedPicker, Row, etc.
│   ├── Platform/                    # iOS implementations: IOSAudioDeviceManager, PhotosExporter, LiveActivity
│   └── Resources/ (Assets.xcassets, Localizable.xcstrings, BuiltInPresets/, PrivacyInfo.xcprivacy)
├── RecordingWidget/                 # Live Activity widget extension
└── Packages/EchoCore/
    ├── Sources/EchoCore/            # models, services, pipeline, render, export, presets, storage (Swift)
    ├── Sources/CEchoDSP/            # C/C++: RNNoise (vendored), DSP kernels, pitch detection/shift
    ├── Sources/EchoAudioUnits/      # AUAudioUnit subclasses wrapping CEchoDSP kernels
    ├── Sources/EchoCoreFakes/       # fakes for every protocol; used by package tests, app tests, SwiftUI previews
    └── Tests/EchoCoreTests/         # Swift Testing + golden files (Resources/TestAudio/)
```

### 4.3 Services (protocol → single responsibility → v1 concrete)

| Protocol | Responsibility | v1 implementation |
|---|---|---|
| `ProjectRepository` | list/load/save/rename/delete project folders | `FileProjectRepository` |
| `ProjectMigrating` | schema migrations on load | `ProjectMigrator` |
| `MediaImporting` | copy source into project, extract working audio | `AVMediaImporter` |
| `MediaInspecting` | duration, tracks, container, codec, size | `AVMediaInspector` |
| `AIProcessing` | run ONE AI op on an input file → output file | `RNNoiseProcessor`, `ClearVoiceProcessor`, `VoiceLevelerProcessor` (routed by `AIProcessorRouter`) |
| `RenderCaching` | key, lookup, store, remove renders | `FileRenderCache` (ALAC) |
| `AIChainRendering` | walk stack using cache + processor, progress, cancellation | `AIChainRenderer` |
| `RenderCacheJanitoring` | mark-and-sweep unreachable renders, budget | `RenderCacheJanitor` |
| `LoudnessAnalyzing` | integrated LUFS / true peak of a file range | `EBUR128Analyzer` |
| `PlaybackEngine` | real-time preview: AI render + live manual chain (+ video sync) | `AVPlaybackEngine` |
| `RecordingEngine` | live capture, processing, file writing | `AVRecordingEngine` |
| `AudioDeviceManaging` | session config, inputs, channels, latency, route changes | `IOSAudioDeviceManager` |
| `ExportService` | offline final render + encode + remux | `AVExportService` |
| `ExportDestination` | deliver file to Photos / Files / share | `PhotosDestination`, `FilesDestination`, `ShareDestination` |
| `PresetRepository` | CRUD presets | `FilePresetRepository` wrapped by `SyncedPresetRepository` |
| `StorageEstimating` | bytes needed per stage, bytes available | `StorageEstimator` |
| `EntitlementProvider` | feature unlocked? | `FreeV1Entitlements` (always true) |
| `DeviceCapabilityChecking` | device supports feature? | `DefaultCapabilities` (always true in v1) |
| `KeyDetecting` | musical key of a backing track | `ChromaKeyDetector` |
| `AnalyticsTracking` | typed events | `FirebaseAnalyticsTracker`, `NoOpAnalytics` |
| `CrashReporting` | context, log, record error | `CrashlyticsReporter`, `NoOpCrashReporter` |
| `ConsentStore` | analytics/crash consent | `UserDefaultsConsentStore` |
| `AppSettingsStore` | appearance, tint, last export settings | `@AppStorage`-backed |
| `Clock`/`DateProviding` | testable time | `SystemClock` |

### 4.4 Composition root (shape)

```swift
@MainActor
final class AppContainer {
    let devices: AudioDeviceManaging = IOSAudioDeviceManager()
    let entitlements: EntitlementProvider = FreeV1Entitlements()
    let capabilities: DeviceCapabilityChecking = DefaultCapabilities()
    lazy var projects: ProjectRepository = FileProjectRepository(root: .projectsDirectory, migrator: ProjectMigrator())
    lazy var cache: RenderCaching = FileRenderCache(root: .renderCacheDirectory)
    lazy var renderer: AIChainRendering = AIChainRenderer(processor: AIProcessorRouter(), cache: cache)
    lazy var janitor: RenderCacheJanitoring = RenderCacheJanitor(cache: cache)
    lazy var presets: PresetRepository = SyncedPresetRepository(local: FilePresetRepository(root: .presetsDirectory))
    lazy var analytics: AnalyticsTracking = FirebaseAnalyticsTracker(consent: consent)
    // ...
    func makeEditorModel(for project: Project) -> EditorModel { /* inject protocols only */ }
}
```

### 4.5 Real-time audio rules (MUST)

- Render callbacks: no allocation, locks, ObjC/Swift reference counting, logging, file I/O, async, or syscalls.
- DSP kernels in C++ (`CEchoDSP`), called from AUAudioUnit render blocks (`EchoAudioUnits`), Swift↔C++ interop.
- UI ↔ DSP only through `AUParameterTree`; every parameter change ramps 20–50 ms.
- Effects are AUv3-shaped `AUAudioUnit` subclasses registered in-process and inserted in `AVAudioEngine`.

### 4.6 Concurrency

- Rendering/export/import/analysis run in actors off the main thread, report progress, support cancellation
  (`Task.checkCancellation()` between processing chunks).
- Long user-started exports use `BGContinuedProcessingTask` (iOS 26) with progress.

### 4.7 Errors

- Typed domain errors per service (`ImportError`, `RenderError`, `ExportError`, `RecordingError`, `StorageError`).
- UI shows actionable messages (what happened + what to do). Errors never apologize. Errors are recorded to
  `CrashReporting.record` without user content.

### 4.8 Device capability & entitlements

- Every AI button and every export path checks `EntitlementProvider.isUnlocked(_:)` and
  `DeviceCapabilityChecking.supports(_:)`. v1 implementations return true.

### 4.9 Dependencies (allowed)

- Apple frameworks only, plus:
  - **RNNoise** (BSD-3-Clause) vendored as C source in `CEchoDSP`; license text included.
  - **Firebase iOS SDK** via SPM: products `FirebaseAnalytics`, `FirebaseCrashlytics` only.
- No AudioKit, no Combine-based libs, no DI frameworks. Ask before adding anything.

---

## 5. Data model & storage

### 5.1 Locations

```
Documents/Projects/<projectUUID>/        # one folder per project
    project.json                         # Codable manifest (atomic writes)
    project.v<N>.backup.json             # written before any schema migration
    source.<ext>                         # imported original, NEVER modified (excluded from backup)
    working.caf                          # extracted working audio, 48 kHz float (excluded from backup)
    takes/                               # recordings: raw.caf, processed.caf, ch1.caf..chN.caf (excluded from backup)
    thumbnail.jpg
Library/Caches/Renders/<projectUUID>/<chainHash>.m4a   # ALAC renders (never backed up, safe to delete)
Library/Application Support/Presets/<presetUUID>.json  # user presets
```

- Mark `source.*`, `working.caf`, `takes/` with `isExcludedFromBackup = true`. Settings states projects are not in iCloud backup.
- Folders are named by UUID; renaming only changes `title`.

### 5.2 Models (EchoCore)

```swift
struct Project: Codable, Identifiable, Equatable {
    var schemaVersion: Int = Project.currentSchemaVersion   // 1 in v1
    let id: UUID
    var title: String
    var mediaType: MediaType                 // .audio | .video
    var origin: ProjectOrigin                // .imported | .recorded
    var sourceFileName: String               // "source.mov"
    var sourceInfo: SourceInfo               // duration, container, codecs, byteSize, channelCount, sampleRate
    var trimRange: TimeRangeCodable          // applied at playback/export only
    var clips: [Clip]                        // v1: exactly ONE clip covering the full source
    var outputLoudness: LoudnessTarget?      // Auto Level; nil = off
    var basePresetID: UUID?
    var recording: RecordingMetadata?        // for recorded projects: takes, channel names, markers
    var createdAt: Date
    var updatedAt: Date
}

struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    var sourceRange: TimeRangeCodable        // v1: full source
    var aiStack: [AIOperation]               // user-ordered
    var manual: ManualSettings               // live chain
}

struct AIOperation: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: AIFeature
    var strength: Float                      // 0...1, wet/dry
}

enum AIFeature: String, Codable, CaseIterable {
    case noiseSuppression, clearVoice, voiceLeveler
    case unknown                             // decode fallback for features from newer app versions
}

struct EditState: Codable, Equatable {       // what undo/redo snapshots
    var aiStack: [AIOperation]
    var manual: ManualSettings
    var trimRange: TimeRangeCodable
    var outputLoudness: LoudnessTarget?
}
```

`ManualSettings` (all with defaults that are "neutral"/off): `eq: [EQBand]` (6 bands), `inputGainDB`,
`gate`, `compressor`, `deEsser`, `limiter`, `reverb`, `pitchSemitones`. `LoudnessTarget`: `.youtube(-14)`,
`.instagram(-14)`, `.tiktok(-14)`, `.spotify(-14)`, `.podcast(-16)`, `.appleMusic(-16)`, `.custom(LUFS)`;
true-peak ceiling −1 dBTP.

### 5.3 Persistence rules

- In-memory `Project` is the source of truth while editing.
- **Autosave**: debounce 1 s after each change; flush immediately when scene phase leaves `.active` and when
  leaving the editor. Writes are `.atomic`. No Save button.
- **Lenient decoding**: every property added after v1 schema uses `decodeIfPresent ?? default`. Enums decode
  unknown raw values to `.unknown` (ops with `.unknown` are kept, skipped in processing, shown as
  "Needs a newer version").
- **Schema versioning**: `schemaVersion` in every `project.json` and preset. `ProjectMigrator` runs chained
  migrations `vN → vN+1` on raw JSON before decoding; writes `project.v<old>.backup.json` first, then writes
  back the migrated file immediately. Additive changes do not bump the version.
- **Newer schema than app**: open read-only, show "Update Echo Engine to edit this project", never save.

```swift
protocol ProjectMigration { var from: Int { get }; func migrate(_ json: inout [String: Any]) throws }
final class ProjectMigrator: ProjectMigrating {
    static let currentVersion = 1
    private let migrations: [ProjectMigration] = []          // none in v1
    func migrateIfNeeded(_ data: Data) throws -> (data: Data, didMigrate: Bool, fromVersion: Int)
}
```

### 5.4 Default titles

- Imported: source file name without extension.
- Recorded: localized "Recording, <date, time>" (e.g. "Recording, 28 Oct 2026, 15:42").

---

## 6. Audio pipeline

### 6.1 Two stages

```
source → [AI op 1] → [AI op 2] → … → (cached render file) → live manual chain → Auto Level gain → limiter → output
          └──────────── AI stage: offline, rendered, cached ──┘   └──── real-time, parameters only ──────┘
```

- Processing order is always: AI stack (user order) → manual chain → Auto Level → output limiter.
- The order the user performed edits only affects undo history, never processing order.
- Manual changes NEVER trigger renders.

### 6.2 Working format

- On import, extract/convert source audio to `working.caf`: 48 kHz, 32-bit float, original channel count
  (mono or stereo; downmix >2 channels to stereo for video sources).
- RNNoise runs per channel at 48 kHz mono, 480-sample frames.
- Renders stored as ALAC 24-bit at 48 kHz.

### 6.3 Render cache

- Key = SHA256 of `projectID + sourceRange + ordered [kind:strength]` for the prefix `ops[0...i]`.
- Every prefix of the current stack is a cached file (enables per-step A/B and partial re-render).
- `AIChainRenderer.render(source:chain:progress:)` walks prefixes, reusing hits, rendering misses on top of the
  previous prefix output.
- **Latest change wins**: any stack change cancels the in-flight render task. Processors check cancellation
  between chunks.
- While rendering, preview continues on the previous result; on completion swap input at the same playhead
  position with a 20 ms crossfade.
- AI renders always cover the full source; trim is applied at playback/export (trim never re-renders).

```swift
func firstChangedIndex(old: [AIOperation], new: [AIOperation]) -> Int {
    zip(old, new).firstIndex { $0.kind != $1.kind || $0.strength != $1.strength }
        ?? min(old.count, new.count)
}
```

### 6.4 Cache retention (RenderCacheJanitor)

- Keep only renders reachable from: every `EditState` in undo + redo history, and every prefix of the current stack.
- Run mark-and-sweep after every stack change and after history changes; delete everything else immediately.
- Budget: if reachable renders exceed min(2 GB, 10% of free space), evict oldest history states' renders first,
  never the current state's. Undoing to an evicted state re-renders.
- On project close: keep only the current state's prefix renders.
- "Clear render cache" (Settings) deletes all renders; regenerated on next open.

### 6.5 Undo/redo

- One `UndoManager` per editor session; registers full `EditState` snapshots (small).
- Linear history, max 30 steps. A new change after undo discards the redo branch (history only; janitor then
  deletes their renders).
- Sliders/knobs register undo on drag end, not per value change.
- Applying a preset = one undo step.

### 6.6 Preview playback (`AVPlaybackEngine`)

- Audio: `AVAudioEngine` → `AVAudioPlayerNode` (current render or `working.caf`) → manual chain AUs →
  Auto Level gain node → limiter → output.
- Video: `AVPlayer` muted with `AVPlayerLayer`; audio engine is slaved to the player's timeline (start both from
  a shared host time; resync on seek/play/pause; correct drift > 10 ms).
- "Hold for original": while held, route `working.caf` with manual chain bypassed; release restores.
- Per-step A/B: tapping a stack row plays the render of the prefix up to that row (manual chain still applied).
- Trim: playback range = `trimRange`.

### 6.7 Auto Level (final output stage)

- Not in the AI stack. Project-level `outputLoudness`.
- Analysis: EBU R128 integrated loudness of (AI render + manual chain) over `trimRange`, computed offline when
  the target, AI stack, manual settings, or trim change (debounced 500 ms; cheap, no model).
- Applies static gain to reach target, then true-peak limiter at −1 dBTP.
- Preview uses the last computed gain; export recomputes exactly.

---

## 7. AI features (v1)

All on-device. Strength = wet/dry blend unless noted. Each AI op renders the whole source.

| Feature | Implementation | Notes |
|---|---|---|
| Noise Suppression | RNNoise per channel | strength = wet/dry |
| Clear Voice | RNNoise → presence EQ (+2.5 dB @ 3 kHz shelf, −2 dB @ 250 Hz, HPF 80 Hz) → gentle compressor (3:1, −20 dB) | strength scales EQ/comp amount and wet/dry |
| Voice Leveler | DSP offline gain riding (below) | strength scales gain-curve depth |

- UI hint: if the stack contains both Noise Suppression and Clear Voice, show on Clear Voice: "Already reduces noise".
  Never block it.
- RNNoise: vendored C (BSD-3). Expose a C API from `CEchoDSP`; resample/convert with `AVAudioConverter` to
  48 kHz mono float frames of 480 samples.

### 7.1 Voice Leveler algorithm

```
windows   = RMS over 50 ms windows
speech    = window > noiseFloor * 2      (noiseFloor = 10th percentile of window RMS)
gainDB[i] = speech ? (targetDB(-20 dBFS) - level[i]) : 0     (clamp −12…+12 dB)
gain      = smooth(gainDB, lookahead 300 ms, release 500 ms) → apply → soft limiter −1 dBFS
```

Silences are never boosted.

### 7.2 Processor contract

```swift
protocol AIProcessing: Sendable {
    func process(_ op: AIOperation, input: URL, output: URL,
                 progress: @Sendable (Double) -> Void) async throws
}
```

`AIProcessorRouter` dispatches by `op.kind`; `.unknown` passes input through unchanged.

---

## 8. Manual controls (live chain)

Order inside the chain: input gain → gate → EQ → de-esser → compressor → pitch shift → reverb → limiter.

| Control | Parameters | Defaults |
|---|---|---|
| Gain | −24…+24 dB | 0 |
| Gate | threshold −80…0 dB, range, attack, release | off |
| Equalizer | 6 bands: low shelf, 4 peaking, high shelf; freq 20 Hz–20 kHz, gain ±18 dB, Q 0.3–8 | flat |
| De-esser | frequency 4–10 kHz, amount | off |
| Compressor | threshold, ratio 1–20, attack, release, makeup | off |
| Pitch shift | −12…+12 semitones, formant preserving | 0 |
| Reverb | room size, damping, mix | off |
| Limiter | ceiling −6…0 dB | −1 dB, always on |

- UI grouping (Editor "Adjust"): **Equalizer**, **Gain and dynamics** (gain, gate, compressor, de-esser, limiter),
  **Effects** (pitch shift, reverb), **Loudness** (Auto Level target).
- EQ screen: interactive curve (drag band handles), list of bands, reset. Graph is left-to-right in all locales.
- Speed change is NOT in v1 (breaks video sync).

---

## 9. Editor

One `EditorView` for both media types; only the header differs.

- **Top bar**: back (to Home), project title (tap to rename), Export button (accent).
- **Header**:
  - Video: `VideoPreview` (16:9, `AVPlayerLayer`).
  - Audio: `DetailWaveform` (≈200 pt): zoomable (pinch), follows playhead, shows original (grey) behind
    processed (accent) so the difference is visible.
- **Transport row**: "Hold for original" (press-and-hold A/B), Play/Pause (large), Undo, Redo.
- **Overview strip**: full-length waveform, processed part in accent, two trim handles (start/end only),
  regions outside trim dimmed, playhead, current time and "Trimmed to X of Y" label. Forced LTR.
- **Enhance section**: AI stack as an ordered list, numbered (order = processing order), each row: number,
  feature name, optional hint, strength value (tap → strength slider sheet), drag handle to reorder, swipe to remove.
  "Add enhancement" row opens a sheet listing AI features with one-line descriptions. Rendering progress shows
  inline on the row being rendered. Caption under header: "Applied top to bottom".
- **Adjust section**: rows Equalizer (mini curve), Gain and dynamics (gain value), Effects, Loudness (target name).
  Each opens a detail screen/sheet.
- **States**:
  - `ProjectReadiness.needsSpaceToEdit(bytes)`: editor blocked with message "Need <X> more to edit this project.
    Free up space on your iPhone, then come back. Your import is saved."
  - Read-only (newer schema): banner + all controls disabled.
- Applying a preset: from the Enhance header menu "Apply preset…"; replaces aiStack + manual + outputLoudness;
  one undo step; sets `basePresetID`; editor subtitle "Based on: <name>" / "Based on: <name> (modified)".
  Menu also: "Save as preset…", "Update preset" (only when based on a user preset).

---

## 10. Import

- Sources: Photos (`PhotosPicker`, videos and audio-capable assets), Files (`fileImporter`), Share Extension is Later.
- Supported: video MOV, MP4, M4V; audio M4A/AAC, MP3, WAV, AIFF, CAF, FLAC. Reject others (MKV, WebM, …) with a
  clear message. Video without an audio track: reject ("This video has no audio").
- No duration limit; storage check is the limit (§ 15).
- Steps: inspect → storage check (import stage) → copy to `source.<ext>` (same container/extension) →
  extract `working.caf` → thumbnail (video frame at 10% or waveform image for audio) → create `Project` with
  one full-range clip → open Editor (or show readiness state).
- Progress UI for copy/extract; cancellable; partial project folder deleted on cancel/failure.

---

## 11. Export

### 11.1 Sheet (single screen)

- **Export as** (video projects): Video · Audio only · Both. Audio projects: audio only (no picker shown).
- **Audio quality** presets: Standard (AAC 192 kbps) · High (AAC 320) · Lossless (FLAC 24-bit 48 kHz) · Custom.
  Custom: format AAC/WAV/FLAC/ALAC, sample rate 44.1/48 kHz, bit depth 16/24 (lossless/PCM), bitrate 128/192/256/320 (AAC).
  For video output, the audio track inside the video is AAC; quality preset picks its bitrate (default 256).
  Caption under the picker explains the choice, e.g. "AAC 320 kbps. The video is kept exactly as it is."
- **Save to**: Photos (video only) · Files · Share (share sheet).
- **After export**: Keep project (default) · Keep, clear cache ("Frees X") · Delete project ("Frees X").
- Storage line: "Needs about X. Y available." Primary button: "Export video" / "Export audio" / "Export".
- Remember last choices per media type (`AppSettingsStore`).

```swift
enum ExportOutput { case video(audioBitrate: Int), audioOnly(AudioExportSettings), both(audioBitrate: Int, AudioExportSettings) }
enum PostExportAction { case keepProject, keepProjectClearCache, deleteProject }
struct AudioExportSettings: Codable { var format: AudioFormat; var sampleRate: Double; var bitDepth: Int?; var bitrate: Int? }
```

### 11.2 Pipeline

1. Storage check (export stage).
2. Offline render (manual rendering mode of `AVAudioEngine`): current AI render → manual chain → Auto Level gain
   (recomputed) → limiter, over `trimRange` only, to a temp lossless file.
3. Encode to the chosen audio format (`AVAudioFile`/`AVAssetWriter`). MP3 export is not supported.
4. Video: `AVMutableComposition` with source video track `trimRange` + new audio track; `AVAssetExportSession`
   **passthrough**, same container as source (MOV→MOV, MP4→MP4). Preserve metadata (creation date, location,
   HDR). Trim at non-keyframes uses edit lists; flag in release testing.
5. Deliver: Photos via `PHAssetCreationRequest` with `shouldMoveFile = true`; Files via `fileExporter`; share via
   `ShareLink`/activity controller. Temp files deleted after delivery completes.
6. Post-export action runs ONLY after delivery is confirmed.
7. Runs under `BGContinuedProcessingTask` with progress; cancellable; failures leave the project untouched.

---

## 12. Presets

```swift
struct Preset: Codable, Identifiable, Equatable {
    var schemaVersion: Int = 1
    let id: UUID
    var name: String
    var aiStack: [AIOperation]
    var manual: ManualSettings
    var outputLoudness: LoudnessTarget?
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date                       // conflict resolution: newer wins
}
```

- Built-in (bundled JSON, read-only, localized names): **Podcast Voice** (NS 0.7 → Voice Leveler 1.0, podcast
  −16 LUFS), **Outdoor Video** (NS 0.9 → Clear Voice 0.8, YouTube −14), **Singing** (NS 0.4, gentle comp,
  reverb mix 0.15, no loudness). "Save as new preset" makes an editable copy.
- User presets: one file per preset in `Application Support/Presets/`. Preset does not include trim.
- Applying copies values into the project (not linked).
- Sync: `SyncedPresetRepository` decorates the file repo with `NSUbiquitousKeyValueStore` (key `preset.<uuid>`,
  value = JSON). Observe `didChangeExternallyNotification`; merge by `updatedAt`; deletes remove the key. Works
  locally when iCloud is unavailable. Only presets sync; projects never sync.
- Preset management: Settings → Presets (rename, delete user presets).

---

## 13. Record

Audio only. Microphone permission only.

### 13.1 Screen

- Title "Record"; input device button (top trailing) opens device + channel sheet.
- Settings rows: Noise reduction (Off/Standard/High), Auto-tune (Off or summary e.g. "A minor, natural"),
  Backing track (None or file name).
- Large timer (tabular digits), "Recording" indicator, per-channel level meters (named), background message,
  Pause and Stop/Record button, tab bar.
- Background message (shown while recording): "Recording continues if you leave the app. Calls or apps that use
  the microphone may pause it. Your audio so far is always saved."
- "Dim mode" button while recording: minimal dark screen with timer and meters.

### 13.2 Devices & channels

- Session: `.playAndRecord`, options `.allowBluetoothHFP`, `.allowBluetoothA2DP`, `.defaultToSpeaker`.
- List every `availableInputs` port. Hints: Bluetooth "Higher delay, not ideal with auto-tune or backing tracks".
- Step 2: select channels of the chosen device (multi-select, user-named, e.g. "Host", "Guest 1"), each with a
  live meter. Built-in mic: Mono / Stereo (via `dataSources` + stereo polar pattern where supported).
- iOS allows ONE input device at a time; multiple mics = multiple channels of one interface. Explain this in the
  sheet footer.
- Locked at record start: device, channels, sample rate (48 kHz), backing track and its start position.
- Adjustable during recording (ramped): suppression level, input gain, auto-tune settings, monitor volume.

### 13.3 Files

- Write continuously to CAF: `takes/raw.caf` (unprocessed mixdown), `takes/processed.caf` (with live processing),
  and per selected channel `takes/ch<N>.caf` raw. Mixdown is the v1 editing source (`working.caf` = processed or
  raw per user's choice at finish; default processed).
- Log parameter changes with timestamps in `RecordingMetadata` (future re-processing).
- Crash/kill recovery: on launch, detect unfinished takes (session marker file), offer "Recover recording".
- On Stop: create a recorded `Project`, open in Editor.

### 13.4 Live processing chain

input → input gain → suppression tier → gentle leveler (slow AGC, max ±6 dB) → auto-tune (if on) → clip limiter
(−1 dBFS, fast) → processed file + monitor (headphones).

| Tier | Implementation |
|---|---|
| Off | raw |
| Standard | `setVoiceProcessingEnabled(true)` on input node + noise gate |
| High | RNNoise live (per channel, 480-sample frames, ring buffer) |

Apple voice processing can force mono input or alter levels. If it is incompatible with the selected device or
channel count, Standard falls back to noise gate only for that session (tell the user in the row's caption);
report findings at the F11 checkpoint.

Show a "Use wired headphones for monitoring" tip when auto-tune or a backing track is on and output is not wired.

### 13.5 Auto-tune

- Loop per frame: YIN pitch detection (confidence > 0.8 else pass-through) → nearest allowed note in scale →
  smooth toward target by retune speed → PSOLA pitch shift with formant preservation.
- Controls: On/Off; Key (default **Chromatic**; else C…B); Scale (Major/Minor, only when a key is set);
  Style slider **Natural ↔ Robotic** (retune speed 100 ms → 0 ms). Advanced: Humanize (sustained-note looseness),
  Formant preservation (on).
- With a backing track loaded: run `KeyDetecting` (chroma-based, DSP) and offer "Song key: A minor. Use it?".
- Target added latency ≤ 20 ms; IO buffer ≈ 5 ms when auto-tune is on.

### 13.6 Backing track

- User imports an instrumental (Files; audio formats as § 10). Plays through headphones while recording;
  not mixed into the vocal take.
- Latency compensation: `offset = inputLatency + outputLatency + ioBufferDuration`; store in metadata; when
  creating the final mix, shift vocal earlier by `offset`.
- On Stop: offer "Save vocal only" or "Save vocal with backing track" (mix project). Vocal take always kept.

### 13.7 Background, interruptions, routes

- `UIBackgroundModes: audio`. Recording continues in background and on lock screen.
- `UIApplication.shared.isIdleTimerDisabled = true` while recording; reset on stop/pause/leaving tab.
- Live Activity (Lock Screen + Dynamic Island): timer, level, Stop button.
- Interruption `.began`: pause, flush to disk, add interruption marker. `.ended`: state `pausedByInterruption`,
  user taps Resume (never auto-resume) to continue the same take.
- Route change (selected device disconnected): same as interruption; never silently switch to built-in mic.

---

## 14. Home & Settings

### 14.1 Home

- Title "Projects", settings button (gear, top trailing), primary button "Import audio or video".
- 2-column grid (adaptive columns on iPad), sorted by `updatedAt` desc. Card: thumbnail (video frame or
  waveform; processed = accent bars, unprocessed = grey), type badge (video/mic icon), duration badge,
  title (1 line, truncated), subtitle (relative date, or readiness warning e.g. "Needs 0.2 GB to edit" in warning color).
- Card context menu: Rename, Delete (confirmation with size freed). No duplicate/folders in v1.
- Empty state: "Import a video or audio file, or record something new." with Import and Record actions.
- Tab bar (floating, native iOS 26 style): Projects, Record.

### 14.2 Settings

- Appearance: System (default) · Dark · Light → `preferredColorScheme`.
- Tint: Amber (default), Teal, Violet, Green, Rose, Blue → `.tint()` + accent tokens (§ 18). Caption
  "Used for buttons and processed audio."
- Presets: manage user presets.
- Privacy: "Share usage analytics", "Share crash reports" toggles; caption "Your audio never leaves your device."
- Storage: Projects total size, Render cache size + Clear; caption "Projects aren’t included in iCloud backup.
  Export anything you want to keep."
- Acknowledgements (RNNoise BSD-3, Firebase licenses), Version (marketing + build).

---

## 15. Storage management

Estimates (constants in `StorageEstimator`):
- Lossless render audio ≈ 100 KB/s (ALAC stereo 48 kHz); AAC 256 ≈ 32 KB/s; margin 200 MB (100 MB export).

| Stage | Check before | Bytes required |
|---|---|---|
| Import | copying | source size + working audio (duration × 384 KB/s float stereo) + margin |
| Edit | opening editor | one render (duration × 100 KB/s) × 2 + margin |
| Export | starting export | trimmed video size (size × trim ratio) + lossless render + encoded audio + 100 MB |

- Free space: `volumeAvailableCapacityForImportantUsage`.
- `ProjectReadiness`: `.ready`, `.needsSpaceToEdit(bytes)`, `.needsSpaceToExport(bytes)`; shown on Home cards and in Editor.
- Messages always state exact numbers: "This project needs about 2.4 GB. You have 1.1 GB free."
- Per-project size (source, renders, takes) on the project info sheet.

---

## 16. Analytics & crash reporting

- Firebase Analytics + Crashlytics behind `AnalyticsTracking` / `CrashReporting`. Nothing else imports Firebase.
- Consent screen on first launch (before any collection): two toggles (analytics, crash reports), both explained in one line each, "Continue". Changeable in Settings.
  - Analytics: `Analytics.setConsent` with `analyticsStorage` per consent; `adStorage`, `adUserData`,
    `adPersonalization` always `.denied`. `setAnalyticsCollectionEnabled(consent)`.
  - Crashlytics: `setCrashlyticsCollectionEnabled(consent)`.
- No IDFA: do not link `AdSupport`; no ATT prompt. Info.plist: `GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS = false`.
- Build phase uploads dSYMs. `GoogleService-Info.plist` provided by the user (ask in F14).
- NEVER send user content: titles, file names, paths, transcripts, audio. Durations as buckets
  (`<1m`, `1-10m`, `10-60m`, `>60m`).

```swift
enum AnalyticsEvent {
    case onboardingCompleted(analytics: Bool, crash: Bool)
    case importStarted(mediaType: MediaType)
    case importCompleted(mediaType: MediaType, durationBucket: DurationBucket)
    case importFailed(reason: ImportFailureReason)
    case aiFeatureApplied(AIFeature, stackPosition: Int)
    case aiFeatureRemoved(AIFeature)
    case undoUsed, redoUsed, originalComparedHeld
    case manualControlOpened(ManualGroup)
    case loudnessTargetSet(LoudnessTargetKind)
    case presetApplied(isBuiltIn: Bool), presetSaved
    case exportStarted(output: ExportKind, format: AudioFormat?)
    case exportCompleted(output: ExportKind, format: AudioFormat?, destination: DestinationKind, postAction: PostExportAction)
    case exportFailed(reason: ExportFailureReason)
    case recordingStarted(inputType: InputType, channels: Int, suppression: SuppressionLevel, autoTune: Bool, backingTrack: Bool)
    case recordingFinished(durationBucket: DurationBucket, interrupted: Bool)
    case storageBlocked(stage: StorageStage)
}
```

- Crash context keys: `screen`, `ai_stack` (kinds only), `recording_state`, `input_type`, `media_type`,
  `duration_bucket`, `source_container`.
- Privacy manifest (`PrivacyInfo.xcprivacy`) for the app; Firebase ships its own. App Store privacy label
  (user fills in App Store Connect): Diagnostics → Crash Data; Usage Data → Product Interaction; Identifiers
  as Firebase requires; all "not used for tracking".

---

## 17. Localization & accessibility

- Languages: English (base), Spanish, French, German, Italian, Portuguese, Dutch, Polish, Arabic, Turkish, Russian.
- String Catalog (`Localizable.xcstrings`); `String(localized:)`/SwiftUI literal keys; plural variations
  (Russian/Polish/Arabic plural rules) via the catalog; never concatenate strings.
- Formatters for numbers, sizes (`.byteCount(style: .file)`), durations, dates.
- RTL (Arabic): SwiftUI mirroring; use leading/trailing only; directional custom images "Mirror for RTL".
  Force `.environment(\.layoutDirection, .leftToRight)` on: waveforms, trim strip, playhead/scrubbing, level
  meters, EQ graph, transport icons.
- Translations: machine-translated drafts are acceptable during development; mark the catalog for native
  review before release (TASKS F15).
- Accessibility: Dynamic Type for all text (layouts must not clip at XXL); VoiceOver labels for every icon-only
  button; meters and waveforms expose values (`accessibilityValue`); touch targets ≥ 44 pt; contrast ≥ 4.5:1
  for text; Reduce Motion respected.

---

## 18. Design system & screens

Approved mockups: Design canvas "Echo Engine" (screens: Home, Editor video, Editor audio, Record, Export,
Settings, Home light, Editor light). This section is the authoritative translation of that canvas.

### 18.1 Principles

- Professional, minimal, calm. One primary action per screen; details one tap away (progressive disclosure).
- Dark-first, light fully supported. **Accent = processed audio**: processed waveforms and active states use
  the tint; untouched audio is grey. Red only for recording and clipping.
- Native iOS 26 components (tab bar, navigation, sheets, menus) to inherit Liquid Glass. No gradient washes,
  no emoji, no decorative shadows. Flat surfaces on a ground color.

### 18.2 Color tokens (asset catalog, `Color("Name")`)

| Token | Dark | Light | Use |
|---|---|---|---|
| `Ground` | #161B22 | #F3F5F8 | screen background |
| `Surface` | #1F2630 | #FFFFFF | grouped rows, cards, waveform wells |
| `SurfaceSunken` | #11161D | #E9EDF2 | segmented control track |
| `SurfaceRaised` | #323B48 | #FFFFFF | selected segment |
| `Separator` | #29313D | #E6EAF0 | row dividers |
| `Stroke` | #333C49 | #C6CDD6 | outlined buttons |
| `TextPrimary` | #ECEFF3 | #141A22 | |
| `TextSecondary` | #A3ADBA | #5B6573 | captions, values |
| `TextTertiary` | #8591A0 | #66717E | placeholders (light was #6B7684: 4.23:1 on Ground) |
| `IconMuted` | #6B7684 | #8A94A1 | chevrons, disabled |
| `WaveformIdle` | #4A5563 | #BCC4CF | unprocessed audio |
| `WaveformOriginal` | #3A4452 | #D3D9E1 | original behind processed (detail waveform) |
| `Playhead` | #FFFFFF | #141A22 | |
| `Record` | #EF5A4F | #D93A2F | record button, recording dot |
| `Clip` | #EF5A4F | #D93A2F | meter clip segments |
| `Warning` | #F3A39C | #B4342A | storage warnings |
| `Success` | #4CAF6E | #2F8F50 | toggles on |
| `Dim` | rgba(14,18,24,.62) | rgba(243,245,248,.72) | outside-trim overlay |

Tints (each: `Tint/<name>` fill, `Tint/<name>-text` for text/icons on Ground, `Tint/<name>-wave` for processed
waveform, `Tint/<name>-on` for text on a filled tint button):

| Tint | Fill (both) | Text dark / light | Wave dark / light | On |
|---|---|---|---|---|
| Amber (default) | #F0B24A | #F0B24A / #8A5A00 | #F0B24A / #D48A12 | #1E1505 |
| Teal | #5CC8D8 | #5CC8D8 / #0F6E7A | #5CC8D8 / #1E97A8 | #062226 |
| Violet | #9B8CFF | #9B8CFF / #5A47D6 | #9B8CFF / #7563F0 | #140F33 |
| Green | #7FD18B | #7FD18B / #2E7D3A | #7FD18B / #3E9E4C | #0B2410 |
| Rose | #F28BA8 | #F28BA8 / #B3315A | #F28BA8 / #D9567E | #33101B |
| Blue | #6FA8FF | #6FA8FF / #2457C5 | #6FA8FF / #3D74E0 | #0A1A36 |

Verify every text pairing ≥ 4.5:1 in a unit test (`ContrastTests`); adjust light values if a check fails and log it.

```swift
enum AppTint: String, CaseIterable, Codable { case amber, teal, violet, green, rose, blue }
extension AppTint {
    var fill: Color { Color("Tint/\(rawValue)") }
    var text: Color { Color("Tint/\(rawValue)-text") }
    var wave: Color { Color("Tint/\(rawValue)-wave") }
    var on:   Color { Color("Tint/\(rawValue)-on") }
}
enum Appearance: String, CaseIterable { case system, dark, light }
```

### 18.3 Typography

- System font (SF Pro) via Dynamic Type styles. Numbers that change (timers, durations, dB, %) use
  `.monospacedDigit()`.
- Mapping: screen titles `.largeTitle.bold()` (34); editor/settings nav title `.headline`; section titles
  `.title3.bold()` (20); row titles `.body.weight(.semibold)` (16–17); values/captions `.subheadline`/`.footnote`
  in `TextSecondary`; record timer 68 pt light monospaced.
- Sentence case everywhere. No all-caps labels.

### 18.4 Spacing, shape, controls

- 4-pt grid. Screen horizontal padding 20. Section gap 18–22. Row min height 52–60, horizontal padding 14.
- Radii: grouped containers 14; cards/thumbnails 14; waveform wells 12; primary buttons 16; pills/capsules
  fully rounded; segmented track 12 / segment 9; phone artboard corners irrelevant (device).
- Primary button: height 54, Tint fill, `Tint-on` text, semibold 17.
- Secondary: outlined `Stroke`, or `Surface` fill circle for icon buttons (44 pt).
- Grouped lists: `Surface` container, rows separated by `Separator`, chevron in `IconMuted`.

### 18.5 Screens (match canvas)

- **Home** (§ 14.1): title + gear, Import button, project grid, floating tab bar.
- **Editor video / audio** (§ 9): top bar, header (video preview or detail waveform), transport row, overview
  strip with trim, Enhance list (numbered, hint, strength, drag handle, Add enhancement), Adjust list.
- **Record** (§ 13.1): title + input device pill, settings rows, recording indicator + timer, named meters
  (30 segments; tint, last 4 segments `Clip`), background message card, Pause + Stop (80 pt ring, `Record` square), tab bar.
- **Export** (§ 11.1): sheet with grabber, title + close, "Export as" segmented, "Audio quality" segmented + caption,
  "Save to" three tiles (selected = tint border), "After export" radio list with freed sizes, storage line, primary button.
- **Settings** (§ 14.2): back + title, Appearance segmented, Tint swatch row (selected ring), Privacy toggles + caption,
  Storage rows + Clear + caption, Acknowledgements, Version.
- **Onboarding/consent** (not on canvas): one screen, app name, one-line value ("Clean, clear audio for your
  videos and recordings. Everything stays on your device."), two consent toggles, Continue. Same tokens.
- Detail screens not on canvas (EQ, Gain and dynamics, Effects, Loudness, strength slider, Add enhancement,
  device/channel picker, auto-tune, backing track, presets): follow § 18.1–18.4; grouped rows, segmented controls,
  sliders with value labels; present as sheets with detents where short. If layout is unclear, ask the user.

---

## 19. Testing

- Swift Testing for EchoCore logic: models (coding, lenient decoding, unknown enums), migrator, cache keys,
  `firstChangedIndex`, janitor reachability, undo history, storage estimator, preset merge, loudness math,
  Voice Leveler gain curve, key detection, pitch detection on synthetic tones.
- Golden-file DSP tests: `Packages/EchoCore/Tests/EchoCoreTests/Resources/TestAudio/` (SPM test resources; fan, street, café, quiet room, sung scale, 2-speaker podcast;
  ≤ 10 s each, generated or CC0). Compare output vs reference within tolerance (RMS diff < −50 dB) so DSP changes
  cannot silently degrade.
- Real-time safety: debug-only render-thread allocation guard in DSP tests.
- UI: SwiftUI previews for every screen in dark + light + Arabic (RTL) + XXL Dynamic Type using fakes.
- Every task: build succeeds, tests pass (CLAUDE.md).

---

## 20. Decision log

Record new user decisions here (date, decision, section updated).

- 2026-10-28: Initial spec agreed with the user (all sections above).
- 2026-10-28: Bundle ID `akumatech.Echo-Engine`; display name "Echo Engine"; team ID left unset until device
  testing; Xcode template project replaced by XcodeGen layout in F01.T02 (§ 3).
- 2026-10-28: Shared fakes live in a new `EchoCoreFakes` package target (§ 4.1, § 4.2). App resources live in
  `App-iOS/Resources/` per § 4.2; golden test audio lives in the package test target (§ 4.2, § 19); CLAUDE.md
  repo layout updated to match.
- 2026-10-28: Per the § 18.2 contrast rule, `TextTertiary` light changed #6B7684 → #66717E (4.23 → 4.55:1 on
  Ground; same hue, still lighter than `TextSecondary`). All other text pairings pass as specified (§ 18.2).
