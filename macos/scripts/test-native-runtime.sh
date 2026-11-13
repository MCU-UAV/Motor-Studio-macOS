#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift build -c release --product MotorStudio --scratch-path build/native-runtime
bin_dir="$(xcrun swift build -c release --scratch-path build/native-runtime --show-bin-path)"
target_triple="$(uname -m)-apple-macosx14.0"
xcrun swiftc -swift-version 5 -parse-as-library -O -g scripts/test-native-runtime.swift \
  -target "$target_triple" \
  Sources/MotorStudio/{StudioModel,Sample,ChartMetric,AcquisitionEngine,RecordingStore,IndexedRecording,LiveReadout}.swift \
  -I "$bin_dir/Modules" -I "$bin_dir/CSerial.build" \
  "$bin_dir"/MotorCore.build/*.swift.o "$bin_dir/CSerial.build/Serial.c.o" \
  -framework IOKit -o build/native-runtime-tests
build/native-runtime-tests
