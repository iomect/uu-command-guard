#!/bin/zsh
set -eu
cd -- "${0:A:h}"
destination="${1:-${PWD}/command-guard.new}"
destination="${destination:A}"
if [[ -f "$destination" ]] && /usr/sbin/lsof -t -- "$destination" >/dev/null 2>&1; then
    print -u2 '目标可执行文件正在使用，不予替换。'
    exit 1
fi
build_directory=$(/usr/bin/mktemp -d "${PWD}/.build-cli.XXXXXX")
trap '/bin/rm -rf -- "$build_directory"' EXIT
/bin/cp command-guard.swift "$build_directory/main.swift"
/usr/bin/xcrun swiftc -warnings-as-errors "${build_directory:t}/main.swift" memory-diagnostics.swift remote-peer.swift \
    -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." \
    -o "$build_directory/command-guard"
"$build_directory/command-guard" --self-test
/bin/mv -- "$build_directory/command-guard" "$destination"
print "命令行版已生成：$destination"
