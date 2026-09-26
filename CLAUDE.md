# Darkroom

Native macOS image editor. Deep-Apple-stack, cloud-backed, non-destructive, forward-compatible.

## Design north star — this trumps everything

**Silky smooth or go home.**

- 60/120 Hz. Every frame. No jank, no jitter, no dropped frames — ever.
- Zoom, pan, pinch, slider drags, tool switches, panel transitions: all must feel physically continuous.
- If a feature can't ship smooth, it doesn't ship.

**Usability: tactile, soft, gorgeous, dynamic.**

- **Tactile** — every gesture has immediate feedback. Cursor tracks input in the same frame. Pinch zooms around the fingers, not the center. Buttons depress. Nothing feels dead.
- **Soft** — transitions ease, don't cut. Never a hard pop. Panels slide. Selections breathe. Motion is subtle, never showy.
- **Gorgeous** — obsessive typography, spacing, color, iconography. Nothing looks stock or templated. Dark chrome that reads as premium. Empty states are considered, not skipped.
- **Dynamic** — the interface responds to context. Tool options change with tool. HUD updates live. The app feels alive under the cursor, not static.

**How to apply:** if a decision trades polish for shipping speed, choose polish. If a feature can't be made smooth, cut it — do not ship a compromised version.

## Architecture constraints (load-bearing, do not violate)

### 1. Cloud-first source model
Sources live in S3 (or another remote store) as the default assumption. Local files are a special case, not the default.

- **Never** assume `URL(fileURLWithPath:)`. All source access goes through a `SourceProvider` abstraction that may be remote.
- **All I/O is async, cancellable, resumable.** Sync `CGImageSource...` calls on the main thread are banned outside the LocalFileSource implementation.
- Auth (presigned URLs, credentials, offline tokens) belongs to the source layer, never leaks into the render pipeline or UI.
- The project file references sources by opaque URL (`s3://bucket/key`, `file:///…`) — the provider layer resolves them.
- **Offline editability is a feature**, not a fallback: once the proxy is cached, the user can edit with no network.

### 2. Proxy-first editing (500GB-scale images are in-scope)
We target images up to Photoshop PSB scale (multi-GB, hundreds of megapixels, gigapixel composites). Full-resolution source rarely fits in RAM and never fits in VRAM.

- **Editing always happens on a proxy**, not the full source. Proxy = downsampled representation (default target ~4K longest edge) generated once on ingest and cached locally.
- Full-resolution is touched only at **export** (final render) or **zoomed-in inspection** (tile-on-demand from the region under the viewport).
- The render pipeline is **resolution-agnostic**: same graph + same parameters produce a correct image at any resolution. Proxy render at 2K and export render at 200MP are the same code path with different inputs.
- **Never** load a full source into a `CIImage` backed by a `CGImage` — that pins the entire decoded bitmap in RAM. Use `CIImageProvider` for tiled/lazy loading of large sources.
- Tiles are cached at multiple mipmap levels (image pyramid). On viewport change we sample the level nearest the current zoom.

### 3. Forward compatibility (schema evolution)
The on-disk model must never break existing files, regardless of feature growth.

- **Every serialized struct carries `schema: Int`**, starting at 1. Bump only on breaking changes.
- **Additive-only schema by default.** New fields are optional with sensible defaults. Removed fields stay in the codec (ignored, but decoded without error).
- **Unknown enum cases decode as `.unknown(raw: String)`**, not as decode errors. Preserves round-trip fidelity from newer versions written back by older ones.
- **Unknown top-level fields survive round-trip.** Decode into a dictionary bucket, re-emit on encode. A user editing a v2 file in a v1 binary never loses their v2 data.
- **Migration functions** live in one place: `Schema.migrate(from:to:document:)`. Never scatter version checks through the code.
- The `.darkroom` project bundle is a folder (NSFileWrapper). New files can be added to the bundle without breaking old readers — old readers ignore unknown bundle entries but preserve them on save.
- **Never** encode Swift enums with `rawValue: Int`. Always `String`. Integers reorder silently across refactors; strings don't.
- **Never** rename a serialized field. Add a new field, deprecate the old, keep decoding both.

## Antipatterns — never ship this

