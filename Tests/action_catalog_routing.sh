#!/bin/zsh
# Contract: every UI surface (status menu, global hotkeys, board button,
# palette) routes through the shared action catalog. No duplicate path may
# call the underlying features directly, and push-to-talk must keep its
# press/release semantics through the catalog.
set -euo pipefail

repo_root="${0:A:h:h}"
app="$repo_root/Sources/GlideBoardCore/AppDelegate.swift"

fail() { echo "action_catalog_routing: $1" >&2; exit 1 }

# The hands-free toggle reaches the coordinator from exactly one site: the
# catalog executor. A second call site is a bypass.
count=$(grep -c "toggleHandsFree(source:" "$app")
[ "$count" -eq 1 ] || fail "toggleHandsFree called from $count sites; expected 1 (the executor)"

# Status-menu selectors delegate to runAction (the catalog).
for selector in menuToggle menuTogglePalette menuToggleAttention \
                menuFocusComposer menuTransform menuSendComposer menuDictation; do
  grep -A1 "func $selector" "$app" | grep -q "runAction" \
    || fail "$selector bypasses the action catalog"
done

# The board's dictation button also routes through the catalog.
grep -A1 "func keyboardViewDidToggleDictation" "$app" | grep -q "runAction" \
  || fail "the board dictation button bypasses the action catalog"

# Push-to-talk press/release goes through the catalog, never one-shot execute.
grep -q "actionCatalog.pressPushToTalk" "$app" \
  || fail "push-to-talk press path bypasses the catalog"
grep -q "actionCatalog.releasePushToTalk" "$app" \
  || fail "push-to-talk release path bypasses the catalog"

# The double-Option monitor observes without consuming (Option must keep
# producing symbols and shortcuts) and stays separate from KeyInterceptor.
monitor="$repo_root/Sources/GlideBoardCore/DoubleOptionMonitor.swift"
grep -q "listenOnly" "$monitor" || fail "double-Option tap is not listen-only"
grep -q "KeyInterceptor(" "$monitor" && fail "double-Option monitor entangled with Tab interception"

echo "action_catalog_routing: OK"
