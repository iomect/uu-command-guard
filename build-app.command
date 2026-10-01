#!/bin/zsh
set -eu
cd -- "${0:A:h}"

destination="${1:-${PWD}/UU 修补工具.app}"
destination="${destination:A}"
if [[ -e "$destination" && ! -d "$destination" ]]; then
    print -u2 '目标是替身或普通文件，请用第一个参数指定实际应用目录；不会覆盖替身。'
    exit 1
fi
if [[ -d "$destination" ]]; then
    bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    if [[ "$bundle_identifier" != local.uu-command-guard ]]; then
        print -u2 '目标不是 UU 修补工具应用，不予替换。'
        exit 1
    fi
fi

destination_running() {
    [[ -f "$destination/Contents/MacOS/UUCommandGuard" ]] && /usr/sbin/lsof -t -- "$destination/Contents/MacOS/UUCommandGuard" >/dev/null 2>&1
}
if destination_running; then
    print -u2 '应用正在运行，请先从菜单栏退出后再构建。'
    exit 1
fi

build_directory=$(/usr/bin/mktemp -d "${PWD}/.build-app.XXXXXX")
trap '/bin/rm -rf -- "$build_directory"' EXIT
app_directory="$build_directory/UU 修补工具.app"
/bin/mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
/bin/cp Info.plist "$app_directory/Contents/Info.plist"
/bin/cp assets/app.icns "$app_directory/Contents/Resources/AppIcon.icns"
/bin/cp assets/menu-bar.png "$app_directory/Contents/Resources/MenuBar.png"
/usr/bin/plutil -lint "$app_directory/Contents/Info.plist"
/bin/cp command-guard.swift "$build_directory/main.swift"
/usr/bin/xcrun swiftc -warnings-as-errors -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
    -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." \
    "${build_directory:t}/main.swift" memory-diagnostics.swift remote-peer.swift -o "$app_directory/Contents/MacOS/UUCommandGuard"
"$app_directory/Contents/MacOS/UUCommandGuard" --self-test
/usr/bin/codesign --force --sign - "$app_directory"
/usr/bin/codesign --verify --strict "$app_directory"

# Recheck after compilation in case the user launched the app meanwhile.
if destination_running; then
    print -u2 '应用已启动，本次不替换。请退出应用后重新构建。'
    exit 1
fi
if [[ -e "$destination" ]]; then
    /bin/mv -- "$destination" "$build_directory/previous.app"
fi
if ! /bin/mv -- "$app_directory" "$destination"; then
    if [[ -d "$build_directory/previous.app" ]]; then
        /bin/mv -- "$build_directory/previous.app" "$destination"
    fi
    exit 1
fi
print "应用已生成：$destination"
print '双击应用启动；若旧版终端工具仍在运行，请先按 Ctrl+C 停止旧版。'