- **"Preview on release" sliders.** Any slider that produces a visible result on the image must render *live* on every frame during the drag. Deferring the render until `onEditingChanged(false)` breaks the silky-smooth covenant and turns adjustment into guesswork. Live-preview via a model side-channel (e.g. `pendingOperation`), commit ONE history entry on drag-end.
- **`.id(x)` on a stateful `NSViewRepresentable`.** Bumping the id tears down and rebuilds the underlying AppKit view (MTKView, WKWebView, NSTextView) — you lose GPU state, first responder, everything. Wire redraws through `updateNSView` or notifications instead.
- **Rendering the full pipeline on every pan event.** Pan doesn't change `state`. Cache the evaluated `CIImage` and invalidate only when state actually changes. Combined with proxy-first rendering, this keeps huge images at 120 Hz.
- **Appending operations of the same kind on repeated clicks.** Crop, straighten, and rotate should be idempotent: a new rectangle replaces the pending one, a new angle replaces the previous, a click on the same flip toggles it off. History shows one entry per user gesture, not per keystroke.

## Code quality — this is not optional

We're building for the long haul. Speed to ship never buys the right to skimp on design.

- **Single responsibility.** Each type has one reason to change. If you can describe a type in one sentence with "and", split it.
- **Pure functions over mutating methods** wherever plausible. `Adjustments.apply(to:)`, `Operation.apply(to:)`, `EditorState.evaluate(source:)` — these must be pure, deterministic, and side-effect-free. Same input → same output, no exceptions.
- **Value types (`struct`) for state, reference types (`class`) for identity.** Adjustments, EditorState, Operation, HistoryEntry = struct. Document, HistoryManager, MTKView = class. If you catch yourself reaching for a class for pure data, stop.
- **Low cyclomatic complexity.** No function longer than ~30 lines. No `switch` with 15 cases in the same function — extract or table-drive it. If a function needs comments to explain its control flow, it's already too complex.
- **High cohesion, loose coupling.** A file should be about one thing. If `CanvasView.swift` starts having methods that don't touch the view, they belong elsewhere. Types communicate via protocols, not concrete classes, when boundaries matter (render targets, source providers, panels).
- **Fail loudly at boundaries.** Fatal errors on programmer mistakes (`fatalError` for "should never happen"); typed `throws` at file/network boundaries. Never silently swallow errors.
- **No global mutable state.** `SharedRenderer` is the one deliberate exception (thread-safe Metal singleton). Everything else is dependency-injected.
- **Every non-trivial pure logic path has a unit test.** Adjustments math, Operation.apply, EditorState transitions, HistoryManager commit/restore/truncate. UI code exempt (verified by screenshot review).
- **Names carry weight.** `commit` means "make this history entry the current tip". `restore` means "jump to a previous state". `apply` means "produce a new value". Don't overload verbs.
- **No comments explaining *what*.** Only *why* — a hidden constraint, a workaround, a non-obvious tradeoff.

## Stack constraints

- macOS 15+ only. No Windows/Linux compat shims.
- Zero third-party dependencies except AWS SDK (later) and only if Apple has no equivalent (`URLSession` covers most S3 needs via presigned URLs).
- Swift 5 language mode; Swift 6 concurrency deferred until MVP settles.
- Xcode project generated by xcodegen from `project.yml` — regen after adding files.
- Sandboxed, ad-hoc signed for local dev.

## Render pipeline invariants

- All pixel operations flow through `CanvasModel.RenderNode` graph → `CIImage`. Never mutate bitmaps destructively.
- All mutations are `Command`s registered with `NSDocument.undoManager`. Undo is not optional.
- `CIContext` is created once (`SharedRenderer.shared`). Never per-frame.
- Render coordinate space is drawable pixels (`bounds * backingScaleFactor`). All positioning math stays in pixel space end-to-end; never mix points and pixels in one transform.
- Render is a **pure function** of `(SourceProvider, RenderNode graph, Adjustments, target resolution)`. No hidden state, no globals other than the shared `CIContext`.

## Build

```
xcodegen generate
xcodebuild -project Darkroom.xcodeproj -scheme Darkroom -configuration Debug build
```
