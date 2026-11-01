# Test audio

Generated, not recorded (SPEC § 19):

- `voice.caf` — 6 s of speech, 48 kHz mono 16-bit, made with macOS `say -v Samantha --data-format=LEI16@48000`.
- `two-speakers.caf` + `.json` — 9.8 s, 48 kHz mono 16-bit: speaker A (`say -v Samantha`) at −14 dBFS RMS and speaker B
  (`say -v Daniel`) at −32 dBFS, 0.5 s pauses, a −62 dBFS noise floor; the JSON lists each speaker's frames. For the Voice
  Leveler (SPEC § 7.1).
- `Golden/*.f32` — reference outputs of the DSP tests (`GoldenFile`); re-record with `ECHO_UPDATE_GOLDEN=1 swift test`.

Noise (fan) and tones are generated in code (`TestSignal`).
