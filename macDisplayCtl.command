#!/bin/sh
set -eu
task_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tool="$task_dir/macDisplayCtl"
task_language=$("$tool" language)
message() {
    if [ "$task_language" = zh-Hans ]; then printf "$1"; else printf "$2"; fi
}
while :; do
    message '\n当前显示器：\n' '\nCurrent displays:\n'
    "$tool" list || true
    message '\n1. 停用内置屏\n2. 启用内置屏\n3. 停用外置屏\n4. 启用外置屏\n5. 恢复全部显示器\n6. 按 ID 切换一块屏幕\n7. 启用自动恢复监控\n8. 停止自动恢复监控\n9. 查看监控状态\n0. 退出\n选择：' '\n1. Disable built-in display\n2. Enable built-in display\n3. Disable external displays\n4. Enable external displays\n5. Restore all displays\n6. Toggle a display by ID\n7. Enable recovery monitor\n8. Stop recovery monitor\n9. Show monitor status\n0. Quit\nChoose: '
    IFS= read -r choice || exit 0
    case "$choice" in
        1) "$tool" off builtin || true ;;
        2) "$tool" on builtin || true ;;
        3) "$tool" off external || true ;;
        4) "$tool" on external || true ;;
        5) "$tool" on all || true ;;
        6) message '显示器 ID：' 'Display ID: '; IFS= read -r identifier || exit 0
           "$tool" toggle "$identifier" || true ;;
        7) "$tool" guard start || true ;;
        8) "$tool" guard stop || true ;;
        9) "$tool" guard status || true ;;
        0) exit 0 ;;
        *) message '请输入 0–9。\n' 'Enter a number from 0 to 9.\n' ;;
    esac
done
