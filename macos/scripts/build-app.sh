#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Motor Studio.app 必须在 macOS 上构建。协议测试可在 Linux 运行：swift test。' >&2
  exit 1
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
  echo '请使用 Xcode 26 或更新版本，以编译系统 Liquid Glass API。' >&2
  exit 1
fi

# Default: native host architecture. --universal builds both Apple Silicon and Intel.
if [[ "${1:-}" == --universal ]]; then
  architectures=(arm64 x86_64)
elif [[ $# == 0 ]]; then
  architectures=("$(uname -m)")
else
  echo '用法：bash scripts/build-app.sh [--universal]' >&2
  exit 1
fi
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  echo '当前仅安装 Command Line Tools：执行原生模型/采样测试；XCTest 协议测试需完整 Xcode。'
else
  xcrun swift test
fi
bash scripts/test-native-runtime.sh
binaries=()
for arch in "${architectures[@]}"; do
  scratch="$project_dir/build/$arch"
  xcrun swift build -c release --product MotorStudio --arch "$arch" --scratch-path "$scratch"
  bin_dir="$(xcrun swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)"
  binaries+=("$bin_dir/MotorStudio")
done

app="$project_dir/dist/Motor Studio Performance.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ ${#binaries[@]} -eq 2 ]]; then
  xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/MotorStudio"
else
  cp "${binaries[0]}" "$app/Contents/MacOS/MotorStudio"
fi
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/../LICENSE" "$app/Contents/Resources/LICENSE"
cp "$project_dir/README.md" "$app/Contents/Resources/README.md"
cp "$project_dir/PROTOCOL.md" "$app/Contents/Resources/PROTOCOL.md"
cp "$project_dir/PRIVATE-PROTOCOL.md" "$app/Contents/Resources/PRIVATE-PROTOCOL.md"
cp "$project_dir/VALIDATION.md" "$app/Contents/Resources/VALIDATION.md"
xcrun swift "$project_dir/scripts/make-icon.swift" "$project_dir/build/MotorStudio.iconset"
iconutil -c icns "$project_dir/build/MotorStudio.iconset" -o "$app/Contents/Resources/MotorStudio.icns"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$project_dir/dist/Motor-Studio-Performance-macOS.zip"
echo "已生成：$app"
echo '这是本地 ad-hoc 签名，尚未进行 Developer ID 签名及 Apple 公证。'
