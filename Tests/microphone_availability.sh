#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Foundation

do {
    try requireMicrophoneInput(deviceCount: 0)
    preconditionFailure("A machine without audio inputs must be rejected before AVAudioEngine starts")
} catch {
    precondition(error.localizedDescription == "No hay ningún micrófono disponible")
}

do {
    try requireMicrophoneInput(deviceCount: 1)
} catch {
    preconditionFailure("A detected input device should be accepted: \(error)")
}
SWIFT

swiftc \
    "$repo_root/Sources/GlideBoardCore/MicrophoneAvailability.swift" \
    "$work_dir/main.swift" \
    -o "$work_dir/microphone-availability"

"$work_dir/microphone-availability"
