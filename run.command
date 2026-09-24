#!/bin/zsh
set -e
cd "$(dirname "$0")"
echo "Building MouseTrace..."
xcrun swiftc MouseTrace.swift -o MouseTrace -framework AppKit -framework CoreGraphics -framework IOKit
echo
echo "Starting. Log: $(pwd)/mouse-trace.log"
echo "If macOS asks, allow Terminal in Privacy & Security > Accessibility and Input Monitoring."
echo
./MouseTrace 2>&1 | tee -a mouse-trace.log
