//go:build !windows

package main

import "fmt"

func main() { fmt.Println("此程序仅在 Windows 运行；可在此系统执行 go test ./...") }
