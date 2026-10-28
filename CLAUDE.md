# CLAUDE.md — Echo Engine

You are implementing **Echo Engine**, an iOS/iPadOS audio processing app (AppLab Ltd.).
These three files are your source of truth. Read them at the start of EVERY session:

1. `CLAUDE.md` (this file) — how to work.
2. `SPEC.md` — what to build and how. Authoritative for product, architecture, models, UI.
3. `TASKS.md` — progress tracker. Authoritative for what is done and what is next.

Never rely on memory of a previous session. If it is not in these files or the repo, it did not happen.

---

## Session start protocol

1. Read `CLAUDE.md`, `SPEC.md`, `TASKS.md` in full.
2. Run `git status` and `git log --oneline -15`. Confirm the working tree matches TASKS.md
   (last `[x]` task has a matching commit). If the tree is dirty or TASKS.md disagrees with git,
   STOP and report the mismatch to the user before doing anything.
3. Find the first feature marked `[IN PROGRESS]`, else the first `[TODO]` feature.
   Inside it, find the first unchecked task. That is your current task.
4. State in chat: current feature, current task, and your short plan for it. Then start.

## Task loop (repeat per small task)

1. Implement ONLY the current task. Follow SPEC.md exactly.
2. Build and test:
   - Build: `xcodebuild -scheme EchoEngine -destination 'platform=iOS Simulator,name=iPhone 17' build`
     (use any available iOS 26 simulator; list with `xcrun simctl list devices available`).
   - Test: `swift test` in `Packages/EchoCore` and/or `xcodebuild test` for app targets.
   - A task is not done until it builds with zero errors and its tests pass. Fix warnings you introduced.
3. Update `TASKS.md`:
   - Mark the task `[x]`.
   - Add a completion note directly under it, 1–4 lines, starting with `> Done:` — WHAT was done and HOW
     (key types/files, notable decisions, anything the next session must know).
   - If the task revealed new required work, add it as a new unchecked task in the right feature
     (ID suffix `a`, `b`, e.g. `F04.T03a`) and mention it in the note.
4. Commit: `git add -A && git commit -m "<TaskID>: <short summary>"`
   e.g. `F06.T02: RenderCache with chain-hash keys`.
5. Print the same completion note in chat.
6. Move to the next task in the same feature.

## Feature checkpoint (after the last task of a major feature)

1. Mark the feature `[DONE]` in TASKS.md, mark the next feature `[IN PROGRESS]`.
2. Commit TASKS.md (`<FeatureID>: checkpoint`), then `git push origin main`.
3. Print a checkpoint summary in chat:
   - What the feature delivers.
   - The manual test checklist from TASKS.md for this feature (what the user should build/run/try).
   - Known limitations or follow-ups.
4. **STOP. Do not start the next feature** until the user says to continue.

## When unsure

- Ask the user instead of guessing — about product behaviour, UX, scope, or anything SPEC.md does not cover
  or covers ambiguously.
- After the user answers, record the decision in SPEC.md (in the relevant section, plus a line in
  `SPEC.md § 20 Decision log`) and commit it with the current task. Future sessions must not need to ask again.
- Things only the user can do (Xcode signing team, bundle ID, Firebase `GoogleService-Info.plist`,
  installing tools, App Store Connect): ask, explain exactly what is needed, and wait.

## Hard rules

- **Scope:** implement only v1 scope (SPEC.md § 2). Never build "Later" items early, even partially,
  except where SPEC.md explicitly says to prepare a hook (e.g. `clips` array, `EntitlementProvider`).
- **Architecture:** SPEC.md § 4. Protocol-first services, constructor injection, one composition root,
  single-purpose types. No singletons except where Apple APIs force them (wrap them behind protocols).
- **Real-time audio thread:** no allocation, no locks, no Swift class/ARC traffic, no logging, no async in
  render callbacks. DSP kernels in C++; parameters only via `AUParameterTree` with ramping.
- **Colors and strings:** every color from the asset catalog (light + dark variants); every user-facing
  string localizable via String Catalog. No hard-coded hex in views, no hard-coded UI strings.
- **Layout direction:** use leading/trailing. Time-based views (waveforms, trim strip, meters, EQ graph,
  transport icons) are forced left-to-right.
- **Privacy:** never log, track, or report user content (titles, file names, audio, paths).
- **Git:** work on `main`. One commit per small task. Push only at feature checkpoints. Never force-push,
  never rewrite history, never commit build output, DerivedData, caches, or secrets.
- **Dependencies:** only those listed in SPEC.md § 4.9. Ask before adding anything else.
- **Do not** modify SPEC.md decisions on your own. Only record decisions the user made.

## Repo layout (see SPEC.md § 4.2)

```
/CLAUDE.md  /SPEC.md  /TASKS.md
/project.yml                 # XcodeGen project definition (source of truth for the Xcode project)
/App-iOS/                    # iOS/iPadOS app target (SwiftUI)
/Packages/EchoCore/          # platform-independent engine, DSP, models, services
/Packages/EchoCore/Sources/CEchoDSP/   # C/C++ DSP kernels + vendored RNNoise
/Resources/                  # asset catalog, String Catalog, built-in presets, test audio
```
