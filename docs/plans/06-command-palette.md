# Plan 06 — Global Command Palette

**Status: implemented (2026-07-16, build v34), pending manual verification.**
Implemented standalone, ahead of Workspace Profiles and independent from it:
profile actions will join the catalog after Plan 05 ships. Checkpoint 5's
manual verification (double-Option reliability, focus restoration, Option
typing) is still owed by a live session.

## Outcome

Replace the floating keyboard as Numa's primary entry point with a fast global
action palette. The Board remains a specialized writing and preview surface,
not the container for every feature.

Invoke the palette by tapping Option twice, search deterministic actions, and
execute with the keyboard. Voice, global shortcuts, the status menu, and the
palette all route to the same action catalog.

## Confirmed product decisions

- Numa is a local personal intent and Mac-control layer. The Board is one
  capability inside it.
- The palette is the primary UI. The status menu remains responsible for state
  and settings.
- Invocation is a clean double tap of Option.
- The palette is deterministic and action-first. Free-form natural language is
  available only through an explicit action such as `Ask Numa`.
- The first palette release exposes existing capabilities only. It does not
  implement TTS, Workspace Profiles, or another new vertical.
- Every action may have an optional global shortcut.
- Global shortcuts are configured only in Settings.
- No action receives a default global shortcut in this iteration.
- A palette row displays shortcut keycaps only when the user configured one.
- A palette row displays a voice icon only when the action has an associated
  voice phrase.
- Hovering the voice icon reveals the full phrase in a tooltip so long commands
  do not consume row width.
- No voice commands are added merely to fill the palette.
- The visual quality must be substantially above a utility list: strong Numa
  identity, clear context, polished selection states, restrained motion, and
  fast metadata scanning.
- There is no automatic feature removal rule based on usage.

## Initial action catalog

The exact catalog is built from existing behavior at implementation time. The
initial target includes:

- Open or hide the Board.
- Focus the Board composer.
- Start or stop hands-free dictation.
- Start push-to-talk through its existing press/release path.
- Transform selected/focused text.
- Send the Board draft.
- Pause or resume Numa attention.
- Open Settings.

Workspace profile actions join only after Plan 05 ships. TTS joins only after a
real TTS capability exists.

## Interaction contract

### Double-Option launcher

- Observe complete Option press/release cycles.
- Open after the second clean release inside a short configurable constant
  window, initially around 400 ms.
- Cancel the sequence when another key or mouse click occurs.
- Ignore key repeat and a held Option key.
- Never consume Option events, so normal symbols and shortcuts continue to work.
- Allow the feature to be disabled in Settings and preserve a conventional
  fallback invocation.

Carbon `RegisterEventHotKey` cannot express a modifier-only gesture. Extend the
existing event-tap infrastructure to observe `flagsChanged`, isolated from
Tab interception and existing global shortcuts.

### Palette behavior

- Open as a transient nonactivating panel without converting Numa into a normal
  activating app.
- Preserve the AX target and previous external app.
- Focus search immediately within the existing nonactivating-panel constraints.
- Filter by title, aliases, and keywords.
- Rank available/contextual actions first, then recent actions, while keeping
  deterministic results for the same state.
- Navigate with Up/Down, execute with Return, and close with Escape or another
  double Option.
- Show the current target context when it is safe and useful.
- Open the Board only when an action needs editing or preview.
- Restore focus to the previous app after closing or executing an action that
  does not intentionally change focus.

## Action model

Introduce an action catalog independent from UI:

### `NumaActionDescriptor`

- Stable action ID.
- User-visible title and subtitle.
- Search aliases and keywords.
- Symbol name.
- Category.
- Availability provider.
- Execution policy.
- Optional configured global shortcut.
- Optional configured voice phrase.

### `NumaActionExecuting`

- Execute the action.
- Return a typed result: completed, opened surface, unavailable, failed, or
  requires confirmation.
- Never reach into palette views.

### `NumaActionCatalog`

- Own the stable descriptor list.
- Resolve availability from current Numa state.
- Route all surfaces to the same action executor.
- Allow Workspace Profiles and future verticals to register actions without
  coupling their domain services to the palette.

## Settings

Add an Actions/Shortcuts surface that:

- Lists every catalog action.
- Records or clears an optional global shortcut.
- Starts with every new catalog shortcut unset.
- Detects conflicts with other Numa actions before saving.
- Shows the associated voice phrase read-only or routes to the existing voice
  command editor where applicable.

The palette never acts as a shortcut editor. An unconfigured row simply omits
shortcut metadata; it does not display `No shortcut` or an add button.

## Delivery sequence

### Checkpoint 0 — Contracts and baseline

- Preserve the dirty worktree and run the existing checks.
- Specify action IDs and map each existing UI/menu path to one action.
- Add pure tests for double-Option timing and cancellation.

### Checkpoint 1 — Shared action catalog

- Add descriptors, availability, typed results, and executors.
- Route existing status-menu actions through the catalog without changing
  behavior.
- Preserve push-to-talk press/release semantics.

### Checkpoint 2 — Double-Option monitor

- Extend event-tap observation safely.
- Verify normal Option typing and all current shortcuts remain unchanged.
- Add timeout, interruption, repeat, disable/re-enable, and tap-recovery checks.

### Checkpoint 3 — Palette panel

- Build search, ranking, keyboard navigation, execution, and focus restoration.
- Implement shortcut keycaps and voice tooltips from real descriptor metadata.
- Polish the visual hierarchy and motion without adding new capabilities.

### Checkpoint 4 — Optional shortcut settings

- Add per-action optional shortcut persistence.
- Register only configured shortcuts.
- Keep every new action unset by default.
- Detect and explain conflicts.

### Checkpoint 5 — Verification

- Open and close repeatedly with double Option.
- Search and execute every existing action.
- Verify the AX target survives palette use.
- Verify normal Option symbols and shortcuts are unaffected.
- Verify empty shortcut slots render no metadata.
- Verify long voice commands appear only through the icon tooltip.
- Verify unavailable actions explain why they cannot run.
- Verify no duplicate path bypasses the action catalog.

## Verification contract

- Add checks to `Tests/GlideBoardChecks/`; do not add XCTest.
- Preserve and migrate existing contract tests for hotkeys, composer focus,
  dictation, and Numa privacy.
- Run `./test.sh` plus relevant shell contracts.
- Increment `BuildVersion.code` before every user-facing build after code
  changes.
- Agents never launch or kill Numa; the user performs the final manual relaunch
  and UI validation.

## Success criteria

- Double Option opens the palette reliably without breaking Option input.
- Existing actions behave exactly as before when invoked through the catalog.
- The palette is fully usable by keyboard.
- The previous external app and AX text target are restored correctly.
- Optional shortcuts and voice metadata are truthful and never invented.
- A future vertical can add actions without changing the palette's search or
  execution core.

