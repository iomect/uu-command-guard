#!/bin/zsh
set -eu
cd -- "${0:A:h}"
go_command=$(command -v go)
destination="${1:-${PWD}/dist/UUCommandBridge.exe}"
destination="${destination:A}"
/bin/mkdir -p -- "${destination:h}"
python3 tools/build-windows-resources.py
cd windows
"$go_command" test -race ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$go_command" build -trimpath -ldflags='-H=windowsgui -s -w' -o "$destination" .
print "Windows x64 托盘程序已生成：$destination"
