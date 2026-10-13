import Foundation

/// The editing actions any AI can ask Eddie for — shared by the built-in "Ask Eddie" chat and the MCP server
/// for outside agents, so both always offer exactly the same tools.
enum EditActionSchema {
    static let types = ["split", "trim", "delete", "move", "duplicate", "speed", "clip_volume", "add_title", "edit_title",
                        "music", "preset", "color", "seek", "transition", "fade", "clip_fade", "format", "framing",
                        "ken_burns", "profile", "overlay", "marker", "reverse", "freeze", "clean_audio", "captions", "beats"]

    /// Field name → JSON type.
    static let fields: [String: String] = [
        "clip": "string", "title": "string", "music": "string", "target": "string",
        "at": "number", "duration": "number", "keep_from": "number", "keep_to": "number", "to_position": "integer",
        "speed": "number", "volume": "number", "text": "string", "style": "string", "x": "number", "y": "number",
        "size": "number", "rotation": "number", "font": "string", "color": "string", "weight": "string",
        "starts_at": "number", "fade_in": "number", "fade_out": "number", "preset": "string", "instruction": "string",
        "kind": "string", "aspect": "string", "opacity": "number", "layout": "string", "profile": "string", "fill": "boolean",
    ]

    /// JSON Schema for one action. `strict` is the form some providers' JSON modes need (every field present, nullable).
    static func action(strict: Bool) -> [String: Any] {
        var properties: [String: Any] = ["type": ["type": "string", "enum": types]]
        for (name, type) in fields { properties[name] = strict ? ["type": [type, "null"]] : ["type": type] }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if strict {
            schema["required"] = Array(properties.keys).sorted()
            schema["additionalProperties"] = false
        } else {
            schema["required"] = ["type"]
        }
        return schema
    }

    /// What each action does and which fields it takes.
    static let guide = """
    Each action is an object with "type" and the fields it needs (leave the others out or null):
    - split: at — cut the clip under that time into two.
    - trim: clip, keep_from, keep_to — keep only that part of the clip, in seconds from the clip's own start (0 … its length).
    - delete: target — a clip (c2), overlay (o1), title (t1), song (m1) or marker (k1).
    - move: clip, to_position — 1 = first.
    - duplicate: clip.
    - speed: clip (or "all"), speed — 0.25 to 4.
    - clip_volume: clip (or "all"), volume — 0 to 1 (0 mutes the clip's own sound).
    - add_title: text, at, duration, style ("title" | "lowerThird" | "caption"), optional x and y (0–1, center of the \
    text, y from the top), size (1 = normal, 0.3–4), rotation (degrees, clockwise), font ("System", "Rounded", "Serif", \
    "Mono" or a font family like "Georgia", "Futura", "Avenir Next", "Didot", "Marker Felt"), color ("#RRGGBB"), weight \
    ("regular" | "medium" | "bold" | "heavy"). Use \\n for a line break.
    - edit_title: title, then any of the add_title fields to change.
    - music: music, optional volume (0–1), at (timeline start), starts_at (seconds into the song), duration, fade_in, fade_out.
    - preset: clip (or "all"), preset — one of Warm, Cool, Bright, Punchy, Soft, Vivid, Moody, Cinematic, Golden, Faded, Mono.
    - color: clip (or "all"), instruction — hand off to the AI colorist for a proper grade ("natural", "warmer", "cinematic"…).
    - seek: at — move the playhead to show the user the result.
    - transition: clip (or "all" for every cut), kind ("crossDissolve" | "dipToBlack" | "wipe" | "slide" | "none"), \
    duration (0.2–3) — the transition INTO that clip from the one before.
    - fade: fade_in (seconds, fade from black at the start; 0 removes), fade_out (seconds, fade to black at the end).
    - clip_fade: clip (or overlay, or "all"), fade_in, fade_out — fade the clip's own sound in/out.
    - format: aspect ("landscape" 16:9 | "portrait" 9:16 for Reels/TikTok/Shorts | "square" | "portrait4x5" | "auto"), \
    optional fill (true = crop to fill the frame, false = fit inside with black bars).
    - framing: clip or overlay, any of size (zoom, 1 = normal), x and y (offset, -1…1 of the frame, y down), rotation.
    - ken_burns: clip or overlay (or "all"), optional size (end zoom, e.g. 1.2) — a slow push-in.
    - profile: clip or overlay (or "all"), profile ("dlogM" for log footage | "normal" for phone/normal footage).
    - overlay: target (o1…), optional at, duration, opacity (0–1), layout ("pip" | "full"), volume, and placement: \
    size (1 = fits the frame, 0.2 = small), x and y (center offset, -1…1 of the frame, y down — e.g. x 0.35, y 0.3 \
    is the bottom-right corner), rotation (degrees, clockwise).
    - marker: at, text.
    - reverse: clip or overlay — play it backwards (toggles).
    - freeze: at — hold that frame for 2 seconds (inserted there).
    - clean_audio: target (a clip, overlay or song), kind ("normalize" | "noise") — even out loudness or remove background noise.
    - captions: — transcribe the speech in the clips into captions (replaces earlier auto captions).
    - beats: music — find the song's beat so cuts can line up with it.

    Labels: c1, c2… are clips in their current order; o1… overlays; t1… titles; m1… songs, voiceovers and sound \
    effects; k1… markers. Labels are renumbered after every edit, so always use the labels from the latest timeline.
    """
}
