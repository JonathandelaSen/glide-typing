# GlideBoard

Full instructions in [AGENTS.md](AGENTS.md). Non-negotiables:

- Increment `BuildVersion.code` before every delivered build; the app is
  relaunched manually by the user.
- Tests: `./test.sh` (custom runner, no XCTest). On refactors, contract tests
  are migrated, never rewritten.
- Panels are `nonactivatingPanel`: the target field must keep AX focus.
  Never activate the app to fix a focus problem.
