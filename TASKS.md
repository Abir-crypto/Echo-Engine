# TASKS.md — Echo Engine v1

Status markers: features `[TODO]` / `[IN PROGRESS]` / `[DONE]`; tasks `[ ]` / `[x]`.
After each task: check it, add a `> Done:` note under it (what + how), commit `<TaskID>: <summary>`.
After each feature: checkpoint (see CLAUDE.md), push, STOP.
Section references (§) point to SPEC.md.

---

## F01 — Project foundation  [DONE]
Goal: buildable empty app with module structure, DI root, tokens, localization and tab shell.

- [x] F01.T01 — Ask user for bundle ID, Apple team ID, display name confirmation. Record in § 3 and § 20.
  > Done: Bundle ID `akumatech.Echo-Engine`, display name "Echo Engine", team ID unset (no `DEVELOPMENT_TEAM`
  > in project.yml; ask before device testing). Recorded in SPEC § 3 + § 20. F01.T02 must also delete the Xcode
  > template (`Echo Engine/`, `Echo Engine.xcodeproj`, tracked `xcuserdata`). Toolchain: Xcode 27.1; if
  > `xcode-select -p` shows CommandLineTools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- [x] F01.T02 — `.gitignore` (Xcode, SPM `.build`, DerivedData, `.DS_Store`, `xcuserdata`, render caches); `project.yml` (XcodeGen) with App-iOS target (iOS 26, iPhone + iPad), test target; generate project.
  > Done: Deleted Xcode template. `project.yml`: target/scheme `EchoEngine` (sources `App-iOS/`, Swift 6, generated
  > Info.plist, iPhone portrait / iPad all orientations) + hosted Swift Testing target `EchoEngineTests` (`App-iOSTests/`).
  > Generated `EchoEngine.xcodeproj` is gitignored — run `xcodegen generate` after pulling or editing project.yml.
  > iPhone 17 exists on iOS 26.5 and 27.0: use destination `...,name=iPhone 17,OS=26.5`.
- [x] F01.T03 — `Packages/EchoCore` SPM package with targets `EchoCore`, `CEchoDSP` (C/C++), `EchoAudioUnits`, `EchoCoreTests`; Swift↔C++ interop enabled; trivial C++ function called from a Swift test.
  > Done: Package (tools 6.2, iOS 26 + macOS 26, C++20). `CEchoDSP` exposes headers via umbrella `include/CEchoDSP.h`
  > (custom modulemap dropped in F01.T04); first kernel helper `echo::dsp::dbToLinear`, tested via `swift test`. Swift targets use
  > `.interoperabilityMode(.Cxx)`, which is viral: project.yml sets `SWIFT_OBJC_INTEROP_MODE: objcxx` project-wide
  > (verified — app import fails without it). App target links products `EchoCore` + `EchoAudioUnits`.
- [x] F01.T04 — `AppContainer` composition root skeleton + environment injection; fakes folder; `FreeV1Entitlements`, `DefaultCapabilities` (§ 4.3–4.8).
  > Done: EchoCore `Entitlements/`: `GatedFeature` (3 AI features + exportVideo/exportAudio; add cases as gated features
  > land), protocols + always-true v1 impls. New `EchoCoreFakes` target (user decision, SPEC § 4.2/§ 20). `AppContainer`
  > is `@MainActor @Observable`, init params default to live types (tests/previews inject fakes); app does `.environment(container)`.
  > Xcode now builds EchoCore as a dynamic framework (app + tests link it). Custom CEchoDSP modulemap caused a
  > DEFINES_MODULE warning → replaced by umbrella header. After package graph changes, stale DerivedData can give bogus errors.
- [x] F01.T05 — Asset catalog with all color tokens and six tints, light/dark variants (§ 18.2); `AppTint`, `Appearance`; `ContrastTests`.
  > Done: `App-iOS/Resources/Assets.xcassets` (18 tokens + `Tint/` namespace, 6 tints × fill/text/wave/on). `App-iOS/DesignSystem/`:
  > `ColorToken` enum + `ShapeStyle` statics (`.foregroundStyle(.textPrimary)`), `AppTint` (`assetName(_:)`, fill/text/wave/on), `Appearance`.
  > `ContrastTests` checks 28 pairings × light/dark ≥ 4.5:1 (mutation-verified). TextTertiary light → #66717E (SPEC § 20).
  > AppIcon name blanked in project.yml until F16.T01 (actool errors on a missing set).
- [x] F01.T06 — String Catalog with 11 languages enabled (English content only for now); localization conventions helper; RTL pseudolanguage scheme option (§ 17).
  > Done: `Localizable.xcstrings` (en source) + `InfoPlist.xcstrings` (`CFBundleDisplayName` "Echo Engine" in all 11 locales —
  > this is what makes XcodeGen emit `knownRegions`; empty entries would compile to "" so never add them). es + pt-BR per user
  > (SPEC § 17/§ 20). `DisplayFormat` (`fileSize`, `duration`) carries the conventions doc; tests pin en/de output. Scheme
  > `EchoEngine-RTL` launches with RTL pseudolanguage args. Missing en.lproj is fine: iOS counts the dev region as available.
