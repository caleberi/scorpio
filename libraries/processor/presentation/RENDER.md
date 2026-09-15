# Deck JSON rendering contract

Versioned with the compiled IR (`version` starts at `1`). Types in `web/src/lib/presentation.ts` mirror `deck.zig`. Sampling lives in `web/src/lib/sampleTrack.ts` and must match `renderer/animation.zig`.

Unknown node `kind`s, channels, and fields must be skipped (`ignore_unknown_fields` on load). If `version` is newer than the client, refuse to play and show the version number.

## Fetch

- `GET /presentation` → `{ documents: [{ slug, title, path, duration_ms, size }] }` for the slides listing tab
- `GET /presentation/*slug` → the deck object below
- Listing UI lives at `/presentations`; player at `/presentations/<slug>` (e.g. `/presentations/blog/projects/hercules/architecture`)

## Coordinate system

- Origin is top-left of the slide canvas. `+x` right, `+y` down. Units are CSS pixels at the authored `size` (default `1920x1080`).
- Letterbox the canvas into the viewport: uniform scale, no stretch. Recording must capture the **unletterboxed** `size` canvas, not the on-screen element.
- Node `bounds` are `{ x, y, w, h }` in canvas space **before** animation. Transform origin is the node center `(x + w/2, y + h/2)` unless `origin` is set.

## Paint loop (one frame at clock `t_ms`)

1. Resolve the active slide: largest `start_ms <= t_ms`. If `t_ms` is past the last slide, clamp to the last frame of the last slide (do not loop unless `loop: true`).
2. If `t_ms` is inside the outgoing slide’s `transition.duration_ms` overlap, draw **both** slides (from then to) and composite per `transition.kind`.
3. Fill `canvas.background`.
4. Sort nodes by `z` ascending, then document order.
5. For each node, sample every track whose `target` equals `node.id` and `t_ms` is in range. Missing tracks mean identity transform (`tx=0, ty=0, sx=1, sy=1, rotate_deg=0, opacity=1`).
6. Compose **T = translate × rotate × scale** (apply scale first, then rotate, then translate — same as canvas2d `translate → rotate → scale` around the origin). Multiply `opacity` onto the draw alpha. Do not bake transforms into `bounds`.
7. Draw by `kind`:
   - `text` — `fill` color, `font` (`family`, `size_px`, `weight`). Wrap to `bounds.w`. Baseline is top-left of the first line. Set these in the README via frontmatter (`color`, `font`, `background`), slide tags (`<slide color="#fff" font="Inter" background="#111">`), or trailing braces on a heading/image (`# Title {color="#f6c244" font="Georgia" size="64" weight="700"}`).
   - `image` — `src` URL, draw into `bounds`, `fit`: `contain` (default), `cover`, or `stretch`.
   - `video` — same as image, but `src` is a video (`.mp4` / `.webm` / GitHub `user-attachments` / `{kind="video"}`). Drawn with `drawImage` on the canvas clock (`currentTime = (t_ms - slide.start_ms) / 1000`).
   - `shape` — `rect` or `ellipse` with `fill` / `stroke` / `stroke_width`.
   - `table` — GFM table compiled to `{ headers[], rows[][] }`. Draw a grid inside `bounds`: header row uses `font.weight` bold, cell text wraps, `stroke` for rules. Same transform as other nodes.
   - `mermaid` — `source` is the fence body. At load, `mermaid.render` → SVG → `ImageBitmap`, then `drawImage` with `fit: contain`. On render error, draw the source as `text` (same fallback as `MermaidDiagram`).
   - `markdown` — remaining GFM (paragraphs, lists, emphasis, links, inline code, fenced code). At load, render with `ReactMarkdown` + `remarkGfm` into an offscreen box of `bounds` size, snapshot to `ImageBitmap`, blit each frame. Links are visual only (no click-through on canvas).
   - `group` — push a clip of `bounds` if `clip` is true, draw children, pop.
8. Skip nodes with sampled `opacity <= 0`. If `src` or a mermaid/markdown snapshot fails, skip the node (do not crash the frame). Preload **must** finish before the record loop starts so every frame is a blit.

