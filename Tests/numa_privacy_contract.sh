#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--static" ]]; then
  echo "usage: $0 --static" >&2
  exit 2
fi

engine_count=$(rg -l 'AVAudioEngine\(' Sources/GlideBoardCore -g '*.swift' | wc -l | tr -d ' ')
[[ "$engine_count" == "1" ]]
rg -q 'AVAudioEngine\(' Sources/GlideBoardCore/MicrophoneCaptureService.swift

tap_count=$(rg -l 'installTap\(' Sources/GlideBoardCore -g '*.swift' | wc -l | tr -d ' ')
[[ "$tap_count" == "1" ]]
rg -q 'installTap\(' Sources/GlideBoardCore/MicrophoneCaptureService.swift

numa_files=(
  Sources/GlideBoardCore/AudioFrame.swift
  Sources/GlideBoardCore/AudioRingBuffer.swift
  Sources/GlideBoardCore/MicrophoneCaptureService.swift
  Sources/GlideBoardCore/NumaAudioExecutor.swift
  Sources/GlideBoardCore/NumaAudioPipeline.swift
  Sources/GlideBoardCore/NumaCoordinator.swift
  Sources/GlideBoardCore/VoiceAttentionRecognizer.swift
)
if rg -n 'AVAudioFile|FileHandle|\.write\(to:|Data\.write|URLSession|NWConnection' "${numa_files[@]}"; then
  echo "Numa attention must not persist audio or open its own network transport" >&2
  exit 1
fi

if rg -n 'NSLog|print\(' Sources/GlideBoardCore/VoiceAttentionRecognizer.swift Sources/GlideBoardCore/NumaCoordinator.swift; then
  echo "Attention transcripts or recognizer output must not be logged" >&2
  exit 1
fi

echo "PASS numa privacy static contract"
