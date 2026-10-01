//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var comdlg32 = syscall.NewLazyDLL("comdlg32.dll")

// OPENFILENAMEW，包含 Windows 2000 以后的保留字段。
type open_file_name struct {
	Size                         uint32
	Owner, Instance              uintptr
	Filter, CustomFilter         *uint16
	MaxCustomFilter, FilterIndex uint32
	File                         *uint16
	MaxFile                      uint32
	FileTitle                    *uint16
	MaxFileTitle                 uint32
	InitialDir, Title            *uint16
	Flags                        uint32
	FileOffset, FileExtension    uint16
	DefaultExtension             *uint16
	CustomData, Hook             uintptr
	TemplateName                 *uint16
	Reserved                     uintptr
	ReservedSize, FlagsEx        uint32
}

type export_notice struct{ Title, Body string }

// 由锁定 OS 线程的托盘 UI 调用；原生对话框不会占用网络或输入钩子线程。
func (a *native_app) choose_diagnostic_path() (string, error) {
	file := make([]uint16, 32768)
	copy(file, syscall.StringToUTF16("UU-诊断-"+time.Now().Format("20060102-150405.000")+".json"))
	filter := utf16.Encode([]rune("JSON 诊断文件 (*.json)\x00*.json\x00所有文件 (*.*)\x00*.*\x00\x00"))
	initial_directory := os.Getenv("USERPROFILE")
	if initial_directory != "" {
		initial_directory = filepath.Join(initial_directory, "Downloads")
	}
	name := open_file_name{
		Size: uint32(unsafe.Sizeof(open_file_name{})), Owner: a.hwnd,
		Filter: &filter[0], FilterIndex: 1,
		File: &file[0], MaxFile: uint32(len(file)),
		Title: utf("导出最近两分钟诊断"), DefaultExtension: utf("json"),
		// 覆盖确认、不改变当前目录、必须选择已有目录、使用 Explorer 风格。
		Flags: 0x2 | 0x8 | 0x800 | 0x80000,
	}
	if initial_directory != "" {
		name.InitialDir = utf(initial_directory)
	}
	if call(comdlg32, "GetSaveFileNameW", uintptr(unsafe.Pointer(&name))) == 0 {
		if code := call(comdlg32, "CommDlgExtendedError"); code != 0 {
			return "", fmt.Errorf("无法打开诊断保存对话框（Windows 错误 0x%X）", code)
		}
		return "", nil
	}
	return syscall.UTF16ToString(file), nil
}

func (a *native_app) finish_diagnostic_export(title, body string) {
	a.export_result.Store(&export_notice{Title: title, Body: body})
	call(user32, "PostMessageW", a.hwnd, 0x8006, 0, 0)
}
