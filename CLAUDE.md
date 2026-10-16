# BetterNotes

An iPadOS/iOS notes app built on PencilKit — handwriting, lasso selection,
imported PDFs, and BYOK AI assistance. SwiftUI + SwiftData, ~16k lines.
There is no cloud sync; it was removed deliberately (commit `002477c`).

Deadlines: **feature-complete 30 Sep 2026, App Store 31 Oct 2026.**

## Project file

`BetterNotes.xcodeproj` is **generated**, not hand-edited:

```
xcodegen generate                  # rewrites the project from project.yml
```

`project.yml` is the spec of record — targets, deployment target, Info.plist
keys, signing. Add a source file and regenerate; do not edit `project.pbxproj`
by hand.

Use **XcodeGen**, not the old `generate_project.py`, which was removed on
2 Sep 2026. That script only ever emitted the app target: running it dropped
the project from three native targets to one, deleted both test bundles, and
wrote an empty `<Testables>` into the scheme. The build still succeeded
afterwards, so nothing announced it — the next `xcodebuild test` simply
answered "Scheme BetterNotes is not currently configured for the test action".
XcodeGen reads `project.yml`, which has described all three targets the whole
time, and also picks up loose bundle resources such as `PrivacyInfo.xcprivacy`
that the script silently skipped.

`DEVELOPMENT_TEAM` sits in **project-level** settings, not on the app target.
A UI test runs from a second signed bundle and the unit tests from a third, so
setting it on the app alone lets the app install while `build-for-testing`
fails on signing.

## Testing

```
# fast loop — full suite, ~7 min
xcodebuild test -scheme BetterNotes \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)'

# trustworthy loop — one test on the real device, ~25-35s
xcodebuild test -scheme BetterNotes \
  -destination 'platform=iOS,id=00008103-000C290C1E28A01E' \
  -allowProvisioningUpdates \
  -only-testing:BetterNotesUITests/BetterNotesUITests/<name>
```

The iPad must be plugged in **and unlocked** — pairing drops while locked.

**Run targeted tests on device, never the whole suite.** A full UI run has sat
22 minutes on a single "wait for app to idle" without finishing one test. The
simulator runs everything in ~7 minutes but degrades after roughly a dozen
runs — hangs in the library flow, timeouts collecting diagnostics — so restart
it when runs start failing in places unrelated to your change.

**A simulator pass is not evidence for anything touching touch targets, gesture
routing or PencilKit.** Four such bugs survived a full green device run in Aug
2026 because no UI test drew a stroke; every one built its content from the
Insert menu instead.

## Writing tests that draw

Drawing is only reachable because of four things — keep them intact:

- Aim at `ink-canvas` (the `PKCanvasView`), not `page-canvas` (the zoomable
  scroll view wrapping it). A drag on the outer view is consumed as a pan and
  never reaches PencilKit.
- Do not hold at either end of the drag. The canvas runs a press-and-hold shape
  recogniser, and dwelling feeds that instead of laying down a stroke.
- `allowsFingerDrawing` is pinned on in the `-ui-testing` launch block. It is
  a user preference, so without pinning a drawing test passes in a fresh
  simulator and fails forever on a device where it has been switched off.
- Prove ink committed via the lasso finding a selection, not the Undo button —
  Undo's activation point is invalid on real hardware and `isHittable` throws.

Selection handles are addressable as `selection-handle-{tl,tr,bl,br,t,b,l,r}`;
drive the handle rather than a coordinate beside it.

## Editor architecture

Keep the library and notebook destinations under one `NavigationStack` with a
stable-ID path. The regular-width sidebar lives on the library root screen;
do not collapse a `NavigationSplitView` while pushing a notebook. Size-class
branches around navigation or presentation modifiers can recreate the editor
and dismiss settings during multitasking. The assistant uses one sheet
modifier, and provider forms push within Settings' navigation stack.
Load provider drafts once per presentation, not on every appearance.

Apple Pencil double tap has one `PencilDoubleTapInteraction` per notebook, not
per page. It switches the toolbar's tool binding through `PencilToolToggle`,
preserving the previous tool for the return tap. Settings appear on all iPads
with an Apple Pencil Pro compatibility label; iPadOS does not expose a public
connected-Pencil model API. Honor the system's disabled double-tap preference.

