#!/bin/sh
set -eu
task_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$task_dir/macDisplayCtl.command" "$@"
