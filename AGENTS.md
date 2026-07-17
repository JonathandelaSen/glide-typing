# GlideBoard / Numa — agent instructions

macOS keyboard (glide typing + local dictation + "Numa" voice control).
Status-bar app (`LSUIElement`), not App Store distributed.

## Build and run

1. **Before every build handed to the user, increment `BuildVersion.code`**
   in `Sources/GlideBoardCore/BuildVersion.swift`. The value shows as `v<N>`
   in the status bar and is the only way to know which build is running.
2. `./build.sh` produces `build/GlideBoard.app` (release, app product only).
3. **The app is relaunched manually by the user** — agents must not launch
   or kill it.
4. Signing uses the stable "GlideBoard Signing" identity when present, so the
   Accessibility permission survives rebuilds. Do not change the signing.

## Tests

- `./test.sh` runs `GlideBoardChecks`, a plain executable runner
  (`swift run GlideBoardChecks`). **There is no XCTest** in the
  CommandLineTools toolchain; do not write XCTest tests.
- Must run from the repo root (word lists in `Resources/` resolve via cwd).
- The `.sh` files in `Tests/` are contract tests (greps and `swiftc`-compiled
  harnesses over source subsets): they validate integration invariants
  (hotkey routing, Numa privacy contract, etc.). **`./test.sh` does NOT run
  them** — run them separately (the `/ship` command does). Special cases:
  `numa_privacy_contract.sh` requires `--static`; `numa_live_metrics.sh`
  requires the PID of the running app.
- If a `swiftc` harness stops compiling because a type moved to another file,
  add the new file to its source list — do not rewrite the harness.
- **On refactors, contract tests are migrated, never rewritten from
  scratch.** A Numa refactor once broke push-to-talk precisely because the
  tests were rewritten instead of preserved. If a test gets in the way of a
  new design, that is a signal to review the design, not the test.

## Code style

- **No comments unless strictly necessary.** A comment must state a
  constraint the code itself cannot show; delete anything that narrates what
  the next line does.
- **All text is in English** — code, comments, docs, and user-facing UI
  strings. Existing Spanish UI strings are legacy: write new ones in English,
  and translate old ones only as a deliberate migration, not opportunistically
  while editing unrelated code.

## Focus gotcha (critical)

Every window in the app (`KeyboardView`, `NumaOverlay`, `DebugWindow`,
mini-menus) is a `[.borderless, .nonactivatingPanel]` panel: **the target
app's field must keep AX focus** while the panel is visible. Never turn a
panel into a regular window or activate the app to "fix" a focus problem —
it breaks text injection into the target app.

## Evals (`evals/`)

Live-capture workspace for phrase completion. Rules:

- A case is created only for a ghost actually shown to the user.
- Cases the user accepted are tagged as such.
- **Never generate synthetic/bootstrap cases** to pad the suites.

## Roadmap (`docs/plans/`)

Plans run in order (`01-transform-anywhere` → `04-snippets`). The **upfront
AX validation** (Notes/Mail/Slack/Chrome/Word/1Password matrix with QueryLog)
is a blocking gate before implementing the plans that inject text. Evidence
lives in `docs/plans/evidence/`.

## Layout

- `Sources/GlideBoardCore/` — all the logic (one file per component).
- `Sources/GlideBoard/` — executable entry point.
- `Tests/GlideBoardChecks/` — Swift checks + `Harness.swift` + `Main.swift`.
- `docs/experiments/` — experiments (e.g. wake word with WhisperKit).
