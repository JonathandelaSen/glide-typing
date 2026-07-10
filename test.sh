#!/bin/zsh
# Runs the GlideBoard checks (plain executable runner: the CommandLineTools
# toolchain has no XCTest). Must run from the repo root so word lists in
# Resources/ resolve via cwd.
set -e
cd "$(dirname "$0")"
swift run GlideBoardChecks
