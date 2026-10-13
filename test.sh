#!/bin/sh
set -eu
task_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$task_dir/build"
xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-function \
    -DDISPLAYCTL_TEST -framework Foundation -framework CoreGraphics -framework IOKit \
    "$task_dir/macDisplayCtl.m" -o "$task_dir/build/planning-tests"
for task_language in en zh-Hans; do
    MACDISPLAYCTL_LANGUAGE="$task_language" "$task_dir/build/planning-tests"
done
if [ -x "$task_dir/build/macDisplayCtl.app/Contents/MacOS/macDisplayCtl" ]; then
    for task_language in en zh-Hans; do
        env -u MACDISPLAYCTL_LANGUAGE "$task_dir/build/macDisplayCtl.app/Contents/MacOS/macDisplayCtl" --self-test -AppleLanguages "($task_language)"
    done
    codesign --verify --deep --strict "$task_dir/build/macDisplayCtl.app"
    python3 "$task_dir/tests/guard_install.py"
fi
python3 "$task_dir/tests/localization.py"
sh -n "$task_dir/macDisplayCtl" "$task_dir/macDisplayCtl-guard" "$task_dir/macDisplayCtl.command" "$task_dir/build-app.sh"
git -C "$task_dir" diff --check
