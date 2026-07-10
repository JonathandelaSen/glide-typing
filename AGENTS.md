# GlideBoard agent instructions

## Build version

After every code change, increment `BuildVersion.code` in
`Sources/GlideBoardCore/BuildVersion.swift` before building. The value is
displayed as `v<N>` in the macOS status bar, so it identifies the exact build
currently running.
