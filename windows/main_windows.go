//go:build windows

package main

import (
	"os"
	"path/filepath"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--ui-preview":
			if e := run_ui_preview(); e != nil {
				message("界面预览失败", e.Error())
			}
			return
		case "--report":
			if len(os.Args) != 3 {
				message("报告参数", "请使用 --report <输出 JSON 路径>")
				return
			}
			if e := self_report(os.Args[2]); e != nil {
				message("报告失败", e.Error())
			}
			return
		case "--self-test":
			e := offline_check()
			if e == nil {
				e = native_offline_check()
			}
			if e != nil {
				message("离线检查失败", e.Error())
			} else {
				message("离线检查通过", "协议、修饰键和世代状态检查通过；未发送真实输入。")
			}
			return
		}
	}
	if e := run_native(); e != nil {
		message(filepath.Base(os.Args[0]), e.Error())
	}
}