In vertical mode, one `ZoomablePageView` owns zoom and pan for the whole notebook.
`VerticalNotebookLayout` describes native page frames and the shared viewport.
Individual `PageEditorView`s set `managesOwnZoom: false`, locking their wrappers
to 1:1 so pinching scales page boxes and spacing together. Toolbar zoom commands
go to the outer view; page navigation scrolls to a native page rect. Keep ink and
selection geometry in page coordinates and convert the shared viewport for paste.

### OCR and handwritten questions

`HandwritingOCR` is always the local Apple Vision marker detector. A handwritten
line beginning with `??` immediately opens the assistant, including a bare marker.
The composer shows "Better OCR happening" until the selected provider returns the
question, then replaces that text. `EditorActionState` owns the task so presenting
the window cannot cancel it when the page view disappears. Dismissal cancels it;
errors stay in the question window with Retry. Sending remains explicit and is
disabled during recognition. Full note OCR refresh still happens when sending.
`OCRSettingsStore` defaults to on-device recognition and stores custom
OCR tokens in a separate Keychain service from the answering AI credentials.
`OCRService` reads content using the selected provider. Custom mode uploads only
for a detected question or an explicit assistant, Ask Notes, or handwriting-index
request, never for every drawing change. Ink/image fingerprints and provider
identities prevent unchanged content from being uploaded again.

PaddleOCR uses the **synchronous** `API_URL` and `TOKEN` from AI Studio's example:
JSON base64 `file`, `fileType: 1`, and `Authorization: token …`. Its endpoint
selects the model. Document-parsing Markdown and PP-OCR `rec_texts` responses are
supported. OpenAI-compatible vision OCR instead uses a full chat/completions URL,
a model name, and Bearer authentication. OCR settings include setup instructions
and a synthetic-image connection test that does not alter saved configuration.

Keep `Page.pdfText` separate from `Page.ocrText` (handwriting); search combines
both through `searchableOCRText`. Recognition failures and stale/cancelled requests
must not replace existing text. New OCR behavior has regression coverage in
`BetterNotesTests/OCRPipelineTests.swift`; provider calls are mocked.

OCR refresh uses a text-only image path, not `SmartImageExtractor.extract`,
which also builds full-resolution photo crops. `HandwritingOCR` serializes local
recognition and image preparation on one worker, cancels the active Vision
request, and drains temporary images in an autorelease pool per job. OCR bitmaps
are capped at 3200 pixels per edge and 6 megapixels; image inputs are downsampled
with ImageIO before decoding. Keep rendered images out of network-await scopes.
Paddle requests disable both visualization and Markdown images. OCR downloads
stop at 8 MiB before JSON parsing, and oversized uploads fail before Base64
encoding. The repeated OCR/provider regression logs physical memory on device.

`PageEditorView` stacks, bottom to top: `PageBackground` → `ElementOverlay` →
`PaperCanvas` → `TapeDisplayLayer` (hit-testing off) → `UnifiedLassoOverlay`
(only when `tool == .lasso`) → `SelectionHandles`.

Keep live ink in PencilKit until the pen-up callbacks settle. The coordinator
debounces finalization by 120 ms, cancels it on a new stroke, and waits for the
drawing gesture to finish before smoothing. Do not publish partial drawings
into SwiftData at touch rate or reassign an unchanged PencilKit tool on every
SwiftUI update. The tiled ink overlay is read-only; swapping it in on each
pen-up can display stale tiles over the newest stroke. Lifecycle regression
tests cover late commits, rapid next strokes, and tool changes during a stroke.

Two pieces of selection state, and both must move together:

- `selectedElementID` — the single element showing its own controls.
- `selectionState` — the lasso selection, and what gates the selection context
  bar. Clearing only the id leaves the bar on screen over nothing.

`refreshSelectionBounds()` is what reconciles them after content changes. Call
it whenever elements are added or removed; forgetting it leaves dead ids in the
bounds.

`UnifiedLassoOverlay` covers the **entire page** with a drag gesture, so any
touch that misses a control above it is read as the start of a new selection
and throws the current one away. That makes touch-target size a correctness
concern here, not a polish one.

## SwiftUI gotchas that have bitten this codebase

- **Hit-testing is clipped to a view's own frame.** `contentShape` inset
  outward is silently ignored. To enlarge a touch target, grow the frame.
- **`.offset` is a rendering transform.** It moves pixels and hit-testing but
  leaves the layout frame behind, and the stale frame is what the accessibility
  system publishes — so VoiceOver, Switch Control and XCUITest all aim at the
  wrong place. Use `.position` for anything that must be reachable.
- Element positions (`posX`/`posY`) are **centres**, not origins.
