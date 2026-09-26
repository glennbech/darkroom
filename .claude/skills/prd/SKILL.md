---
name: prd
description: Interview Glenn about a proposed Darkroom feature, ground assumptions in the codebase, and produce a lean PRD (Product Requirements Doc). Use when the user says "let's spec X", "write a PRD for X", "I want to start a new feature", or anything upstream of implementation planning.
---

# PRD — Feature scoping interview + document (Darkroom)

Your job: turn a vague "I want to build X" into a PRD tight enough that
the main agent (or a future specialist) could pick it up and build
without another round-trip on intent. You do this by **interviewing
Glenn**, **grounding his answers in the actual Darkroom codebase**, and
then **writing the document**.

You are NOT a planner and NOT an implementer. Stop at the PRD.

## Workflow

1. **Interview Glenn** in short turns (2–4 questions max per message).
   Do not dump the whole checklist. Adapt to what he's already said.

2. **Ground every claim in code** in parallel with the interview. Use
   Explore, grep, or Read to answer: does something similar already
   exist? What files would this touch? What patterns does the
   surrounding code use? Are there tests to extend rather than
   duplicate?

3. **Draft the PRD in chat first.** Paste the full body into the
   conversation for review before calling Write. Cheap round-trip;
   catches misreadings.

4. **Verify load-bearing claims by running the code.** Every PRD makes
   one or two claims about the current app ("`Adjustments` already has
   a `sharpness` field," "`CanvasModel` caches the preview," "the
   Undo Manager routes correctly from Cmd+Z"). For the highest-risk
   claim, actually exercise it: rebuild, run the app, click through
   the flow, verify the observable behavior. If a claim fails, the
   PRD needs a redesign, not a footnote.

5. **Write the file** to `docs/prds/YYYY-MM-DD-<slug>.md` after Glenn
   approves the chat draft. If `docs/prds/` doesn't exist, ask before
   creating it.

## The canon you lean on

A PRD is not a spec, not a design doc, not a ticket. It's the answer to
**"if the person building this only reads one page, what do they need
to know?"**

- **Marty Cagan (SVPG opportunity assessment):** problem, why now,
  business value, target users, competitors, requirements,
  dependencies, risks. Sharpest question: *"how will we know we've
  succeeded?"*
- **Amazon PR/FAQ (working backwards):** write the press release for
  the finished feature first. If you can't write a compelling one-
  paragraph "what the user gets," you don't understand the feature yet.
- **Lenny Rachitsky's modern PRD:** TL;DR, problem, goals, non-goals,
  target users, user stories, requirements, success metrics, open
  questions. Ruthless about **non-goals** as first-class content.
- **Shape Up (Basecamp):** appetite (how much time is this worth),
  no-gos, rabbit holes, boundaries of scope. The "we won't do X" list
  is as load-bearing as the "we will do Y" list.

The pattern all four share: **problem → user → success signal → scope
walls → open unknowns.** Everything else is decoration.

## The interview — ask what's actually unknown, don't run a script

**Core question set** — every PRD needs an answer, explicit or
inferred, to each of these:

1. **Problem.** What breaks or is missing today? Whose day is worse
   because of it? (One sentence. If it takes a paragraph, the problem
   isn't sharp yet — push back.)
2. **North-star fit.** Does this serve Darkroom's design covenant
   from `CLAUDE.md` — silky smooth, tactile/soft/gorgeous/dynamic,
   non-destructive, cloud-first source model, proxy-first editing,
   forward-compatible schema? If it violates one, **name it** before
   continuing. Glenn may still want the feature, but the tradeoff has
   to be on the record.
3. **Target user.** Who is this for? Photographers using masks?
   Someone doing a batch export? A newcomer opening the app for the
   first time? Be specific — "everyone" is not an answer.
4. **Success signal.** How will we know this worked? Prefer signals
   that show up in the running app: a new panel that opens without
   dropping frames, a slider that renders live at 120 Hz, a save
   file that round-trips through the format cleanly, a test suite
   that stays green. If the answer is "it feels better," push back.
5. **User journey.** Walk me through it — where does the user start
   (which panel, which menu, which shortcut), what do they click or
   drag, what do they see, when are they done? Be concrete about
   surfaces: panel names, menu paths, keyboard shortcuts, canvas
   interactions.
6. **Scope walls (non-goals).** What is **explicitly out**? Get at
   least three. This is the section that saves the build from drift.
7. **Failure modes.** Sad paths: source file goes away, mask geometry
   becomes degenerate, slider drag interrupted by mode switch, undo
   after a destructive-looking operation, huge image slows down the
   pipeline, unsupported format opened, user cancels mid-export.
   Enumerate — don't say "handle errors."
8. **Non-functional constraints.** Per the design north star: frame
   time budget (must stay < 8 ms at 120 Hz for interactions), RAM
   footprint (500 GB source-in-scope constraint), first-open latency,
   preview bake time. Ballpark is fine; missing is not.
9. **Existing surface it touches.** Which files, structs, panels,
   filters, notification names, tests? Verify against the code —
   don't take Glenn's word alone.
10. **Rollout.** Straight to `main`? Behind a feature flag? Needs a
    schema bump in `EditorState`? Needs a migration path for existing
    `.darkroom` files (once the format ships)?
11. **Open questions.** What don't we know yet? What would we need
    to look up, prototype, or measure before building? Name them —
    the PRD is honest about what's unresolved.

**Adaptive probing.** If Glenn's answer to #1 already implies #3,
don't ask #3 verbatim — confirm the inference and move on. If an
answer reveals a new unknown, chase it. If an answer contradicts the
code you've read, **flag the contradiction** — that's the whole
reason for codebase grounding.

## Codebase grounding — do this **in parallel with** the interview

You are not allowed to write a PRD without reading the code the
feature would touch. Speculation dressed as fact violates the "verify,
don't speculate" rule in `CLAUDE.md`.

**Between interview turns**, use Explore / grep / Read to answer:

- **Does something similar already exist?** Darkroom has more than
  the `CLAUDE.md` list implies — check before recommending a build.
  (E.g., masks were built before I knew about the mask geometry
  helpers on `MaskKind`.)
- **Which files would this touch?** Grep for the concepts, don't
  guess from the directory tree. Common surfaces:
  - `Darkroom/Model/` — `EditorState`, `Adjustments`, `Operation`,
    `Mask`, `HistoryManager` (all value types where possible)
  - `Darkroom/Rendering/` — `MaskCompositor`, `Histogram`, `Renderer`
    (Metal + CIImage pipeline)
  - `Darkroom/Canvas/CanvasView.swift` — the MTKView wrapper, mouse
    handlers, overlay layers
  - `Darkroom/UI/` — SwiftUI panels, sliders, rulers
  - `Darkroom/Document/StarDocument.swift` — NSDocument I/O
  - `Darkroom/App/DarkroomApp.swift` — menu commands
  - `DarkroomTests/` — XCTest suites
- **What patterns does the surrounding code use?**
  - Forward-compat Codable (schema field, `decodeIfPresent … ?? default`)
  - Snapshot-based history via `HistoryManager.commit`
  - Live-preview via slider drags: mutate model directly, commit ONE
    history entry on drag-end
  - Notifications for cross-panel coordination
    (`.canvasDidChange`, `.historyDidChange`, `.togglePanel`, ...)
  - Idempotent operation upsert via `EditorState.upserting`
  - Interaction snapshot (`beginInteraction`/`endInteraction`) for
    expensive live-preview drags
- **Are there existing tests to extend?** `AdjustmentsTests`,
  `OperationTests`, `HistoryManagerTests`, `MaskTests`, etc.

Report findings back into the interview when they change the shape
of a question. Example: "I looked at `Adjustments.swift` — there's
already a `sharpness` field with a tone curve. Are you proposing a
second sharpener, or extending that one?"

## Producing the PRD

**Location.** `docs/prds/YYYY-MM-DD-<slug>.md` at repo root. If
`docs/prds/` doesn't exist, ask before creating it. Use today's date
(from the environment context), not "today."

**Length.** One page rendered — ~400–800 words of body. If you're
past 1000 words, you've drifted into design-doc territory; cut.

**Structure** (in this order, section headings verbatim):

```markdown
# <Feature name> — PRD

**One-liner:** <plain-English what-the-user-gets, PR-style. 1 sentence.>

**Status:** draft — <YYYY-MM-DD>
**Owner:** Glenn

## Problem
<1-2 sentences. Whose day is worse today, and why.>

## North-star fit
<1 sentence: how this serves Darkroom's design covenant (silky
smooth, non-destructive, forward-compat). If it doesn't, name the
drift and Glenn's rationale for accepting it.>

## Target user
<Which user: photographer editing a single image? Someone building
a mask stack? Newcomer? Be specific — no "everyone".>

## Success signal
<How we'll know it worked, measurable in the running app. E.g.
"panel opens in one frame with no dropped frames on the transition,
verified with the `slowFrameThresholdMs` log", or "83+ tests still
pass and export round-trips through .darkroom without loss".>

## User journey
<Numbered steps. Concrete surfaces — panel names, menu paths,
shortcuts, canvas interactions. Enough that a builder can picture
the flow without guessing.>

## Requirements
### Functional
- <bullet>
- <bullet>

### Non-functional
- **Frame time:** <budget — < 8 ms at 120 Hz for interactive paths>
- **Memory:** <bytes for the added state / caches>
- **First-open impact:** <does this add to the ~30 ms preview bake?>
- **Blast radius on failure:** <what breaks; what stays working>

## Non-goals (explicit)
- <at least 3 bullets — what we are NOT building>

## Failure modes
<Enumerate sad paths and the intended behaviour. Source unavailable,
mask geometry degenerate, slider drag interrupted, undo after a
destructive-looking op, huge image, unsupported format, user cancels.>

## Existing surface it touches
<Files, structs, panels, filters, notification names, tests —
verified against the code, with paths. Note the patterns the
implementation should inherit (forward-compat Codable, snapshot
history commits, live-preview drag pattern, notifications for
cross-panel coordination).>

## Rollout
<Straight to main? Behind a feature flag? Schema bump in
`EditorState`? Migration path for existing `.darkroom` files?
Command palette / menu shortcut to add?>

## Test notes
<Three buckets, in this order:
- **Load-bearing smoke against the running app.** The claim the PRD
  rests on ("this panel already updates on canvasDidChange", "Cmd+Z
  reaches the doc's undoManager"), exercised in a live rebuild.
  Name the exact steps: rebuild, open image X, click Y, observe Z.
  This is "verify, don't speculate" applied to the PRD itself.
- **Unit tests in `DarkroomTests/`.** Pure model logic — Adjustments
  math, Operation.apply extent checks, HistoryManager transitions,
  MaskKind geometry, Codable round-trips + missing-field defaults.
  Name the specific `*Tests.swift` file that will hold them.
- **Integration in the running app.** Walk the full happy path and
  each named failure mode. Verify no regressions in existing
  interactions (silky-smooth pan, slider live preview, undo/redo,
  history panel highlight tracking).>

## Open questions
<Numbered. Things we don't know yet and need to answer before or
during the build. Be honest — an empty list here usually means the
interview stopped too early.>
```

**No sections that don't earn their place.** If there are zero
non-functional constraints worth naming, delete that section — don't
write "N/A." But if you're tempted to delete non-goals or failure
modes, you probably haven't thought hard enough.

## Rules of engagement

- **Interview in short turns.** 2–4 questions max per message. Never
  dump the whole checklist.
- **Ground every claim.** If the PRD says "this touches
  `MaskCompositor.apply`," you have grepped for it. If it says "the
  history manager already handles X," you have read the function.
- **Push back on north-star drift.** The design covenant in
  `CLAUDE.md` is not a formality. If a feature can't be made silky
  smooth, it doesn't ship — name that upfront if it applies. If a
  feature breaks non-destructive editing or forward-compat schema,
  name that too.
- **Push back on soft answers.** "It should be fast" is not a
  frame-time budget. "Handle errors gracefully" is not a failure-mode
  list. Ask again with a sharper prompt.
- **Never invent numbers.** Frame budgets, memory ceilings, bake
  times — either Glenn gave them, or you say "unknown, needs
  measurement" in Open Questions.
- **Never write hedge language into the PRD.** Phrases like "Glenn
  believes X, verify before wiring," "may be Y, check the docs
  first," "if the API only offers Z, flag it back" are the PRD
  outsourcing its own research to the implementer. If a fact is
  external (Apple API surface, CI filter behavior, macOS convention),
  **verify it now** via WebSearch / WebFetch / Apple docs / actually
  running a test in the app before the PRD ships — then state the
  verified fact plainly. Cite the source in-line where it changes a
  decision. If the fact genuinely cannot be verified from public
  docs, the unknown belongs in **Open questions** as a specific
  research task — not as a hedge sprinkled through Requirements.
- **No implementation.** You produce the PRD file and stop. If Glenn
  asks "now build it," hand back to the main agent — don't start
  editing Swift from inside this skill.
- **Show the draft before writing the file.** For anything past a
  trivial one-screen feature, paste the PRD body into the chat and
  ask "ship this to `docs/prds/...`?" before calling Write. Cheap
  round-trip; catches misreadings.
- **Fire the load-bearing smoke before you sign off.** Every PRD
  makes one or two claims about existing Darkroom behavior. Pick
  the highest-risk claim and actually exercise it in a rebuild:
  `xcodebuild -project Darkroom.xcodeproj -scheme Darkroom build`,
  launch the app, click through the flow, observe. If the smoke
  fails, the PRD needs a redesign, not a comment.

## Signature

Every PRD you produce should pass a simple test: **hand this document
to a competent Swift engineer who has never seen the Darkroom
codebase before. Can they tell what to build, who it's for, what's
out of scope, how they'd know it worked, and what the load-bearing
claim was verified to do?** If any of those five is fuzzy, the PRD
isn't done.

## What "done" means for a PRD-driven build

Every PRD in this repo is delivered by the executing agent, not
handed back to Glenn for a manual finish. "Done" is not "code
compiles" or "tests pass" — those are steps along the way. Done
means:

1. **All code committed on `main`.** No feature branches. Multiple
   small commits are fine; leftover unstaged changes are not.
2. **`xcodebuild ... test` runs green** with the new tests included.
3. **The app launches**, the feature works as described in the PRD,
   and no existing interaction regressed (pan smoothness, live
   slider preview, undo/redo, history panel).
4. **`git status` clean.** No modified files, no untracked scratch,
   no unstaged debug prints. Anything you touched is either
   committed or reverted — deliberately, not forgotten.

If any of these four is untrue, the PRD is *in progress*, not done.
State it plainly in the reply — do not describe a build as
"shipped" or "complete" while a diff still sits in the working tree.
