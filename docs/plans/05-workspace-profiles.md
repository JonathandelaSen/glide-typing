# Plan 05 — Workspace Profiles

**Status: active.** This is an independent product track and does not depend on
the text-injection roadmap in plans 01–04. The first deliverable targets the
currently connected single-display setup. Command-palette integration, voice
commands, automatic login application, and multi-display support are later
deliverables.

## Outcome

Save the current arrangement of apps and windows across pre-existing macOS
Spaces as a named profile, then restore that profile reliably from Numa's
status menu.

The first real profile is captured from this six-Space layout:

1. Spotify + OrbStack
2. Antigravity IDE
3. ChatGPT + Claude
4. Brave A
5. Brave B
6. Finder

The capture is authoritative for window frames and stacking. The plan must not
invent tiling or overlap rules from the list above.

## Confirmed product decisions

- Profiles are user-defined. They are not generated from the display count.
- More than one profile may target the same display configuration, such as
  `Work` and `Browsing`.
- A profile is bound to the exact physical displays captured, their effective
  resolutions, rotations, relative arrangement, and primary-display choice.
- A changed display configuration never auto-matches merely because it has the
  same number of displays. The user may duplicate and recapture a profile for
  the new configuration.
- Multi-display profiles require independent Spaces per display. Numa checks
  this setting but never changes it silently.
- Spaces must already exist. Numa does not create, delete, or reorder them.
- Automatic Space reordering must be disabled. Numa checks and reports the
  prerequisite.
- Profile creation is capture-first. Numa scans every existing Space, returns
  to the original Space and focused app, previews the result, and saves only
  after confirmation.
- Applying a profile is best-effort. One failed window does not roll back the
  successful windows.
- Each application reports its result and may be retried individually.
- Applying a profile creates one temporary undo snapshot. Undo restores moved
  windows but never closes applications Numa launched.
- Extra windows are never closed, minimized, or moved. They are reported and
  left untouched.
- Required windows are unminimized. Native fullscreen and Split View are out of
  scope; normal windows may fill the usable screen frame.
- Window stacking is captured and restored as best effort. The captured front
  window is raised last within its Space.
- Profiles manage apps, windows, displays, Spaces, frames, and stacking only.
  They do not manage browser tabs, URLs, IDE projects, terminal directories,
  commands, or conversations.
- Brave windows are interchangeable slots named `Brave A`, `Brave B`, and so
  on. Tab titles and transient window IDs are not identity.
- Missing applications are launched. Missing windows are created only through
  an explicit, tested recipe for that application.
- Reapplying a profile is idempotent and never creates duplicate windows.
- The first deliverable includes launching missing applications and creating
  missing windows. These are not postponed to a separate release.
- No profile voice commands are added in this version.
- No default global shortcuts are assigned.
- The initial control surface is a `Workspace Profiles` submenu in Numa's
  status menu. The future command palette will reuse the same actions.

## First-deliverable boundary

The first deliverable ships all of the following together:

- Capture and persist a named single-display profile across six Spaces.
- Preview a capture before saving it.
- Apply a saved profile manually.
- Launch missing applications.
- Create missing windows using app-specific recipes.
- Restore display, Space, frame, and stacking order.
- Preserve extra windows.
- Produce a per-window result summary with retry.
- Reapply without duplication.
- Undo the latest application.
- Rename, inspect, update, exclude windows from, and delete profiles.
- Access the workflow from the status menu.

The first deliverable does not include:

- Applying a default profile at login.
- Automatically applying a profile when displays connect or disconnect.
- A multi-display profile.
- Creating or deleting Spaces.
- Native fullscreen or Split View.
- Voice commands.
- Command-palette integration.
- A drag-and-drop visual profile editor.

## Platform strategy

Public APIs remain the default:

- `NSScreen` for current display topology and usable frames.
- `NSWorkspace` for installed/running apps and launching by bundle ID.
- Accessibility for enumerating, raising, minimizing, moving, and resizing app
  windows.
- `CGWindowListCopyWindowInfo` only where a Core Graphics window ID is required
  and the result can be matched safely to an Accessibility window.

Space enumeration and assignment use a narrowly isolated private adapter. The
current macOS 26.5.1 machine exposes these symbols:

- `CGSMainConnectionID`
- `CGSCopySpaces`
- `CGSGetWindowWorkspace`
- `CGSMoveWindowsToManagedSpace`
- `CGSManagedDisplayGetCurrentSpace`

They must be resolved dynamically at runtime. Missing or changed symbols disable
workspace capture/application with a useful diagnostic; they must never crash
Numa or affect its existing features.

The private adapter owns no launch, matching, geometry, persistence, or UI
logic. It implements only the minimal `SpaceManaging` contract.

