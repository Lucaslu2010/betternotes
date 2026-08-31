# BetterNotes

An iPadOS/iOS notes app built on PencilKit — handwriting, lasso selection,
imported PDFs, and BYOK AI assistance. SwiftUI + SwiftData, ~16k lines.
There is no cloud sync; it was removed deliberately (commit `002477c`).

Deadlines: **feature-complete 30 Sep 2026, App Store 31 Oct 2026.**

## Project file

`BetterNotes.xcodeproj` is **generated**, not hand-edited:

```
python3 generate_project.py        # rewrites project.pbxproj from the source tree
```

`project.yml` is the XcodeGen-style spec of record for settings (deployment
target, Info.plist keys, signing). Add a source file and regenerate; do not
edit `project.pbxproj` by hand.

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

`PageEditorView` stacks, bottom to top: `PageBackground` → `ElementOverlay` →
`PaperCanvas` → `TapeDisplayLayer` (hit-testing off) → `UnifiedLassoOverlay`
(only when `tool == .lasso`) → `SelectionHandles`.

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
