#!/bin/sh
set -eu
task_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_app="$task_dir/build/macDisplayCtl.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -O2 -Wall -Wextra \
    -framework Foundation -framework CoreGraphics -framework IOKit \
    "$task_dir/macDisplayCtl.m" -o "$task_dir/build/macDisplayCtl"
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O -framework AppKit -framework SwiftUI -framework Carbon \
    "$task_dir/App/Localization.swift" "$task_dir/App/macDisplayCtl.swift" -o "$task_app/Contents/MacOS/macDisplayCtl"
cp "$task_dir/build/macDisplayCtl" "$task_app/Contents/Resources/macDisplayCtl"
cp "$task_dir/macDisplayCtl-guard" "$task_app/Contents/Resources/macDisplayCtl-guard"
cp -R "$task_dir/App/Resources/en.lproj" "$task_dir/App/Resources/zh-Hans.lproj" "$task_app/Contents/Resources/"
cp "$task_dir/App/Info.plist" "$task_app/Contents/Info.plist"
xcrun swift "$task_dir/App/MakeIcon.swift" "$task_dir/build/macDisplayCtl.iconset"
iconutil -c icns "$task_dir/build/macDisplayCtl.iconset" -o "$task_app/Contents/Resources/macDisplayCtl.icns"
chmod +x "$task_app/Contents/Resources/macDisplayCtl-guard" "$task_app/Contents/Resources/macDisplayCtl"
# Remove obsolete generated names when rebuilding an existing bundle.
rm -f "$task_app/Contents/MacOS/ScreenSwitch" \
    "$task_app/Contents/Resources/ScreenSwitch.icns" \
    "$task_app/Contents/Resources/displayctl" "$task_app/Contents/Resources/guardctl"
codesign --force --deep --sign - "$task_app"
printf 'Built: %s\n' "$task_app"