### Platform reality (verified live, 2026-07-18/19)

Live probing on macOS 26.5.1 corrected the strategy above; evidence in
`docs/plans/evidence/` and `docs/experiments/space-spike/`:

- Every CGS mutation API is dead for other apps' windows from a normal
  process: `CGSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, and the
  compat-ID shim are silent no-ops (the legacy call returns notImplemented).
  They still work for a process's own windows, which is why the original
  spike passed.
- `CGSManagedDisplaySetCurrentSpace` updates CGS state without switching the
  visible Space, and `GetCurrentSpace` echoes the lie while idle.
- Synthetic Ctrl+Arrow events never trigger Mission Control shortcuts; app
  level synthetic keys and mouse drags do work.
- Accessibility exposes only the ACTIVE Space's windows per app (plus
  minimized ones); `CGWindowListCopyWindowInfo(.optionAll)` sees every
  window, and the adapter's per-window Space query is precise. The
  on-screen-only list keeps reporting a previous Space's windows for over a
  second after a switch and must never be used for capture.
- The private adapter therefore stays read-only (enumeration and queries),
  and all mutation is done through real user gestures, verified after every
  step: Space switching clicks the expanded Mission Control Spaces bar
  (Dock's AX tree exposes live space buttons and their frames), and
  cross-Space moves drag the real title bar against the screen's boundary
  pixel until the Space slides. Capture is traversal-free (CG-primary).

## Profile model

Persist a versioned JSON document under GlideBoard's existing Application
Support directory. The visible product name is Numa, but the internal support
directory remains `GlideBoard`.

### `DisplayConfigurationSignature`

- Physical display fingerprint.
- Effective frame and visible frame.
- Rotation.
- Relative origin.
- Primary-display flag.
- Whether displays use independent Spaces.

The fingerprint should prefer stable vendor, product, and serial information
when macOS exposes it. A transient `CGDirectDisplayID` is runtime identity, not
the only persisted identity.

### `WorkspaceProfile`

- Stable profile ID.
- User-visible name.
- Captured display signature.
- Ordered window rules.
- Creation and last-update timestamps.
- Schema version.

Profiles store Space ordinals per display, not raw private Space IDs. Private
IDs are resolved again for the current login session.

### `WorkspaceWindowRule`

- Application bundle ID.
- User-visible slot name.
- Display role and fingerprint.
- Space ordinal.
- Frame normalized to the display's visible frame.
- Captured stacking rank.
- AX role/subrole hints where useful.
- Window-creation recipe ID, if supported.

Titles may be stored as diagnostic hints, never as the sole identity for Brave
or another window whose title follows mutable content.

### `WorkspaceUndoSnapshot`

- Only windows Numa intends to move.
- Original Space, display, frame, minimized state, and stacking rank.
- In-memory/session-scoped lifetime.
- Replaced by the next apply operation and cleared on logout or termination.

## Components

Keep one component per file under `Sources/GlideBoardCore/`.

- `DisplayConfigurationResolver`: fingerprints and compares display setups.
- `SpaceManaging`: narrow protocol for Space enumeration and window assignment.
- `CGSSpaceManager`: runtime-loaded private implementation.
- `WorkspaceWindowCatalog`: maps running apps, AX windows, and CG window IDs.
- `WorkspaceCaptureService`: guided read-only capture across every Space.
- `WorkspaceProfileStore`: versioned local JSON persistence.
- `WorkspacePlanBuilder`: produces an explicit apply plan before mutation.
- `WorkspaceApplicationLauncher`: resolves and launches bundle IDs.
- `WorkspaceWindowRecipeRegistry`: creates missing windows through known recipes.
- `WorkspaceProfileExecutor`: applies the plan, verifies each rule, and reports
  partial failures.
- `WorkspaceUndoStore`: owns the latest reversible snapshot.
- `WorkspaceProfilesController`: status-menu and settings coordination.

The executor must not know about AppKit menu items. UI calls application
services; application services depend on the protocols above.

## Initial app inventory and recipes

The first single-display profile supports these installed bundle IDs:

| Slot | Bundle ID | Initial recipe |
| --- | --- | --- |
| Spotify | `com.spotify.client` | Launch; use the existing main window |
| OrbStack | `dev.kdrag0n.MacVirt` | Launch; use the existing main window |
| Antigravity IDE | `com.google.antigravity-ide` | Launch; use the existing main window |
| ChatGPT | `com.openai.codex` | Launch; use the existing main window |
| Claude | `com.anthropic.claudefordesktop` | Launch; use the existing main window |
| Brave A/B | `com.brave.Browser` | Launch and create normal windows until required slots exist |
| Finder | `com.apple.finder` | Activate Finder and create a normal window if none exists |

A generic fallback may launch any captured bundle ID. It must not synthesize a
generic `Command-N` for an application without a tested recipe.

## Status-menu and settings surface

Add a `Workspace Profiles` submenu with:

- Profile names: apply the selected profile.
- `Save Current Layout…`
- `Undo Last Apply` when a snapshot exists.
- `Manage Profiles…`

The first settings surface supports:

- Rename and delete.
- Inspect the captured display configuration and Spaces.
- Inspect application/window rules.
- Exclude a captured window.
- Choose the front window within a Space.
- Update a profile by recapturing the current layout.

Changing a frame or Space assignment is done by arranging the real windows and
recapturing. A visual layout editor is deferred.

## Delivery sequence

These are implementation checkpoints, not separately releasable product
versions. The first deliverable is complete only when all checkpoints pass.

### Checkpoint 0 — Baseline and reversible Space spike

- Record the dirty worktree and preserve all unrelated Numa changes.
- Run the existing `./test.sh` baseline.
- Resolve the private symbols dynamically.
- Enumerate the current display and ordered Spaces.
- Prove a disposable window can be mapped to a CG window ID, moved to another
  Space, verified, and returned to its original Space.
- Prove a missing symbol produces a disabled capability rather than a crash.

This is a blocking gate. Do not build the profile model on an unverified Space
mapping.

### Checkpoint 1 — Pure profile and planning core

- Add display signatures, profile/rule primitives, JSON schema, and migrations.
- Add deterministic compatibility and normalized-frame calculations.
- Build apply plans without mutating applications.
- Unit-check matching, duplicate prevention, and best-effort result aggregation
  in `GlideBoardChecks`.

### Checkpoint 2 — Guided single-display capture

- Preserve the original Space, app, and AX focus.
- Traverse all six pre-existing Spaces.
- Capture supported normal windows, geometry, and stacking.
- Return to the original state even after a partial capture failure.
- Preview and persist the profile.

### Checkpoint 3 — Apply, verify, and undo existing windows

- Build a preflight plan and undo snapshot.
- Move existing windows to their Space and frame.
- Unminimize required windows and restore stacking as best effort.
- Verify each final placement.
- Preserve and report extras.
- Reapply without changing the result or creating windows.
- Undo moved windows.

### Checkpoint 4 — Launch and create missing windows

- Add bundle-ID launching.
- Add the seven initial app recipes.
- Wait for app/window readiness with bounded timeouts.
- Reconcile Brave slots without using tab titles.
- Retry individual failed rules.
- Confirm a second apply creates no duplicates.

### Checkpoint 5 — Status menu and profile management

- Add capture, apply, retry, undo, rename, exclude, update, and delete flows.
- Keep every surface nonactivating where required by Numa's focus contract.
- Show explicit compatibility/prerequisite diagnostics.

### Checkpoint 6 — End-to-end verification

1. Arrange and capture the six-Space profile.
2. Move and resize several windows and move them to other Spaces.
3. Quit at least one supported app and remove one required Brave window.
4. Create at least one unrelated extra window.
5. Apply the profile.
6. Confirm every required window is restored and the extra is untouched.
7. Reapply and confirm there are no duplicates.
8. Undo and confirm moved windows return while launched apps remain open.
9. Force one recipe failure and confirm the remaining rules complete.
10. Restart Numa manually and confirm the profile persists.

## Verification contract

- Add pure checks to `Tests/GlideBoardChecks/`; do not introduce XCTest.
- Add targeted shell contract tests where source wiring or privacy boundaries
  need protection. Existing contract tests are migrated, never replaced.
- Run `./test.sh` from the repository root.
- Run relevant shell contracts separately because `./test.sh` does not run
  them.
- Increment `BuildVersion.code` before every user-facing build after code
  changes.
- Agents build but never launch or kill the app. The user performs relaunch and
  manual Space verification.

## Later deliverables

### Default profile at login

- Allow one optional default profile per exact display configuration.
- Wait for display topology and app session restoration to settle.
- Apply automatically only at login.

### Display changes during a session

- Detect a new compatible display configuration.
- Suggest a matching profile; never reorganize immediately.
- Let the user apply, ignore, or choose another compatible profile.

### Multi-display profiles

- Require `NSScreen.screensHaveSeparateSpaces == true`.
- Capture independent Space sequences per physical display.
- Validate the user's four-Space primary display and three-Space secondary
  display layout.

### Deferred integrations

- Command-palette actions.
- Optional per-profile global shortcuts configured in Settings, with no
  defaults.
- Optional voice commands with an explicit confirmation step.
- Visual drag-and-drop profile editing.

