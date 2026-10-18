# Update history

This history records changes in the [Lucaslu2010 BetterNotes fork](https://github.com/Lucaslu2010/betternotes).
Entries describe the code in the branch; validation is recorded separately from implemented behavior.

## 2026-10-18 — Folders, document imports, and handwriting interactions

Compared with [`a13d6ae`](https://github.com/Lucaslu2010/betternotes/commit/a13d6ae2e0bb09165cbeaac8655b1a137fceef6a), the previous published update.

### Before and after

| Area | Previous code | This update |
| --- | --- | --- |
| Library folders | Folder membership came from notebook folder-name strings. | Persistent folder records preserve empty folders and support nested locations, folder tiles, breadcrumbs, and notebook drag-and-drop. |
| Document opening | PDF and backup imports used separate existing paths. | A shared document importer handles supported PDFs, images, and BetterNotes backups, including incoming file URLs and explicit destination selection. |
| Handwritten questions | A leading `??` marker opened an assistant question draft. | Leading or trailing markers show an inline confirmation prompt. Only Answer opens the assistant and submits the recognized question. |
| Scribble erasing | No scratch-out eraser setting or recognition pipeline. | Scribble to Erase recognizes repeated scratch passes over existing ink, with a setting to disable it and undo support. |
| Zoomed handwriting | Rendering adjustments changed scale factors through the view hierarchy. | PencilKit receives the actual zoom while page coordinates stay stable; bounded viewport rasters provide settled-ink rendering. |
| Lasso interaction | Mode selection was separate, and selection transforms rebuilt drawing state during dragging. | The first tap activates the saved mode; another tap opens mode choices. Drag previews defer the transformed drawing commit until the gesture ends. |
| Autosave feedback | Successful saves briefly showed a saving indicator. | Successful autosaves are silent; failures retain the save badge and Retry action. |

### Emergency follow-up — Folder actions and state consistency

- Add a folder ellipsis menu with Favorite, Archive, Rename, Customize Colour, and Move to Trash; persist folder colors and favorite state.
- Include folders in Favorites, Archive, and Trash, with navigation into archived folder containers.
- Rename a folder and all descendant paths/notebook memberships in one save, without changing similarly prefixed sibling folders. Reject conflicting names and restore prior values if saving fails.
- Inherit archive state from ancestor folders while preserving each notebook's own archive flag. Apply the effective state to search indexing, assistant filtering, and notebook navigation.
- Trash live descendants together with their folder. Restore only the notebooks deleted by that operation, preserving earlier independent notebook or subfolder deletions across relaunches.
- Include folder contents in Empty Trash and the existing 30-day retention cleanup. Reject imports, child creation, and drops into unavailable archived or trashed folders.
- Extend document regression tests for recursive rename, inherited archive state, and persistent folder trash/restore behavior.

### Library and document support

- Add `NotebookFolder` persistence, nested folder paths, validation, and recovery of legacy memberships and missing ancestor folders.
- Show only the current location's immediate notebooks and folders. Add root/parent navigation and a folder creation button beside New Notebook.
- Add typed notebook drag payloads, native lift previews, and drop targets on folder tiles, breadcrumbs, and sidebar folders. Validate destinations and save membership changes atomically.
- Queue incoming file URLs and ask where to save each document before importing. Cancelling the destination picker creates no notebook.
- Support PDF, `.betternotes` backups, JPEG, PNG, HEIC, HEIF, TIFF, GIF, BMP, and WebP. Word, Excel, PowerPoint, and plain-text import are not supported by this importer.
- Keep imported PDF/image artwork locked for annotation and preserve extracted PDF text separately from handwriting OCR. Image imports decode the first frame with a 3200-pixel edge cap.
- Avoid duplicate navigation identities when importing the same backup more than once; clean up failed imports rather than retaining partial notebooks.
- Register supported document types and the BetterNotes archive UTI through `project.yml` and the generated `Info.plist`.

### Handwriting, selection, and questions

- Add scratch-out recognition for repeated back-and-forth passes crossing existing strokes. Remove the scratch stroke with the crossed ink; include nearby detached punctuation while retaining unrelated writing.
- Keep blank-area scribbles as ink. Cancel pending automatic recognition while writing, and suppress automatic OCR/question detection for scratch gestures and lasso edits. Explicit recognition remains available.
- Add the Scribble to Erase toggle in Settings and the editor's handwriting menu.
- Keep lasso activation and mode changes responsive across single-page and vertical notebook layouts. Reserve one-finger drags for lasso selection; use two fingers to pan.
- Use cached selection previews while moving, resizing, and rotating, then commit the transformed drawing once, including when leaving a page or switching tools.
- Bound settled-ink viewport rasters to 6 megapixels and 4096 pixels per edge. Serialize/coalesce rendering work and reject stale results.
- Recognize `??` at either end of a handwritten line, including full-width question marks. Join OCR observations on the same row and retry the recent row locally when small punctuation is missed.
- Show recognition progress, errors, Retry, Answer, and Not now in an inline prompt without automatically presenting the assistant or focusing a text field.
- Fingerprint question-region stroke content rather than drawing-archive identity. Preserve a pending question when writing elsewhere and capture current ink when retrying.
- Restore the normal app's saved preferences after a UI-testing launch instead of leaving test-pinned settings behind.

### Regression coverage and validation

- Add `DocumentSupportTests` for persistent folders, hierarchy, moves, actual file imports, invalid files, backup collisions, and built-bundle document declarations.
- Add `InkInteractionTests` for scratch recognition, punctuation, saved lasso modes, viewport geometry, selection previews, and pen-lift behavior.
- Extend `OCRPipelineTests` for suffix markers, split punctuation, full-width crops, inline confirmation, stable fingerprints, unrelated writing, and retries.
- Extend UI regression coverage for the changed library and editing flows.
- Validation: 52 focused simulator tests passed, 0 failed, and 0 skipped across `DocumentSupportTests`, `InkInteractionTests`, and `OCRPipelineTests` on iPad Air 13-inch (M3), iOS 26.3.1, with simulator signing enabled. The app and test targets compiled successfully. Staged whitespace and secret checks passed. Physical Apple Pencil/gesture testing and the full UI suite were not run for this publication.

## 2026-10-17 — Configurable OCR and notebook editing

Published in [`a13d6ae`](https://github.com/Lucaslu2010/betternotes/commit/a13d6ae2e0bb09165cbeaac8655b1a137fceef6a), compared with upstream commit [`686d92c`](https://github.com/kenny-21342/betternotes/commit/686d92cc5941b6b3c211bbf33aba2e12b94a4004).

- Add on-device and custom OCR providers, including synchronous PaddleOCR and OpenAI-compatible vision endpoints.
- Store OCR credentials separately in Keychain; test draft provider settings without replacing saved configuration.
- Bound OCR image preparation and provider response sizes, support cancellation, and avoid uploading unchanged content repeatedly.
- Separate native PDF text from handwriting OCR and preserve existing text after failed or stale recognition.
- Add handwritten question drafts, recognition progress, failure handling, retries, and dismissal cancellation.
- Improve Apple Pencil double-tap tool switching, pen-lift finalization, shared vertical notebook zoom, and navigation/presentation state.
- Add memory diagnostics, regression tests, generated-project entries, and Debug development signing settings.
- Validation at publication: simulator build-for-testing passed for the app and both test bundles; staged secret scanning passed. Runtime tests were not run for that publication.
