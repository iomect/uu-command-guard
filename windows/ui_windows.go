//go:build windows

package main

import (
	"errors"
	"runtime"
	"syscall"
	"unsafe"
)

var gdi32 = syscall.NewLazyDLL("gdi32.dll")

// 仅供开发者检查界面；不启动输入钩子、网络或配置读写。
func run_ui_preview() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	a := &native_app{ui_preview: true, status: "等待连接"}
	previous := native
	native = a
	defer func() { native = previous }()
	instance := call(kernel32, "GetModuleHandleW", 0)
	callback := syscall.NewCallback(settings_proc)
	a.callbacks = append(a.callbacks, callback)
	wc := wndclass{Size: uint32(unsafe.Sizeof(wndclass{})), Proc: callback, Instance: instance, Name: utf("UUBridgeSettings"), Cursor: call(user32, "LoadCursorW", 0, 32512), Background: 6, Icon: application_icon(ui_scale(32, window_dpi(0))), SmallIcon: application_icon(ui_scale(16, window_dpi(0)))}
	if call(user32, "RegisterClassExW", uintptr(unsafe.Pointer(&wc))) == 0 {
		return errors.New("预览窗口注册失败")
	}
	defer call(user32, "UnregisterClassW", uintptr(unsafe.Pointer(utf("UUBridgeSettings"))), instance)
	defer func() {
		if a.dialog != 0 {
			call(user32, "DestroyWindow", a.dialog)
		}
	}()
	if e := a.settings(); e != nil {
		return e
	}
	var m msg
	for {
		v := call(user32, "GetMessageW", uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(v) == -1 {
			return errors.New("预览窗口消息读取失败")
		}
		if v == 0 {
			return nil
		}
		if a.dialog == 0 || call(user32, "IsDialogMessageW", a.dialog, uintptr(unsafe.Pointer(&m))) == 0 {
			call(user32, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
			call(user32, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
		}
	}
}

const (
	ui_background = 0x00f7f5f2
	ui_white      = 0x00ffffff
	ui_text       = 0x00352a20
	ui_muted      = 0x007b7066
	ui_blue       = 0x00cf6627
)

type settings_control struct {
	hwnd                uintptr
	x, y, width, height int32
	font                int
	background          bool
	color               uintptr
}

type settings_ui struct {
	dpi              uint32
	fonts            [3]uintptr
	background, card uintptr
	controls         []settings_control
	status, icon     uintptr
	default_button   uintptr
}

func ui_scale(value int32, dpi uint32) int32 {
	return int32((int64(value)*int64(dpi) + 48) / 96)
}

func window_dpi(hwnd uintptr) uint32 {
	if hwnd != 0 && user32.NewProc("GetDpiForWindow").Find() == nil {
		if dpi := uint32(call(user32, "GetDpiForWindow", hwnd)); dpi != 0 {
			return dpi
		}
	}
	if user32.NewProc("GetDpiForSystem").Find() == nil {
		if dpi := uint32(call(user32, "GetDpiForSystem")); dpi != 0 {
			return dpi
		}
	}
	return 96
}

// LR_SHARED 的资源图标由系统管理，窗口销毁时不能 DestroyIcon。
func application_icon(size int32) uintptr {
	return call(user32, "LoadImageW", call(kernel32, "GetModuleHandleW", 0), 1, 1, uintptr(size), uintptr(size), 0x8000)
}

func (a *native_app) settings() error {
	if a.dialog != 0 {
		call(user32, "ShowWindow", a.dialog, 9)
		call(user32, "SetForegroundWindow", a.dialog)
		return nil
	}
	u := &settings_ui{dpi: window_dpi(a.hwnd), default_button: 1}
	u.background = call(gdi32, "CreateSolidBrush", ui_background)
	u.card = call(gdi32, "CreateSolidBrush", ui_white)
	a.settings_ui = u
	if u.background == 0 || u.card == 0 {
		a.release_settings_ui()
		return errors.New("无法创建设置窗口画刷")
	}
	const style = 0x02ca0000 // 固定尺寸，保留标题栏、关闭和最小化。
	const extended_style = 0x40000
	r := rect{Right: ui_scale(520, u.dpi), Bottom: ui_scale(440, u.dpi)}
	if user32.NewProc("AdjustWindowRectExForDpi").Find() == nil {
		call(user32, "AdjustWindowRectExForDpi", uintptr(unsafe.Pointer(&r)), style, 0, extended_style, uintptr(u.dpi))
	} else {
		call(user32, "AdjustWindowRectEx", uintptr(unsafe.Pointer(&r)), style, 0, extended_style)
	}
	a.dialog = call(user32, "CreateWindowExW", extended_style, uintptr(unsafe.Pointer(utf("UUBridgeSettings"))), uintptr(unsafe.Pointer(utf("UU 局域网辅助"))), style, 0x80000000, 0x80000000, uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), a.hwnd, 0, call(kernel32, "GetModuleHandleW", 0), 0)
	if a.dialog == 0 {
		a.release_settings_ui()
		return errors.New("无法创建 Mac IPv4 设置窗口")
	}
	a.mu.Lock()
	peer_setting := a.cfg.Peer
	a.mu.Unlock()
	create := func(class, text string, style, extended, id uintptr, x, y, width, height int32, font int, background bool, color uintptr) uintptr {
		h := call(user32, "CreateWindowExW", extended, uintptr(unsafe.Pointer(utf(class))), uintptr(unsafe.Pointer(utf(text))), 0x50000000|style, uintptr(ui_scale(x, u.dpi)), uintptr(ui_scale(y, u.dpi)), uintptr(ui_scale(width, u.dpi)), uintptr(ui_scale(height, u.dpi)), a.dialog, id, call(kernel32, "GetModuleHandleW", 0), 0)
		u.controls = append(u.controls, settings_control{h, x, y, width, height, font, background, color})
		return h
	}
	u.icon = create("STATIC", "", 3, 0, 0, 28, 30, 48, 48, 0, true, ui_text)
	create("STATIC", "UU 局域网辅助", 0, 0, 0, 96, 28, 396, 34, 2, true, ui_text)
	create("STATIC", "让远程快捷键保持一致", 0, 0, 0, 96, 68, 396, 24, 0, true, ui_muted)
	u.status = create("STATIC", "", 0, 0, 0, 44, 148, 432, 36, 0, false, ui_blue)
	create("STATIC", "Mac IPv4", 0, 0, 0, 44, 198, 432, 22, 0, false, ui_text)
	a.edit = create("EDIT", peer_setting, 0x10080, 0x200, 10, 44, 226, 432, 34, 0, false, ui_text)
	call(user32, "SendMessageW", a.edit, 0xc5, 63, 0) // EM_SETLIMITTEXT
	create("STATIC", "填写 Mac 的局域网地址。两台设备需在同一网络。", 0, 0, 0, 44, 272, 432, 32, 1, false, ui_muted)
	create("BUTTON", "保存并连接", 0x10001, 0, 1, 244, 316, 140, 34, 0, false, ui_text)
	create("BUTTON", "关闭", 0x10000, 0, 2, 396, 316, 80, 34, 0, false, ui_text)
	create("STATIC", "关闭窗口后仍在托盘运行", 0, 0, 0, 28, 382, 464, 20, 1, true, ui_muted)
	create("STATIC", "诊断仅在导出时写入文件", 0, 0, 0, 28, 406, 464, 20, 1, true, ui_muted)
	for _, control := range u.controls {
		if control.hwnd == 0 {
			call(user32, "DestroyWindow", a.dialog)
			return errors.New("无法创建设置窗口控件")
		}
	}
	if !a.layout_settings() {
		call(user32, "DestroyWindow", a.dialog)
		return errors.New("无法创建设置窗口字体")
	}
	a.refresh_settings_status()
	call(user32, "ShowWindow", a.dialog, 5)
	call(user32, "SetFocus", a.edit)
	call(user32, "SetForegroundWindow", a.dialog)
	return nil
}

func (a *native_app) layout_settings() bool {
	u := a.settings_ui
	var fonts [3]uintptr
	for i, size := range []int32{14, 12, 24} {
		weight := uintptr(400)
		if i == 2 {
			weight = 600
		}
		fonts[i] = call(gdi32, "CreateFontW", uintptr(-ui_scale(size, u.dpi)), 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, uintptr(unsafe.Pointer(utf("Segoe UI"))))
		if fonts[i] == 0 {
			for _, font := range fonts {
				if font != 0 {
					call(gdi32, "DeleteObject", font)
				}
			}
			return false
		}
	}
	for _, c := range u.controls {
		call(user32, "SendMessageW", c.hwnd, 0x30, fonts[c.font], 1)
		call(user32, "MoveWindow", c.hwnd, uintptr(ui_scale(c.x, u.dpi)), uintptr(ui_scale(c.y, u.dpi)), uintptr(ui_scale(c.width, u.dpi)), uintptr(ui_scale(c.height, u.dpi)), 1)
	}
	for _, font := range u.fonts {
		if font != 0 {
			call(gdi32, "DeleteObject", font)
		}
	}
	u.fonts = fonts
	call(user32, "SendMessageW", u.icon, 0x170, application_icon(ui_scale(48, u.dpi)), 0)
	call(user32, "SendMessageW", a.dialog, 0x80, 0, application_icon(ui_scale(16, u.dpi)))
	call(user32, "SendMessageW", a.dialog, 0x80, 1, application_icon(ui_scale(32, u.dpi)))
	call(user32, "InvalidateRect", a.dialog, 0, 1)
	return true
}

func (a *native_app) refresh_settings_status() {
	if a.dialog == 0 || a.settings_ui == nil || a.settings_ui.status == 0 {
		return
	}
	a.mu.Lock()
	status := a.status
	a.mu.Unlock()
	call(user32, "SetWindowTextW", a.settings_ui.status, uintptr(unsafe.Pointer(utf("连接状态 · "+status))))
}

func (a *native_app) release_settings_ui() {
	if u := a.settings_ui; u != nil {
		for _, object := range append(u.fonts[:], u.background, u.card) {
			if object != 0 {
				call(gdi32, "DeleteObject", object)
			}
		}
		a.settings_ui = nil
	}
}

func (a *native_app) settings_message(h uintptr, m uint32, w, l uintptr) (uintptr, bool) {
	u := a.settings_ui
	if u == nil {
		return 0, false
	}
	switch m {
	case 0x400: // DM_GETDEFID: IsDialogMessage 的 Enter 默认按钮。
		return 0x534b0000 | u.default_button, true
	case 0x401: // DM_SETDEFID
		old := call(user32, "GetDlgItem", h, u.default_button)
		button := call(user32, "GetDlgItem", h, w)
		if old != 0 {
			call(user32, "SendMessageW", old, 0xf4, 0, 1)
		}
		if button != 0 {
			call(user32, "SendMessageW", button, 0xf4, 1, 1)
		}
		u.default_button = w
		return 1, true
	case 0x14: // WM_ERASEBKGND
		var client rect
		call(user32, "GetClientRect", h, uintptr(unsafe.Pointer(&client)))
		call(user32, "FillRect", w, uintptr(unsafe.Pointer(&client)), u.background)
		card := rect{ui_scale(24, u.dpi), ui_scale(128, u.dpi), ui_scale(496, u.dpi), ui_scale(366, u.dpi)}
		call(user32, "FillRect", w, uintptr(unsafe.Pointer(&card)), u.card)
		return 1, true
	case 0x138: // WM_CTLCOLORSTATIC
		for _, c := range u.controls {
			if c.hwnd == l {
				background, brush := uintptr(ui_white), u.card
				if c.background {
					background, brush = ui_background, u.background
				}
				call(gdi32, "SetTextColor", w, c.color)
				call(gdi32, "SetBkColor", w, background)
				return brush, true
			}
		}
	case 0x2e0: // WM_DPICHANGED: 接受系统推荐的外框，重新缩放子控件。
		if l != 0 && uint32(w)&0xffff != 0 {
			u.dpi = uint32(w) & 0xffff
			r := *(*rect)(unsafe.Pointer(l))
			call(user32, "SetWindowPos", h, 0, uintptr(r.Left), uintptr(r.Top), uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), 0x14)
			if !a.layout_settings() {
				message("设置窗口失败", "无法调整显示比例，请重新打开设置窗口")
				call(user32, "DestroyWindow", h)
			}
			return 0, true
		}
	}
	return 0, false
}
