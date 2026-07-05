#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sources="$repo_root/Sources/GlideBoard"

if [ -e "$sources/EvalWorkspace.swift" ]; then
    echo "EvalWorkspace.swift still enables live eval generation" >&2
    exit 1
fi

if grep -En 'evalExporter|evalSink|evalCaptureEnabled' \
    "$sources/AppDelegate.swift" \
    "$sources/CompletionProvider.swift" \
    "$sources/Settings.swift"
then
    echo "GlideBoard still wires live eval generation into typing" >&2
    exit 1
fi
