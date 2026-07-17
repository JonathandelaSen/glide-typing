---
description: Bump BuildVersion, run all tests and build the app ready for manual relaunch
---

Prepare a deliverable build:

1. Increment `BuildVersion.code` in `Sources/GlideBoardCore/BuildVersion.swift` (+1).
2. Run `./test.sh` from the repo root. If any check fails, stop here and
   report the failure — do not build.
3. Run the shell contract tests (same rule: any failure stops the process):

   ```zsh
   for t in Tests/*.sh; do
     case $(basename $t) in
       numa_live_metrics.sh) continue;;          # needs the running app's PID
       numa_privacy_contract.sh) args=--static;;
       *) args=;;
     esac
     zsh "$t" $args
   done
   ```

4. Run `./build.sh`.
5. Report the new version (`v<N>`) and remind the user to relaunch the app
   manually. Do not launch or kill it yourself.
