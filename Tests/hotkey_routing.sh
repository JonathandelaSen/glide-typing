#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Carbon

let signature = OSType(0x474C4244)
let registered = EventHotKeyID(signature: signature, id: 1)
let same = EventHotKeyID(signature: signature, id: 1)
let other = EventHotKeyID(signature: signature, id: 2)

precondition(hotKeyRoutingResult(registered: registered, pressed: same) == noErr)
precondition(hotKeyRoutingResult(registered: registered, pressed: other) == eventNotHandledErr)
precondition(hotKeyPhase(eventKind: UInt32(kEventHotKeyPressed)) == .pressed)
precondition(hotKeyPhase(eventKind: UInt32(kEventHotKeyReleased)) == .released)
precondition(hotKeyPhase(eventKind: UInt32(kEventRawKeyDown)) == nil)
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoardCore/HotKey.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/hotkey-routing"

"$work_dir/hotkey-routing"