- [x] F01.T07 — App shell: floating tab bar (Projects, Record), placeholder screens, appearance + tint applied at root, Info.plist keys (microphone usage, photo add usage, background audio).
  > Done: `RootView` = native `TabView` (mockups draw a custom capsule bar; SPEC § 18.1 native wins), `.tint(tint.text)` (= mockups' accentText),
  > appearance/tint via `@AppStorage(AppSettingsKey…)`; placeholder Home/Record; `#if DEBUG DebugAppearanceMenu`. Usage strings in InfoPlist
  > catalog; `UIBackgroundModes` via XcodeGen `info:` (generated `App-iOS/Info.plist`, gitignored). Simulator-verified iPhone light/dark/RTL + iPad.
  > `xcodebuild test` on a still-booting sim fails "Busy/preflight": run `simctl bootstatus <id> -b` first.

**Checkpoint test:** app launches on iPhone and iPad simulators; tabs switch; Dark/Light/System and tint changes apply (temporary debug toggle OK); Arabic RTL pseudolanguage mirrors layout.

---

## F02 — Projects & storage model  [DONE]
Goal: persistent projects with schema versioning and the Home screen.

- [x] F02.T01 — Models: `Project`, `Clip`, `AIOperation`, `AIFeature` (+`.unknown`), `ManualSettings`, `LoudnessTarget`, `EditState`, `SourceInfo`, `RecordingMetadata`, `TimeRangeCodable` with lenient decoding (§ 5.2–5.3). Tests.
  > Done: `EchoCore/Models/`; `UnknownCaseDecodable` gives every persisted enum a `.unknown` fallback, and `.unknown` AI ops re-encode their
  > original kind so saves don't destroy them. `LoudnessTarget` encodes `{kind, lufs}`; unknown kind → `.custom(lufs)`. `ManualSettings` nests
  > Gate/DeEsser/Compressor/Reverb/Limiter with § 8 ranges as statics; default params (EQ band freqs, gate/comp/de-esser/reverb) are provisional —
  > confirm by ear in F05. `RecordingMetadata` = channel names, editing take, markers; F10–F12 add fields leniently. Times in seconds (Double).
- [x] F02.T02 — `ProjectMigrator` (chain runner, backup file, didMigrate), newer-schema read-only detection. Tests with fake migrations.
  > Done: `EchoCore/Projects/`: `ProjectMigrating` (+ `ProjectMigration` step protocol, `ProjectMigrationError`), `ProjectMigrator` (pure
  > JSON chain; runner sets `schemaVersion` per step; missing version = 1; register steps in `registeredMigrations`). `migrateFileIfNeeded(at:)`
  > writes `project.v<N>.backup.json` then the migrated file (atomic); `isReadOnly(schemaVersion:)` for newer schemas. `FakeProjectMigrator`.
  > Also recorded user decisions (SPEC § 4.2 folders, § 18.4 tint roles). Xcode misses new package files incrementally → clean DerivedData.
- [x] F02.T03 — `FileProjectRepository`: folder layout, atomic writes, list sorted by `updatedAt`, rename, delete, backup exclusion flags (§ 5.1). Tests.
  > Done: `ProjectRepository` (async) → `StoredProject {project, isReadOnly}`; `FileProjectRepository` actor (`root`, migrator, clock; own
  > `FileManager()` instance). `list()` skips folders without a readable manifest; `load` migrates in place; save/rename refuse read-only.
  > `createFolder(for:)` excludes the whole folder from backup (user decision, § 5.1); importers must call it first. `ProjectFolder` = § 5.1 layout, `URL.projectsDirectory`,
  > `DateProviding`/`SystemClock`; fakes `FakeProjectRepository`, `FakeClock`. Delete doesn't touch renders yet (render cache is F06).
- [x] F02.T04 — Autosave helper (1 s debounce + flush on scene phase change) (§ 5.3).
  > Done: `ProjectAutosaving` + `ProjectAutosaver` actor (restartable 1 s debounce via injected `Clock`, latest wins, stamps `updatedAt`
  > at schedule time, chained saves so `flush()` returns only once everything is on disk, failures → `onError`). App modifier
  > `.flushesAutosave(_:)` flushes on scene phase ≠ active and on disappear (Editor wires it in F04). Fakes: `ManualClock` (test clock,
  > `advance(by:)`), `FakeProjectAutosaver`; `FakeProjectRepository.saveCount`. Autosaver tests passed 20/20 repeated runs.
- [x] F02.T05 — Home screen UI per canvas: title, gear, Import button (non-functional yet), grid cards with thumbnail/waveform placeholder, badges, empty state, rename/delete context menu (§ 14.1, § 18.5). Previews dark/light/RTL.
  > Done: `HomeView`/`HomeModel`/`ProjectCard` (native `.inlineLarge` title + grey gear → placeholder `SettingsView`; adaptive grid; context menu
  > Rename/Delete with `diskUsage` "frees X"; empty state with Import + Record → tab switch). New tokens `TextValue`/`BadgeFill`, `PrimaryButtonStyle`/
  > `SecondaryButtonStyle`, `\.appTint` env, `DisplayFormat.projectDate`. Debug: `DebugMenu` (Settings) + `-seedSampleProjects YES`. App links `EchoCoreFakes`;
  > test target links NO EchoCore products (a second copy duplicated types and broke `catch`). Mockup diff: native tab bar/nav glass (§ 18.1).

**Checkpoint test:** seed debug projects; they persist across launches; rename and delete work; empty state shows when none.

---

## F03 — Import & storage checks  [DONE]
Goal: import audio/video into a project with exact storage messaging.

- [x] F03.T01 — `MediaInspector`: duration, tracks, container, codecs, size; supported-format validation; no-audio rejection (§ 10).
  > Done: `EchoCore/Import/`: `MediaInspecting` → `MediaInspection {mediaType, sourceInfo, fileExtension}`; typed `ImportError`
  > (`.unsupportedFormat`/`.noAudio`/`.unreadable`). `AVMediaInspector`: extension → UTType checked against the § 10 list (DRM-protected
  > video excluded), then AVURLAsset duration/tracks/format (FourCC codecs, channels, rate, file size); video = has a video track.
  > Tests generate real WAV/M4A/CAF/AIFF/MOV files (`Tests/EchoCoreTests/Support/TestMedia.swift`). `FakeMediaInspector`.
- [x] F03.T02 — `StorageEstimator` + `ProjectReadiness` (§ 15). Tests with fixed numbers.
  > Done: `EchoCore/Storage/`: `StorageEstimating` + `StorageEstimator` (§ 15 constants; KB = 1,000 bytes; export assumes the default
  > output: video kept + AAC 256), `availableBytes()` = `volumeAvailableCapacityForImportantUsage`. `ProjectReadiness` carries the
  > shortfall in bytes; `readiness(of:availableBytes:)` checks edit before export. `FakeStorageEstimator`. Exact-number tests.
- [x] F03.T03 — `AVMediaImporter`: copy to `source.<ext>`, extract `working.caf` (48 kHz float, channel rules § 6.2), thumbnail, cancellation + cleanup.
  > Done: `MediaImporting` → `ImportedMedia {sourceFileName, workingChannelCount, overview}`. `AVMediaImporter`: 4 MB chunked copy (security-scoped
  > access, cancellation per chunk), `AVAssetReaderAudioMixOutput` → interleaved float CAF at 48 kHz, mono stays mono, >2 ch → stereo (user
  > decision); 48-bucket peak overview → `waveform-overview.json` (user decision: drawn live, not an image); video → `thumbnail.jpg` at 10%.
  > Any error/cancel removes the files it wrote; the caller (F03.T04) deletes the folder. Progress: copy 0–0.5, extract 0.5–1. `FakeMediaImporter`.
- [x] F03.T04 — Import UI: PhotosPicker + fileImporter, progress, errors, storage-blocked message, open created project.
  > Done: Import button = menu (Photos: `PhotosPicker` videos, `.current` encoding → `PickedMovie` temp copy; Files: `fileImporter` movie/audio).
  > `ImportModel` (protocols only): inspect → storage check (exact-number message) → `createFolder` → import → save (title = file name, § 5.4);
  > failure/cancel deletes the folder, Photos temp copy always deleted. One `ImportProgressView` sheet shows progress, then the failure
  > (an alert during sheet dismissal was dropped). Home uses a `HomeRoute` path: new project and card taps open placeholder `EditorView` (F04).
  > Debug: `-debugImportPath <file>`. Integration test runs the real stack on iOS.
- [x] F03.T05 — Home cards show real thumbnails, durations, readiness warnings.
  > Done: `ProjectRepository.waveformOverview(id:)`/`thumbnail(id:)`; `HomeModel` loads them per card (`.task(id:)`, cached as `ProjectThumbnail`
  > `.frame`/`.levels`) and computes `readiness` from free space on each load. Video cards show the frame; audio cards draw `WaveformBars`
  > (Components; 48 levels → 24 peak bars scaled to the loudest, tinted when processed); no files → seeded placeholder bars. Cards show
  > "Needs X to edit/export" in Warning instead of the date. Verified with a real MOV and AIFF in the simulator.

**Checkpoint test:** import a 4K iPhone video, an MP3 and a WAV; check the folder contents; fill simulator storage (or fake estimator) to see the blocked message with exact numbers.

---

## F04 — Editor shell & playback  [DONE]
Goal: play projects with video sync, waveforms, trim.

- [x] F04.T01 — Waveform data generation (downsampled peaks cache per project) in EchoCore. Tests.
  > Done: `EchoCore/Waveform/`: `WaveformPeaks` (max |sample| over all channels per 256 frames + halving pyramid; `levels(from:to:count:)`
  > reads the coarsest level ≥ 1 bucket per value, rounding outward so peaks are never missed). `WaveformProviding` → `CachedWaveformProvider`
  > actor: vDSP generator (cancellable, progress), cache `URL.waveformCacheDirectory/<project>/<key>.peaks` (binary "EEWP" v1), reused while
  > the source frame count matches; `removeAll(projectID:)` (wire into project delete + Settings Clear cache, F13). `FakeWaveformProvider`.
- [x] F04.T02 — `AVPlaybackEngine` audio path (player node → placeholder chain → output), play/pause/seek, trim range playback.
  > Done: `EchoCore/Playback/`: `@MainActor PlaybackEngine` (Observable) → `AVPlaybackEngine`: player → `chainInput` mixer (insertion point for
  > F05/F07) → main mixer; trim via `scheduleSegment`, seek reschedules, generation counter drops stale completions; end of range stops with
  > the playhead at the end, next play restarts at the range start. Completion uses `.dataRendered` (`.dataPlayedBack` never fires offline).
  > Tests render offline (`init(manualRenderingFormat:)`, ≤ 4,096 frames/call) on a frame-index ramp; 10/10 repeated runs. Audio session: F04.T04.
- [x] F04.T03 — Video sync: muted `AVPlayer` + `AVPlayerLayer`, shared host-time start, drift correction (§ 6.6).
  > Done: `load(audio:video:)` adds a muted `AVPlayer` (`automaticallyWaitsToMinimizeStalling = false`, `forwardPlaybackEndTime` = trim end).
  > Play: player node `play(at:)` host time − output latency, video `setRate(_:time:atHostTime:)` at the same host time (+100 ms lead).
  > Every 0.5 s audible audio vs video; > 10 ms → audio rescheduled onto the video timeline (`VideoSync`, pure, tested). Pause/seek move both.
  > App `Components/VideoPreview` (AVPlayerLayer-backed view). Real-time sync only checkable by hand (checkpoint: 5+ min on device).
- [x] F04.T04 — Editor layout per canvas: top bar (rename on title tap), header switch (VideoPreview / DetailWaveform with pinch zoom), transport row, overview strip with trim handles, forced LTR (§ 9).
  > Done: `EditorScreen` (makes `EditorModel` once) → `EditorView`: native back (swipe works; TextValue tint), principal title → rename alert, Export
  > (disabled until F08), no tab bar; `VideoPreview` in `VideoWell` tokens (user) or `DetailWaveform` (Canvas, playhead-centred, pinch zoom ≥ 2 s,
  > drag scrub); `TransportRow` (Undo/Redo disabled until T05, hold-original state only → F05/F06); `OverviewStrip` (trim ≥ 1 s per user, 44 pt
  > handle targets, VoiceOver adjustables). Readiness block + read-only banner. Rename/trim already autosave; `AudioDeviceManaging` + `IOSAudioDeviceManager`.
- [x] F04.T05 — `UndoManager` with `EditState` snapshots, 30-step cap, drag-end registration (§ 6.5); trim changes undoable; autosave wired.
  > Done: own `EchoCore/Editing/EditHistory` (user decision, SPEC § 6.5/§ 20: Foundation `UndoManager` can't list states for the janitor):
  > undo/redo stacks, cap 30, new change clears redo, `allStates` = timeline minus current. `Project.editState` get/set (clip 0). `EditorModel`
  > commits on drag end (no step if unchanged), `undo()`/`redo()` restore project + playback range and autosave; ⌘Z / ⇧⌘Z. Title isn't undoable
  > (not in `EditState`). Autosave: every edit schedules, scene phase/disappear/close flush.

**Checkpoint test:** open video and audio projects; play, seek, scrub; trim start/end and hear only the trimmed range; video and audio stay in sync over 5+ minutes; undo/redo trim.

---

## F05 — Manual effects chain  [DONE]
Goal: real-time manual controls as C++ DSP in Audio Units.

- [x] F05.T01 — `CEchoDSP` kernels: gain, biquad EQ (6 bands), gate, compressor, de-esser, limiter. Golden-file tests + render-thread allocation guard.
  > Done: `echo::dsp` C++ kernels (`prepare`/setters/`process(float* const*, ch, frames)`, ≤ 2 ch, fixed-size state, `noexcept`): params ramp
  > 30 ms via `SmoothedValue`, enable/disable is a ramped mix; EQ = RBJ biquads, log-freq glide, coeffs per 32 frames, `magnitudeDB` for the curve;
  > de-esser = band-pass detector (−30 dBFS) driving a dynamic high shelf (≤ 12 dB × amount); limiter = 1.5 ms look-ahead, ramped gain, 50 ms
  > release, `latencyFrames()` (72 @ 48 kHz) for F05.T03. Kernels clamp compressor threshold −60…0 / makeup 0…24 (not in the model yet). Tests:
  > analytic per kernel, golden files `Resources/TestAudio/Golden/*.f32` (re-record: `ECHO_UPDATE_GOLDEN=1 swift test`), zero `operator new` via
  > test-only `CEchoDSPTestSupport` (thread-local counter, proven to catch a kernel allocation).
- [x] F05.T02 — Kernels: reverb, formant-preserving pitch shift (PSOLA; shared with auto-tune later). Tests.
  > Done: `PitchDetector` (YIN on a ~12 kHz decimated copy, 70–1000 Hz, unvoiced below 0.8 confidence per § 13.5; `push`/`detect`).
  > `PitchShiftKernel` = TD-PSOLA: pulse-aligned analysis marks, 2-period Hann grains spaced period/ratio, energy-preserving gain;
  > constant latency 2.5 × 70 Hz period (1,715 frames @ 48 kHz) even at 0 st (then exactly the delayed input) — F05.T03 must report and
  > compensate it. `ReverbKernel` = Freeverb (8 combs + 4 allpasses, skips work and clears its tail while off). Buffers allocate in
  > `prepare` (off the render thread); scenarios guard only the render loop. Golden tolerance now SPEC § 19's −50 dB (relative).
- [x] F05.T03 — `EchoAudioUnits`: AUAudioUnit subclasses + `AUParameterTree` with ramping; chain assembly in `AVPlaybackEngine` in § 8 order.
  > Done: `ManualChainAudioUnit` (gain → gate → EQ → de-esser → compressor → pitch → reverb) and `OutputLimiterAudioUnit` (last, per § 6.6/6.7;
  > F07 inserts the Auto Level gain between them), base `EchoEffectAudioUnit`, registered in-process (`EchoAudioUnits.register()`). Real-time side is
  > `CEchoDSP/AudioUnitEffect.mm`: ObjC++ render block capturing a raw pointer, lock-free atomic parameter mailbox, render-thread reset flag.
  > Engine: player → chain → limiter; `apply(ManualSettings)` sets tree values (`manualChainParameterValues`); latency 1,787 frames @ 48 kHz is
  > compensated (playhead = what left the chain, video start/resync, silence flush at range end); seek/stop clears the chain. Flat EQ bands and an
  > idle de-esser shelf are skipped so neutral settings are bit-exact (FMA contraction broke exact identity biquads). Editor applies settings on open/undo.
- [x] F05.T03a — Playback resilience: on `AVAudioEngineConfigurationChange` (route change, e.g. headphones unplugged) and session
  interruptions (calls), pause cleanly (keep the playhead, `isPlaying` false, video paused) and restart the engine on next play. From F04.
  > Done: `AudioDeviceManaging.sessionEvents()` (`AudioSessionEvent`: interruption began/ended, output removed = route change
  > `.oldDeviceUnavailable`); `IOSAudioDeviceManager` maps `AVAudioSession` notifications; `EditorModel` pauses on began/removed, never
  > auto-resumes. `AVPlaybackEngine` pauses on `AVAudioEngineConfigurationChange`; with no render time left the playhead continues from the
  > last read render time by the clock; `play` restarts a stopped engine. Not testable in the simulator (no calls/route changes): device check.
- [x] F05.T04 — Adjust UI: Equalizer screen (interactive curve, bands, reset), Gain and dynamics, Effects, Loudness row placeholder (§ 8, § 18.5).
  > Done: native from § 18 (user: no Sleek). `AdjustSection` (Equalizer mini curve, Gain and dynamics, Effects — SPEC § 9 row the mockup
  > lacks —, Loudness placeholder) opens sheets `EqualizerSheet` (draggable `EQCurveView` + band chips + Frequency/Gain/Q), `GainDynamicsSheet`
  > (essentials + "Advanced" disclosure), `EffectsSheet`. `ValueSlider` (log scales, VoiceOver steps), `EQResponse` (C++ filter math). Edits
  > go through `EditorModel.adjust` (live) + `finishAdjusting` (existing commit: one undo step + autosave), so persistence/undo already work.
- [x] F05.T05 — Persist `ManualSettings`, undo on drag end, "Hold for original" bypass.
  > Done: persistence/undo came with T04 (`adjust` + `finishAdjusting` → `EditHistory` step + autosave; open/undo re-`apply`). Hold for original:
  > `PlaybackEngine.holdOriginal` sets a `bypass` parameter on both AUs; `LatencyMatchedBypass` (AudioUnitEffect.mm) crossfades 30 ms to the dry
  > input delayed by the effect's latency, kernels keep running, so timing never shifts. Switching to `working.caf` under an AI render: F06.T06a.

**Checkpoint test:** adjust each control during playback with no clicks/dropouts; hold for original; undo/redo; reopen project and settings persist.

---

## F06 — AI stack & render cache  [IN PROGRESS]
Goal: user-ordered AI stack with per-step cached renders.

- [x] F06.T01 — Vendor RNNoise into `CEchoDSP` (license file), C API, Swift wrapper; 48 kHz mono 480-frame processing with `AVAudioConverter`. Golden-file test (fan noise).
  > Done: RNNoise v0.2 + standard model (user decision, SPEC § 4.9/§ 20) in `CEchoDSP/rnnoise/` with COPYING, AUTHORS, VENDORED.md
  > (provenance; upstream fix 372f7b4 applied: v0.2 doesn't build on arm64). C API `Denoiser.h` (`EEDenoiser*`, −1…1 floats). Swift
  > `RNNoiseDenoiser` (streaming, removes RNNoise's 960-sample delay, output length = input) + `RNNoiseDenoiser.denoise(buffer)` via
  > `AudioChannels` (`AVAudioConverter` → 48 kHz float, per channel). Tests on generated speech (`TestAudio/voice.caf`) + fan noise: −26 dB in pauses, speech ±0.2 dB.
- [x] F06.T02 — `AIProcessing` + `RNNoiseProcessor` (wet/dry strength), `ClearVoiceProcessor` (§ 7), `AIProcessorRouter` (`.unknown` pass-through).
  > Done: `ChunkedRender` streams 48 kHz float input 1 s at a time through a `ChunkTransform` into ALAC 24-bit 48 kHz (cancellation +
  > progress per chunk; failed/cancelled renders leave no file; typed `RenderError`). `WetDryMix` keeps dry aligned with delayed wet.
  > Clear Voice = RNNoise → HPF 80 / −2 dB@250 / +2.5 dB shelf@3k → compressor 3:1 @ −20 (strength scales EQ, ratio, mix). Router
  > passes `.unknown` and features without a processor (Voice Leveler until F07) through. `FakeAIProcessor` for F06.T04.
- [x] F06.T03 — `FileRenderCache` (ALAC 24-bit, chain-hash keys § 6.3). Tests.
  > Done: `RenderKey` (SHA-256 of "projectID|start,duration|kind:strength;…", POSIX-formatted, op IDs excluded; `prefixes`; pinned hash
  > test). `RenderCaching` + `FileRenderCache` actor: `Library/Caches/Renders/<project>/<key>.m4a`, hidden `.render-<UUID>.m4a` temp files
  > on the same volume, `store` = move/replace, `entries` (key + bytes) for the janitor. Project delete now removes renders. `FakeRenderCache`.
- [x] F06.T04 — `AIChainRenderer`: prefix walk, progress, cancellation, latest-change-wins; `firstChangedIndex`. Tests with fake processor.
  > Done: `AIChainRendering` + `AIChainRenderer` actor: walks every prefix (§ 6.3 keeps them all for A/B), reuses hits, renders misses on
  > the previous prefix via cache temp file → `store`; progress over the steps to render; a new `render` cancels the one in flight (caller
  > cancellation too); temp files removed on failure. Returns `RenderedChain` (prefix URLs + output; empty chain = source). `AIChain`
  > + `firstChangedIndex` (SPEC's `zip(...).firstIndex` doesn't compile; same logic over indices). `FakeAIChainRenderer`.
- [x] F06.T05 — `RenderCacheJanitor`: reachability from history + current prefixes, budget eviction, close-time pruning (§ 6.4). Tests.
  > Done: `RenderCacheJanitoring` + `RenderCacheJanitor` actor. `sweep(current:history:)` (history = `EditHistory.allStates`, oldest first)
  > deletes unreachable renders, then over min(2 GB, 10 % free; 2 GB if unknown) evicts history states oldest first, keeping keys the
  > current or a newer state shares; current never evicted. `prune(current:)` for close. `FakeRenderCacheJanitor`; storage fake can fail to measure.
- [x] F06.T06 — Playback integration: keep playing previous render, swap at playhead with crossfade; per-step A/B by tapping a row.
  > Done: `SourceSwitchAudioUnit` (2 inputs, C++ `SourceSwitch.mm`, 20 ms fade starting at an exact render sample via scheduled parameter
  > events) between two player nodes and the chain. `PlaybackEngine.swapAudio(to:)`: idle player starts the new file at the same source
  > frame and render sample; playhead via a linear timeline anchor (asking a not-yet-started player for its time raises an exception —
  > found in a live run). `EditorModel`: renders on open/stack change/undo (`changeAIStack` for T07), swaps when ready, `audition(step:)`,
  > `renderProgress`, `renderedPeaks` (key "render-<hash>"), janitor sweep after history changes and prune on close. Debug `-debugAIDemo`.
- [x] F06.T06a — "Hold for original" also plays `working.caf` instead of the AI render (crossfade) on top of F05's chain bypass (§ 6.6). From F05.T05.
  > Done: with T06 — `holdOriginal` swaps to `working.caf` (crossfade) and back to the auditioned step or full render on release.
- [x] F06.T06b — Waveform peaks of renders ("render-<hash>" in the waveform cache) outlive their renders until project delete; remove them
  with the janitor's sweep (or on Clear cache, F13). From F06.T06.
  > Done: `WaveformProviding.remove(keys:projectID:)`; the janitor removes `RenderKey.waveformKey` peaks with every render it deletes
  > (sweep, eviction, prune). The key name lives in `RenderKey` only.
- [x] F06.T07 — Enhance UI: numbered list, strength sheet, reorder, swipe remove, Add enhancement sheet, inline progress, "Already reduces noise" hint; entitlement/capability checks.
  > Done: `EnhanceSection` per mockup (scroll-disabled `List` sized to content for native swipe-remove + long-press reorder; VoiceOver
  > actions), `AddEnhancementSheet` (gated by `EntitlementProvider` + `DeviceCapabilityChecking`), `StrengthSheet` (applies on release).
  > User decisions (SPEC § 9/§ 20): new steps 80 %, each feature once, A/B = filled badge + later rows dimmed, Voice Leveler hidden until
  > F07 (F07.T01a). Renderer progress now names the step (`ChainRenderProgress`) for the inline bar. Strength moves under the name at AX sizes.

**Checkpoint test:** noisy recording: apply Noise Suppression, Clear Voice, reorder, change strength, undo/redo rapidly; confirm instant undo, correct audio, cache folder shrinks after new edits; tap rows to A/B.

---

## F07 — Voice Leveler & Auto Level  [TODO]
Goal: leveling and loudness targeting.

- [ ] F07.T01 — `VoiceLevelerProcessor` (§ 7.1) as an AI-stack op. Tests on 2-speaker sample.
- [ ] F07.T01a — Offer Voice Leveler in the Add enhancement sheet (hidden until its processor exists, user decision § 9) and route it in `AIProcessorRouter`.
- [ ] F07.T02 — `EBUR128Analyzer` (integrated LUFS, true peak). Tests vs reference values.
- [ ] F07.T03 — Auto Level output stage: analysis over trim range, debounced recompute, static gain + true-peak limiter (§ 6.7).
- [ ] F07.T04 — Loudness screen: targets (YouTube, Instagram, TikTok, Spotify, Podcast, Apple Music, Custom, Off).

**Checkpoint test:** podcast with quiet/loud speakers levels evenly; Auto Level output measures within ±1 LU of target (check exported file in a loudness meter).

---

## F08 — Export  [TODO]
Goal: final render and delivery.

- [ ] F08.T01 — Offline final render (manual rendering mode) over trim range, Auto Level recomputed (§ 11.2).
- [ ] F08.T02 — Audio encoders: AAC (bitrates), WAV, FLAC, ALAC, sample rate/bit depth (§ 11.1).
- [ ] F08.T03 — Video remux: composition + passthrough, same container, metadata preserved, trim via edit lists.
- [ ] F08.T04 — Destinations: Photos (`shouldMoveFile`), Files, Share; temp cleanup.
- [ ] F08.T04a — `AppSettingsStore` protocol + `UserDefaults`-backed impl + fake (§ 4.3): appearance, tint, last export settings. Route `EchoEngineApp` and `DebugAppearanceMenu` through it (they repeat the `@AppStorage` keys and defaults today). From the F01 code review.
- [ ] F08.T05 — Export sheet UI per canvas; last-used settings; storage line; post-export actions after confirmed delivery.
- [ ] F08.T06 — `BGContinuedProcessingTask`, progress, cancellation, failure handling.

**Checkpoint test:** export 4K HDR video to Photos and verify identical video quality/metadata and new audio; export audio-only in each format; video→audio conversion with no effects; delete-after-export removes project only after save.

---

## F09 — Presets  [TODO]
Goal: built-in and user presets with iCloud sync.

- [ ] F09.T01 — `Preset` model, `FilePresetRepository`, built-in presets JSON (§ 12). Tests.
- [ ] F09.T02 — Apply (replace, one undo step, `basePresetID`), Save as preset, Update preset, "Based on … (modified)".
- [ ] F09.T03 — `SyncedPresetRepository` with `NSUbiquitousKeyValueStore`, merge by `updatedAt`, deletes. Tests with fake store.
- [ ] F09.T04 — Settings → Presets management (rename, delete).

**Checkpoint test:** create preset on iPhone simulator, apply to another project, edit and update it; with two devices on one Apple ID, preset appears on the other.

---

## F10 — Recording core  [TODO]
Goal: reliable capture from any input with recovery.

- [ ] F10.T01 — `IOSAudioDeviceManager`: session config, input list with hints, channel enumeration, built-in mono/stereo, latency values, route-change stream (§ 13.2).
- [ ] F10.T02 — `AVRecordingEngine`: continuous CAF writing (raw mixdown, processed, per-channel), locked config, level metering.
- [ ] F10.T03 — Interruptions + route changes: pause, flush, markers, manual Resume (§ 13.7).
- [ ] F10.T04 — Background audio mode, idle timer, Live Activity widget extension (timer, level, Stop).
- [ ] F10.T05 — Crash recovery of unfinished takes on launch.
- [ ] F10.T06 — Record screen UI per canvas + device/channel sheet + dim mode; Stop creates project and opens Editor.

**Checkpoint test (real device required):** record with built-in mic (mono/stereo), a USB interface with 2 channels, AirPods; lock the phone mid-recording; take a call; unplug the interface; force-quit and recover.

---

## F11 — Live processing in Record  [TODO]
Goal: live suppression, gain, leveling, clip protection.

- [ ] F11.T01 — Suppression tiers Off/Standard/High (live RNNoise ring buffer), voice-processing fallback rule (§ 13.4).
- [ ] F11.T02 — Input gain, gentle live leveler, clip limiter; ramped live parameter changes; parameter change log.
- [ ] F11.T03 — Monitoring through headphones; wired-headphones tip; settings rows UI.

**Checkpoint test (device):** record in a noisy room at each tier; shout to confirm no clipping in processed take; raw take untouched.

---

## F12 — Auto-tune & backing tracks  [TODO]
Goal: live pitch correction and sing-along.

- [ ] F12.T01 — YIN pitch detector kernel + tests on synthetic tones.
- [ ] F12.T02 — Auto-tune kernel: scale snapping, retune smoothing, humanize, PSOLA with formants; AU wrapper (§ 13.5). Golden test on sung scale.
- [ ] F12.T03 — Auto-tune UI: on/off, key (Chromatic default), scale, Natural↔Robotic, Advanced.
- [ ] F12.T04 — Backing track import + playback during recording; latency compensation stored (§ 13.6).
- [ ] F12.T05 — `ChromaKeyDetector` + "Song key: X. Use it?" suggestion. Tests.
- [ ] F12.T06 — Finish flow: vocal only vs vocal + backing mix project.

**Checkpoint test (device, wired headphones):** sing over a backing track with auto-tune at Natural and Robotic; check latency feels acceptable; mixed project is in sync.

---

## F13 — Settings  [TODO]
Goal: complete Settings screen.

- [ ] F13.T01 — Settings UI per canvas: Appearance, Tint, Presets link, Privacy toggles, Storage (sizes, Clear cache), Acknowledgements, Version (§ 14.2).
- [ ] F13.T01a — Clear cache also removes waveform caches (`Library/Caches/Waveforms`, `WaveformProviding.removeAll`); project delete already does (F04 review).
- [ ] F13.T02 — Storage sizes computation; project info sheet with per-project breakdown (§ 15).

**Checkpoint test:** every setting persists and applies instantly; Clear cache frees space and projects re-render on open.

---

## F14 — Analytics, crash reporting, consent  [TODO]
Goal: privacy-respecting telemetry.

- [ ] F14.T01 — Ask user for `GoogleService-Info.plist`; add Firebase SPM (Analytics, Crashlytics only), dSYM upload phase, Info.plist flags (§ 16).
- [ ] F14.T02 — `FirebaseAnalyticsTracker`, `CrashlyticsReporter`, no-op versions, `ConsentStore`; typed `AnalyticsEvent`; duration buckets.
- [ ] F14.T03 — Onboarding/consent screen; Settings toggles wired; instrument events listed in § 16 across features.
- [ ] F14.T04 — `PrivacyInfo.xcprivacy`; document privacy label answers for the user in the checkpoint summary.

**Checkpoint test:** consent off → no Firebase traffic (debug view); consent on → events appear in Firebase DebugView; forced test crash reports with readable symbols.

---

## F15 — Localization & accessibility pass  [TODO]
Goal: 11 languages, RTL and accessibility quality.

- [ ] F15.T01 — Translate String Catalog into 10 languages (draft); plural variants; mark "needs review".
- [ ] F15.T02 — RTL audit in Arabic: mirrored layouts, forced-LTR time views, mirrored custom icons.
- [ ] F15.T03 — Dynamic Type XXL audit, VoiceOver labels/values, contrast checks, Reduce Motion.

**Checkpoint test:** run in Arabic, Russian, German (long strings) and XXL text; navigate key flows with VoiceOver.

---

## F16 — Release readiness  [TODO]
Goal: ready for TestFlight.

- [ ] F16.T01 — App icon placeholder slot + launch screen; acknowledgements content (RNNoise, Firebase). Set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in project.yml (blank since F01.T05).
- [ ] F16.T02 — Performance pass: import/render/export timing on iPhone 11-class device, memory on 2-hour audio, battery during 1-hour recording; fix regressions.
- [ ] F16.T03 — Edge cases: no audio track, HDR/ProRes, 2-hour podcast, low storage at each stage, newer-schema project, airplane mode, iCloud signed out.
- [ ] F16.T03a — Unreadable manifests (corrupt, or a newer schema that no longer decodes) are skipped by `ProjectRepository.list()`, so Home hides them and their storage. Show them (title from raw JSON if present) with "Update Echo Engine to open this project" and Delete. From the F02 code review; unreachable in v1 (no sync, backup or downgrade path).
- [ ] F16.T04 — Checkpoint summary: list everything the user must do in App Store Connect (privacy label, age rating, descriptions in 11 languages, keywords incl. "video to audio", screenshots).

**Checkpoint test:** full TestFlight build installs and passes the edge-case list.
