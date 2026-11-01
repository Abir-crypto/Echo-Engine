# RNNoise (vendored)

Noise suppression for Noise Suppression and Clear Voice (SPEC § 4.9, § 7). BSD-3-Clause: see `COPYING` (and
`AUTHORS`); shown in Settings → Acknowledgements.

- Upstream: https://github.com/xiph/rnnoise, tag `v0.2` (commit 904a876dce1f9ab8860c0a5000ed151f9f6eef58).
- Model: standard model `0b50c45` (`model_version`), from
  https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz
  (sha256 4ac81c5c0884ec4bd5907026aaae16209b7b76cd9d7f71af582094a2f98f4b43): `src/rnnoise_data.c`, `src/rnnoise_data.h`.
- Taken: the library sources `Makefile.am` builds (`RNNOISE_SOURCES` without x86 run-time dispatch), their headers,
  `include/rnnoise.h`, and `src/x86/x86_arch_macros.h` + `src/x86/x86cpu.h` (included by `vec.h`/`vec_avx.h`).
- Patched with exactly one upstream commit after the tag: 372f7b4b76cde4ca1ec4605353dd17898a99de38 "Fix compilation
  errors" (GitHub #222: v0.2 includes a non-existent `os_support.h`, so it doesn't build on arm64). No other changes.
- Left out: training, examples, dump tools, the "little" model, x86 SSE/AVX dispatch (arm64 uses `vec_neon.h`).
- The app uses it only through `include/Denoiser.h`.

To update: replace these files from a new tag and its `model_version`, keep the list above current, and re-record the
golden files (`ECHO_UPDATE_GOLDEN=1 swift test`).
