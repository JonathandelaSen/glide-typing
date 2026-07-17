#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Carbon

UserDefaults.standard.removeObject(forKey: "focusHotKeyCode")
UserDefaults.standard.removeObject(forKey: "focusHotKeyModifiers")

precondition(Settings.focusHotKeyCode == UInt32(kVK_ANSI_G))
precondition(Settings.focusHotKeyModifiers == UInt32(cmdKey | optionKey | shiftKey))
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoardCore/KeyboardLayout.swift" \
    "$repo_root/Sources/GlideBoardCore/EmojiCatalog.swift" \
    "$repo_root/Sources/GlideBoardCore/Settings.swift" \
    "$repo_root/Sources/GlideBoardCore/VoiceCommands.swift" \
    "$repo_root/Sources/GlideBoardCore/NumaSoundPlayer.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/focus-shortcut-settings"

"$work_dir/focus-shortcut-settings"