## Keyframe sampling

- Each track is one channel: `translate` (`[x,y]`), `scale` (`[sx,sy]` or a single number duplicated), `rotate` (degrees), `opacity` (`0..1`).
- Keyframes are sorted by `t_ms` (absolute from deck start). Before the first keyframe, use that first value (hold). After the last, hold the last value.
- Between two keys, lerp with `ease` on the **outgoing** keyframe. Independent channels compose: a translate track and a scale track on the same `target` both apply.

Easing formulas (`x` clamped to `0..1`):

| Name | Formula |
| --- | --- |
| `linear` | `x` |
| `ease` | `x * x * (3 - 2 * x)` (smoothstep) |
| `ease-in` | `x * x` |
| `ease-out` | `1 - (1 - x) * (1 - x)` |
| `cubic-in` | `x * x * x` |
| `cubic-out` | `1 - (1 - x)^3` |
| `cubic-in-out` | `x < 0.5 ? 4 * x^3 : 1 - (-2x + 2)^3 / 2` |

`ease-in-out` is an alias of `cubic-in-out`.

## Clocks

- Live: `t_ms = performance.now() - startedAt`. Prev/next seeks to `slides[i].start_ms`. Space toggles pause (freeze `t_ms`). Live mode may wait on user input before advancing.
- Record: `t_ms = frameIndex * (1000 / fps)` from `0` to `sum(slide.duration_ms)`. Do not use `requestAnimationFrame` as the source of time while encoding. The recorder always auto-advances.
- Slide `duration_ms` is the recorded length.

Keyboard (player chrome): `→` next, `←` prev, `Space` pause/play, `Home` / `End` first/last, `T` outline.

## Transitions

- `none` — hard cut at `start_ms`
- `fade` — crossfade opacities over `transition.duration_ms` at the boundary
- `slide_left` — outgoing moves `-width * p`, incoming moves in from `+width * (1-p)`

## Soundtrack

- Deck `soundtrack` starts at `start_ms` (usually `0`), media `offset_ms` is the trim into the file, `volume` is `0..1`.
- Slide `cues[]` are extra buffers mixed on the same clock (`start_ms`, `url`, `volume`).
- Decode before play/record. If a URL 404s, continue silent. Record mux: canvas `captureStream(fps)` + `MediaStreamAudioDestinationNode`.

## Minimal player pseudocode

```
const deck = await getPresentation(slug)
const ctx = canvas.getContext('2d')
canvas.width = deck.size.w
canvas.height = deck.size.h

function frame(t_ms) {
  const slide = slideAt(deck, t_ms)
  ctx.fillStyle = cssColor(slide.canvas.background)
  ctx.fillRect(0, 0, deck.size.w, deck.size.h)
  for (const node of sortByZ(slide.nodes)) {
    const xf = sampleTransform(slide.tracks, node.id, t_ms)
    ctx.save()
    ctx.globalAlpha = xf.opacity
    ctx.translate(node.bounds.x + node.bounds.w / 2 + xf.tx,
                  node.bounds.y + node.bounds.h / 2 + xf.ty)
    ctx.rotate(xf.rotate_deg * Math.PI / 180)
    ctx.scale(xf.sx, xf.sy)
    ctx.translate(-node.bounds.w / 2, -node.bounds.h / 2)
    drawNode(ctx, node)
    ctx.restore()
  }
}
```

## Worked example

One slide, one image, two keyframes — translate `0,40 → 0,0` over 800ms, linear.

```json
{
  "target": "title",
  "channel": "translate",
  "keyframes": [
    { "t_ms": 0, "value": [0, 40], "ease": "linear" },
    { "t_ms": 800, "value": [0, 0], "ease": "linear" }
  ]
}
```

Expected `sampleTransform` (see `WORKED_KEYS` in `web/src/lib/sampleTrack.ts`):

| `t_ms` | `tx` | `ty` |
| --- | --- | --- |
| `0` | `0` | `40` (hold first) |
| `400` | `0` | `20` (midpoint lerp) |
| `800` | `0` | `0` (last key) |
| `900` | `0` | `0` (hold last) |
