# Eddie — AI color grading for DJI D-Log M footage

## Goal
A native macOS app where a person with no grading experience opens a DJI Osmo Action 4
D-Log M 10-bit clip, presses **Auto Grade**, and gets good-looking footage. The AI is the
operator: it looks at frames + measurements and sets the editor's knobs. The person only
adjusts *how strong* the grade is, asks for changes in plain words ("warmer", "moodier"),
or re-runs the AI.

Success: a flat gray LOG clip becomes natural, well-exposed, pleasing footage in one click,
the result can be nudged without knowing what any knob means, and the graded clip exports.

## Non-goals (v1)
Cutting/trimming, multiple clips on a timeline, per-scene grading, masks/secondary grading,
audio editing. (Per-scene grading is the obvious v2.)

## Pipeline
```
decoded 10-bit frame (raw LOG code values, no color management)
  → DJI official D-Log M → Rec.709 LUT (33³ .cube, bundled; other .cube files importable)
  → grade kernel (10 knobs, float math)
  → Rec.709 output
```
All processing is in 16-bit float (Core Image, RGBAh working format, color management off so
the LUT sees true LOG code values). The same renderer is used for live preview, AI frames and export.

## The knobs (the "recipe")
| Knob | Range | Meaning |
|---|---|---|
| exposure | −2…+2 EV | overall brightness (linear light) |
| contrast | −100…100 | S-curve around mid-gray |
| highlights | −100…100 | bright areas (negative recovers detail) |
| shadows | −100…100 | dark areas (positive opens them up) |
| whites | −100…100 | white point |
| blacks | −100…100 | black point |
| temperature | −100…100 | blue ↔ yellow |
| tint | −100…100 | green ↔ magenta |
| vibrance | −100…100 | saturation weighted toward muted colors |
| saturation | −100…100 | uniform saturation |

A recipe is a small JSON document. **Intensity** (0–150 %) multiplies every knob, so "less" /
"more" is instant and never calls the AI.

## AI loop
1. Sample 6 frames evenly across the clip (decoded once, cached at ~1280 px).
2. App measures each frame: luma percentiles, clipped/crushed %, mean color, color of the
   brightest near-neutral pixels (white-balance hint), mean saturation.
3. **Round 1:** send LUT-only frames + measurements + knob definitions → the model returns a recipe.
4. **Rounds 2–3 (self-check):** render the frames with that recipe, send them back with the
   recipe and new measurements → the model returns a corrected recipe or `satisfied: true`.
5. **Refine:** user text ("make it warmer") + current graded frames + current recipe → new recipe.

Each round is a fresh single request (no growing history). The model answers in a JSON
schema (structured outputs where the provider supports it); values are clamped client-side.

### Provider-agnostic AI
The grading logic only talks to a `VisionModel` protocol: *system prompt + text + JPEG frames +
JSON schema → JSON text*. Providers (raw HTTPS, no SDKs), chosen in Settings:

| Provider | Default model | Endpoint | JSON enforcement |
|---|---|---|---|
| Gemini | `gemini-3.8-flash` | `generateContent` | `responseMimeType` + `responseJsonSchema` |
| OpenAI | `gpt-5.5` | Chat Completions | `response_format: json_schema` (strict) |
| Claude | `claude-opus-5` | Messages | `output_config.format` json_schema, refusal fallback |
| DeepSeek (default) | `deepseek-flash` | OpenAI-compatible Chat Completions | `response_format: json_object`, reasoning on |

Model names are editable per provider. Each provider has its own key (Keychain, falling back to
`GEMINI_API_KEY` / `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `DEEPSEEK_API_KEY`). The prompt also
spells out the JSON shape and the parser extracts the JSON object, so a provider without
schema enforcement still works. Adding a provider = one new type conforming to `VisionModel`.

## App
SwiftUI, macOS 15+. One window:
- Left: video player (live graded preview) with a **View** picker: Original LOG / LUT only / Graded.
- Right panel: **Auto Grade**, progress log with the AI's reasoning, **Intensity** slider,
  "Ask for a change" text field, **Export**. A collapsed "Knobs" section shows the 10 values
  (editable, for curiosity/debugging).
- Settings: AI provider picker, per-provider API key + model name, LUT override.

## Components
| Unit | Responsibility |
|---|---|
| `GradeRecipe` | Knob values, ranges, clamping, intensity scaling, JSON |
| `CubeLUT` | Parse `.cube` → Core Image color cube data |
| `GradeKernel.ci.metal` + `GradeRenderer` | LUT + knob math on a `CIImage` |
| `GradeCompositor` | `AVVideoCompositing` that runs `GradeRenderer` for playback/export |
| `FrameSampler` | Decode raw 10-bit frames at chosen times via `AVAssetReader` |
| `FrameStats` | Measurements from a rendered frame |
| `VisionModel` + providers | Provider-agnostic AI call; Gemini/OpenAI/Claude/DeepSeek |
| `GradingAgent` | Orchestrates rounds 1–3 and refine |
| `Exporter` | `AVAssetExportSession` HEVC with the grade baked in |

## Error handling
Missing key → Settings prompt. HTTP/API errors and refusals surface in the log; the current
recipe is kept. Invalid JSON is impossible under structured outputs but still guarded.
Unsupported file (no video track) → alert.

## Testing
Unit tests: `.cube` parsing, recipe clamping/scaling/JSON, neutral recipe = LUT-only output,
each knob moves pixels in the expected direction, stats on synthetic images, request body
shape and response parsing. Integration: synthetic 10-bit HEVC clip through sampler,
compositor (image generator) and export.
