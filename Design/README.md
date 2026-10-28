# Design reference (approved mockups)

Source markup of the approved Echo Engine mockups, exported from the design canvas.
These files are REFERENCE ONLY. Do not ship them, import them, or convert them mechanically.
Rebuild each screen natively in SwiftUI using the tokens in SPEC.md § 18.

How to read them:
- Each file is one 390 pt wide phone screen. Inline `style` values are the layout spec:
  sizes, paddings, gaps, radii, font sizes and weights map 1:1 to SwiftUI points.
- Hex colors map to the asset-catalog tokens in SPEC.md § 18.2 (e.g. #161B22 = Ground dark,
  #1F2630 = Surface dark, #F0B24A = Tint/amber). Never copy hex values into Swift code.
- `{{accent}}` = current tint fill; `{{accentText}}` = tint text color; `{{wave}}` = processed-waveform tint.
- The `<script>` block at the bottom only holds sample data (project names, bars, stack items). Ignore its logic.
- `href="X.dc.html"` links show navigation between screens.

| File | Screen | SPEC |
|---|---|---|
| screens/Home.dc.html | Home (dark) | § 14.1 |
| screens/HomeLight.dc.html | Home (light) | § 14.1 |
| screens/Editor.dc.html | Editor, video project (dark) | § 9 |
| screens/EditorLight.dc.html | Editor, video project (light) | § 9 |
| screens/EditorAudio.dc.html | Editor, audio project (dark) | § 9 |
| screens/Record.dc.html | Record, while recording | § 13.1 |
| screens/Export.dc.html | Export sheet | § 11.1 |
| screens/Settings.dc.html | Settings | § 14.2 |

Where SPEC.md and a mockup disagree, SPEC.md wins; mention the difference in the task note.
