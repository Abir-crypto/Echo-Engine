# Test audio

Generated, not recorded (SPEC § 19):

- `voice.caf` — 6 s of speech, 48 kHz mono 16-bit, made with macOS `say -v Samantha --data-format=LEI16@48000`.
- `Golden/*.f32` — reference outputs of the DSP tests (`GoldenFile`); re-record with `ECHO_UPDATE_GOLDEN=1 swift test`.

Noise (fan) and tones are generated in code (`TestSignal`).
