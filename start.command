#!/bin/zsh
cd -- "${0:A:h}" || exit 1
if /usr/bin/pgrep -x command-guard >/dev/null; then
    echo '修补工具已经运行，请先停止现有实例。'
    read -r '?按回车关闭窗口。'
    exit 1
fi
./command-guard
read -r '?程序已退出，按回车关闭窗口。'
