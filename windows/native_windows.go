//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

var user32 = syscall.NewLazyDLL("user32.dll")
var kernel32 = syscall.NewLazyDLL("kernel32.dll")
var shell32 = syscall.NewLazyDLL("shell32.dll")
var advapi32 = syscall.NewLazyDLL("advapi32.dll")
var versiondll = syscall.NewLazyDLL("version.dll")
var get_foreground = user32.NewProc("GetForegroundWindow")
var get_ancestor = user32.NewProc("GetAncestor")
var get_pid = user32.NewProc("GetWindowThreadProcessId")
var next_hook = user32.NewProc("CallNextHookEx")
var async_key = user32.NewProc("GetAsyncKeyState")

func utf(s string) *uint16 { p, _ := syscall.UTF16PtrFromString(s); return p }

// Win32 调用点将指针转为 uintptr；必须在整个调用期间保活并避免栈移动。
//
//go:uintptrescapes
func call(d *syscall.LazyDLL, n string, a ...uintptr) uintptr {
	v, _, _ := d.NewProc(n).Call(a...)
	return v
}

type point struct{ X, Y int32 }
type msg struct {
	HWND           uintptr
	Message        uint32
	WParam, LParam uintptr
	Time           uint32
	Pt             point
	Private        uint32
}
type wndclass struct {
	Size, Style                        uint32
	Proc                               uintptr
	ClassExtra, WindowExtra            int32
	Instance, Icon, Cursor, Background uintptr
	Menu, Name                         *uint16
	SmallIcon                          uintptr
}
type notifyicon struct {
	Size                uint32
	HWND                uintptr
	ID, Flags, Callback uint32
	Icon                uintptr
	Tip                 [128]uint16
	State, StateMask    uint32
	Info                [256]uint16
	Version             uint32
	InfoTitle           [64]uint16
	InfoFlags           uint32
	GUID                [16]byte
	BalloonIcon         uintptr
}
type keyboard struct {
	VK, Scan, Flags, Time uint32
	Extra                 uintptr
}
type mouse struct {
	Pt                point
	Data, Flags, Time uint32
	Extra             uintptr
}
type rect struct{ Left, Top, Right, Bottom int32 }
type process_identity struct {
	PID     uint32
	Created uint64
	Path    string
}
type focus_state struct {
	HWND     uintptr
	Identity process_identity
	Token    string
	Scope    bool
}
type config struct {
	Peer   string `json:"peer_ipv4"`
	Paused bool   `json:"paused"`
}
type native_app struct {
	hwnd, edit, dialog                    uintptr
	settings_ui                           *settings_ui
	ui_preview                            bool
	cfg                                   config
	cfg_path                              string
	commands                              chan ui_command
	input                                 chan source_event
	focus                                 atomic.Pointer[focus_state]
	mods                                  atomic.Uint32
	event_id                              atomic.Uint64
	overflow                              atomic.Bool
	gap_reasons                           atomic.Uint32
	lifecycle                             chan uintptr
	lifecycle_lost                        atomic.Bool
	dirty                                 atomic.Bool
	mu                                    sync.Mutex
	status                                string
	diag                                  *diagnostics
	roots                                 []string
	seen                                  map[uintptr]focus_state
	keyboard_hook, mouse_hook, event_hook uintptr
	stop                                  chan struct{}
	hook_ready                            chan error
	hook_done                             chan struct{}
	hook_thread                           atomic.Uint32
	network_done                          chan struct{}
	closed                                sync.Once
	mutex                                 uintptr
	taskbar_created                       uint32
	ui_loop_started                       bool
	dialogs                               []uintptr
	callbacks                             []uintptr
	export_pending                        bool
	export_result                         atomic.Pointer[export_notice]
}
type ui_command struct{ Kind, Value string }

const (
	gap_modifier_state_mismatch uint32 = 1 << iota
	gap_input_queue_overflow
	gap_health_queue_overflow
	gap_foreground_changed_before_verify
	gap_lifecycle_queue_overflow
	gap_focused_window_lifecycle_changed
	gap_focus_cache_overflow
)

func (a *native_app) mark_source_gap(reason uint32) {
	a.gap_reasons.Or(reason)
	a.overflow.Store(true)
}

var native *native_app

func message(title, body string) {
	call(user32, "MessageBoxW", 0, uintptr(unsafe.Pointer(utf(body))), uintptr(unsafe.Pointer(utf(title))), 0x40)
}
func config_file() (string, error) {
	d := os.Getenv("LOCALAPPDATA")
	if d == "" {
		return "", errors.New("找不到 LOCALAPPDATA")
	}
	return filepath.Join(d, "UUCommandBridge", "config.json"), nil
}
func (a *native_app) save() error {
	if e := os.MkdirAll(filepath.Dir(a.cfg_path), 0700); e != nil {
		return e
	}
	b, e := json.MarshalIndent(a.cfg, "", "  ")
	if e != nil {
		return e
	}
	tmp := a.cfg_path + ".tmp"
	if e = os.WriteFile(tmp, b, 0600); e != nil {
		return e
	}
	if e = os.Rename(tmp, a.cfg_path); e != nil {
		os.Remove(tmp)
	}
	return e
}
func (a *native_app) set_status(s string) {
	a.mu.Lock()
	a.status = s
	a.mu.Unlock()
	call(user32, "PostMessageW", a.hwnd, 0x8003, 0, 0)
}
func (a *native_app) tray(add bool) error {
	n := notifyicon{Size: uint32(unsafe.Sizeof(notifyicon{})), HWND: a.hwnd, ID: 1, Flags: 7, Callback: 0x8001, Icon: application_icon(ui_scale(16, window_dpi(a.hwnd)))}
	if n.Icon == 0 {
		return errors.New("无法加载应用托盘图标")
	}
	a.mu.Lock()
	s := "UU 局域网辅助 · " + a.status
	a.mu.Unlock()
	v := syscall.StringToUTF16(s)
	copy(n.Tip[:], v)
	kind := uintptr(1)
	if add {
		kind = 0
	}
	if call(shell32, "Shell_NotifyIconW", kind, uintptr(unsafe.Pointer(&n))) == 0 {
		return errors.New("无法添加或更新系统托盘图标；请确认 Windows 任务栏正常运行后重新打开程序")
	}
	return nil
}
func (a *native_app) menu() {
	h := call(user32, "CreatePopupMenu")
	defer call(user32, "DestroyMenu", h)
	a.mu.Lock()
	status := a.status
	paused := a.cfg.Paused
	a.mu.Unlock()
	pause_label := "暂停同步"
	if paused {
		pause_label = "恢复同步"
	}
	entries := []struct {
		id   uintptr
		text string
	}{{0, status}, {1, "设置 Mac IPv4…"}, {2, pause_label}, {3, "导出诊断…"}, {4, "退出"}}
	for _, e := range entries {
		flags := uintptr(0)
		if e.id == 0 {
			flags = 2
		}
		call(user32, "AppendMenuW", h, flags, e.id, uintptr(unsafe.Pointer(utf(e.text))))
	}
	var p point
	call(user32, "GetCursorPos", uintptr(unsafe.Pointer(&p)))
	call(user32, "SetForegroundWindow", a.hwnd)
	id := call(user32, "TrackPopupMenu", h, 0x100|2, uintptr(p.X), uintptr(p.Y), 0, a.hwnd, 0)
	call(user32, "PostMessageW", a.hwnd, 0, 0, 0)
	switch id {
	case 1:
		if e := a.settings(); e != nil {
			message("设置窗口失败", e.Error())
		}
	case 2:
		a.commands <- ui_command{Kind: "pause"}
	case 3:
		if a.export_pending {
			return
		}
		a.export_pending = true
		path, e := a.choose_diagnostic_path()
		if e != nil {
			a.export_pending = false
			message("导出失败", e.Error())
		} else if path != "" {
			a.commands <- ui_command{Kind: "export", Value: path}
		} else {
			a.export_pending = false
		}
	case 4:
		call(user32, "DestroyWindow", a.hwnd)
	}
}
func wnd_proc(h uintptr, m uint32, w, l uintptr) uintptr {
	a := native
	if a != nil {
		if a.taskbar_created != 0 && m == a.taskbar_created {
			if e := a.tray(true); e != nil {
				if setting_error := a.settings(); setting_error != nil {
					message("设置窗口失败", setting_error.Error())
				}
				message("托盘恢复失败", e.Error())
			}
			return 0
		}
		switch m {
		case 0x11:
			return 1
		case 0x16:
			if w != 0 {
				call(user32, "DestroyWindow", h)
			}
			return 0
		case 0x8001:
			if uint32(l) == 0x205 || uint32(l) == 0x202 {
				a.menu()
			}
			return 0
		case 0x8003:
			// Explorer 重建任务栏时由 TaskbarCreated 重新添加。
			a.tray(false)
			a.refresh_settings_status()
			return 0
		case 0x8005:
			if e := a.settings(); e != nil {
				message("设置窗口失败", e.Error())
			}
			return 0
		case 0x8006:
			if result := a.export_result.Swap(nil); result != nil {
				a.export_pending = false
				message(result.Title, result.Body)
			}
			return 0
		case 2:
			n := notifyicon{Size: uint32(unsafe.Sizeof(notifyicon{})), HWND: h, ID: 1}
			call(shell32, "Shell_NotifyIconW", 2, uintptr(unsafe.Pointer(&n)))
			a.closed.Do(func() { close(a.stop) })
			// 启动失败后 main 还需要显示错误对话框，不能提前投递 WM_QUIT。
			if a.ui_loop_started {
				call(user32, "PostQuitMessage", 0)
			}
			return 0
		}
	}
	return call(user32, "DefWindowProcW", h, uintptr(m), w, l)
}
func settings_proc(h uintptr, m uint32, w, l uintptr) uintptr {
	a := native
	if a != nil {
		if result, handled := a.settings_message(h, m, w, l); handled {
			return result
		}
		switch m {
		case 0x111:
			switch uint16(w) {
			case 1, 11:
				b := make([]uint16, 64)
				call(user32, "GetWindowTextW", a.edit, uintptr(unsafe.Pointer(&b[0])), 64)
				s := strings.TrimSpace(syscall.UTF16ToString(b))
				if s != "" {
					if _, e := ipv4(s); e != nil {
						message("配置错误", e.Error())
						return 0
					}
				}
				if !a.ui_preview {
					a.commands <- ui_command{Kind: "peer", Value: s}
				}
				call(user32, "DestroyWindow", h)
				return 0
			case 2, 12:
				call(user32, "DestroyWindow", h)
				return 0
			}
		case 0x82:
			a.release_settings_ui()
			a.dialog = 0
			a.edit = 0
			if a.ui_preview {
				call(user32, "PostQuitMessage", 0)
			}
		}
	}
	return call(user32, "DefWindowProcW", h, uintptr(m), w, l)
}
func (a *native_app) fast_focus() *focus_state {
	f := a.focus.Load()
	if f == nil {
		return nil
	}
	h := get_foreground.Call
	v, _, _ := h()
	root, _, _ := get_ancestor.Call(v, 2)
	if root != f.HWND {
		a.dirty.Store(true)
		a.mark_source_gap(gap_foreground_changed_before_verify)
		return nil
	}
	return f
}
func (a *native_app) push(kind string, key uint16, action string) {
	f := a.fast_focus()
	if f == nil || !f.Scope {
		return
	}
	e := source_event{ID: a.event_id.Add(1), Time: now_us(), Window: f.Token, Kind: kind, Key: key, Action: action, Mods: uint16(a.mods.Load())}
	select {
	case a.input <- e:
	default:
		a.mark_source_gap(gap_input_queue_overflow)
	}
}
func keyboard_proc(code int32, w, l uintptr) uintptr {
	if code >= 0 {
		a := native
		k := (*keyboard)(unsafe.Pointer(l))
		if k.Flags&0x10 == 0 {
			down := w == 0x100 || w == 0x104
			up := w == 0x101 || w == 0x105
			if down || up {
				u := scan_usage(k.Scan, k.Flags&1 != 0)
				bit := usage_mod(u)
				if bit != 0 {
					for {
						old := a.mods.Load()
						v := old
						if down {
							v |= uint32(bit)
						} else {
							v &^= uint32(bit)
						}
						if a.mods.CompareAndSwap(old, v) {
							break
						}
					}
				}
				if u != 0 {
					action := "up"
					if down {
						action = "down"
					}
					kind := "key"
					if bit != 0 {
						kind = "modifier"
					}
					a.push(kind, u, action)
				}
			}
		}
	}
	v, _, _ := next_hook.Call(0, uintptr(code), w, l)
	return v
}
func mouse_proc(code int32, w, l uintptr) uintptr {
	// Windows still invokes the shared mouse hook for motion (including drags).
	// Pass it straight through without decoding, timestamps, focus checks or queues.
	if code >= 0 && w != 0x200 {
		a := native
		k := (*mouse)(unsafe.Pointer(l))
		if k.Flags&1 == 0 {
			key := uint16(0)
			action := "down"
			switch w {
			case 0x201:
				key = 1
			case 0x202:
				key = 1
				action = "up"
			case 0x204:
				key = 2
			case 0x205:
				key = 2
				action = "up"
			case 0x207:
				key = 3
			case 0x208:
				key = 3
				action = "up"
			case 0x20b:
				key = 3 + uint16(k.Data>>16)
			case 0x20c:
				key = 3 + uint16(k.Data>>16)
				action = "up"
			case 0x20a:
				key = 1
				if int16(k.Data>>16) < 0 {
					key = 2
				}
				a.push("wheel", key, "pulse")
			case 0x20e:
				key = 3
				if int16(k.Data>>16) < 0 {
					key = 4
				}
				a.push("wheel", key, "pulse")
			}
			if key > 0 && w != 0x20a && w != 0x20e {
				a.push("button", key, action)
			}
		}
	}
	v, _, _ := next_hook.Call(0, uintptr(code), w, l)
	return v
}
func event_proc(h uintptr, event uint32, window uintptr, object, child int32, thread, time uint32) uintptr {
	if object == 0 && child == 0 {
		native.dirty.Store(true)
		if event == 0x8000 || event == 0x8001 {
			select {
			case native.lifecycle <- window:
			default:
				native.mark_source_gap(gap_lifecycle_queue_overflow)
				native.lifecycle_lost.Store(true)
				native.focus.Store(nil)
			}
			f := native.focus.Load()
			if f != nil && f.HWND == window {
				native.focus.Store(nil)
				native.mark_source_gap(gap_focused_window_lifecycle_changed)
			}
		}
	}
	return 0
}
func (a *native_app) hooks() {
	defer close(a.hook_done)
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	kb := syscall.NewCallback(keyboard_proc)
	ms := syscall.NewCallback(mouse_proc)
	ev := syscall.NewCallback(event_proc)
	a.callbacks = append(a.callbacks, kb, ms, ev)
	a.keyboard_hook = call(user32, "SetWindowsHookExW", 13, kb, 0, 0)
	a.mouse_hook = call(user32, "SetWindowsHookExW", 14, ms, 0, 0)
	a.event_hook = call(user32, "SetWinEventHook", 0x8000, 0x8001, 0, ev, 0, 0, 2)
	fg := call(user32, "SetWinEventHook", 3, 3, 0, ev, 0, 0, 2)
	var initial_message msg
	call(user32, "PeekMessageW", uintptr(unsafe.Pointer(&initial_message)), 0, 0, 0, 0)
	if a.keyboard_hook == 0 || a.mouse_hook == 0 || a.event_hook == 0 || fg == 0 {
		a.hook_ready <- errors.New("无法建立输入观察钩子")
	} else {
		a.hook_ready <- nil
	}
	tid := call(kernel32, "GetCurrentThreadId")
	a.hook_thread.Store(uint32(tid))
	go func() { <-a.stop; call(user32, "PostThreadMessageW", tid, 0x12, 0, 0) }()
	var m msg
	for {
		r := call(user32, "GetMessageW", uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if r == 0 || int32(r) == -1 {
			break
		}
		if m.HWND == 0 && m.Message == 0x8004 {
			a.health()
			continue
		}
		call(user32, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
		call(user32, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
	}
	if a.keyboard_hook != 0 {
		call(user32, "UnhookWindowsHookEx", a.keyboard_hook)
	}
	if a.mouse_hook != 0 {
		call(user32, "UnhookWindowsHookEx", a.mouse_hook)
	}
	if a.event_hook != 0 {
		call(user32, "UnhookWinEvent", a.event_hook)
	}
	if fg != 0 {
		call(user32, "UnhookWinEvent", fg)
	}
}
func identity(hwnd uintptr) (process_identity, error) {
	var id process_identity
	get_pid.Call(hwnd, uintptr(unsafe.Pointer(&id.PID)))
	if id.PID == 0 {
		return id, errors.New("pid")
	}
	h := call(kernel32, "OpenProcess", 0x1000, 0, uintptr(id.PID))
	if h == 0 {
		return id, errors.New("process")
	}
	defer call(kernel32, "CloseHandle", h)
	b := make([]uint16, 32768)
	n := uint32(len(b))
	if call(kernel32, "QueryFullProcessImageNameW", h, 0, uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&n))) == 0 {
		return id, errors.New("path")
	}
	id.Path = filepath.Clean(syscall.UTF16ToString(b[:n]))
	var c, e, k, u syscall.Filetime
	if call(kernel32, "GetProcessTimes", h, uintptr(unsafe.Pointer(&c)), uintptr(unsafe.Pointer(&e)), uintptr(unsafe.Pointer(&k)), uintptr(unsafe.Pointer(&u))) == 0 {
		return id, errors.New("creation")
	}
	id.Created = uint64(c.HighDateTime)<<32 | uint64(c.LowDateTime)
	return id, nil
}
func registry_string(h uintptr, name string) string {
	var typ, size uint32
	r := call(advapi32, "RegQueryValueExW", h, uintptr(unsafe.Pointer(utf(name))), 0, uintptr(unsafe.Pointer(&typ)), 0, uintptr(unsafe.Pointer(&size)))
	if r != 0 || size < 2 || size > 65536 || typ != 1 && typ != 2 {
		return ""
	}
	b := make([]uint16, size/2+1)
	r = call(advapi32, "RegQueryValueExW", h, uintptr(unsafe.Pointer(utf(name))), 0, uintptr(unsafe.Pointer(&typ)), uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&size)))
	if r != 0 {
		return ""
	}
	return syscall.UTF16ToString(b)
}
func install_roots() []string {
	var out []string
	for _, root := range []uintptr{0x80000001, 0x80000002} {
		for _, view := range []uintptr{0x100, 0x200} {
			var h uintptr
			r := call(advapi32, "RegOpenKeyExW", root, uintptr(unsafe.Pointer(utf(`Software\Microsoft\Windows\CurrentVersion\Uninstall`))), 0, 0x20019|view, uintptr(unsafe.Pointer(&h)))
			if r != 0 {
				continue
			}
			for i := uint32(0); ; i++ {
				b := make([]uint16, 512)
				n := uint32(len(b))
				r = call(advapi32, "RegEnumKeyExW", h, uintptr(i), uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&n)), 0, 0, 0, 0)
				if r == 259 {
					break
				}
				if r != 0 {
					continue
				}
				var sub uintptr
				if call(advapi32, "RegOpenKeyExW", h, uintptr(unsafe.Pointer(&b[0])), 0, 0x20019|view, uintptr(unsafe.Pointer(&sub))) != 0 {
					continue
				}
				name := registry_string(sub, "DisplayName")
				icon := registry_string(sub, "DisplayIcon")
				loc := registry_string(sub, "InstallLocation")
				call(advapi32, "RegCloseKey", sub)
				if !(strings.Contains(name, "UU") && (strings.Contains(name, "远程") || strings.Contains(strings.ToLower(name), "remote"))) {
					continue
				}
				if loc != "" {
					out = append(out, filepath.Clean(loc))
				}
				icon = strings.TrimSpace(icon)
				if strings.HasPrefix(icon, "\"") {
					if j := strings.Index(icon[1:], "\""); j >= 0 {
						icon = icon[1 : j+1]
					}
				} else if j := strings.LastIndex(icon, ","); j >= 0 {
					icon = icon[:j]
				}
				if strings.EqualFold(filepath.Base(icon), "GameViewer.exe") {
					out = append(out, filepath.Dir(icon))
					if strings.EqualFold(filepath.Base(filepath.Dir(icon)), "bin") {
						out = append(out, filepath.Dir(filepath.Dir(icon)))
					}
				}
			}
			call(advapi32, "RegCloseKey", h)
		}
	}
	return out
}
func product_info(path string) map[string]string {
	out := map[string]string{}
	var dummy uint32
	n := call(versiondll, "GetFileVersionInfoSizeW", uintptr(unsafe.Pointer(utf(path))), uintptr(unsafe.Pointer(&dummy)))
	if n == 0 || n > 4*1024*1024 {
		return out
	}
	b := make([]byte, n)
	if call(versiondll, "GetFileVersionInfoW", uintptr(unsafe.Pointer(utf(path))), 0, n, uintptr(unsafe.Pointer(&b[0]))) == 0 {
		return out
	}
	var p uintptr
	var size uint32
	var translations []uint16
	if call(versiondll, "VerQueryValueW", uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(utf(`\VarFileInfo\Translation`))), uintptr(unsafe.Pointer(&p)), uintptr(unsafe.Pointer(&size))) != 0 && size >= 4 {
		translations = unsafe.Slice((*uint16)(unsafe.Pointer(p)), size/2)
	}
	for i := 0; i+1 < len(translations); i += 2 {
		for _, key := range []string{"ProductName", "CompanyName", "OriginalFilename", "FileDescription", "ProductVersion"} {
			query := fmt.Sprintf(`\StringFileInfo\%04x%04x\%s`, translations[i], translations[i+1], key)
			if call(versiondll, "VerQueryValueW", uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(utf(query))), uintptr(unsafe.Pointer(&p)), uintptr(unsafe.Pointer(&size))) != 0 && size > 0 {
				out[key] = syscall.UTF16ToString(unsafe.Slice((*uint16)(unsafe.Pointer(p)), size))
			}
		}
	}
	return out
}
func (a *native_app) verify_focus() {
	if a.lifecycle_lost.Swap(false) {
		a.seen = map[uintptr]focus_state{}
	}
	for {
		select {
		case h := <-a.lifecycle:
			delete(a.seen, h)
		default:
			goto drained
		}
	}
drained:
	h := call(user32, "GetForegroundWindow")
	h = call(user32, "GetAncestor", h, 2)
	id, e := identity(h)
	scope := false
	if e == nil {
		for _, root := range a.roots {
			for _, p := range []string{filepath.Join(root, "GameViewer.exe"), filepath.Join(root, "bin", "GameViewer.exe")} {
				if strings.EqualFold(p, id.Path) {
					info := product_info(id.Path)
					company := strings.ToLower(info["CompanyName"])
					product := info["ProductName"] + info["FileDescription"]
					scope = strings.Contains(product, "UU") && (strings.Contains(company, "netease") || strings.Contains(company, "网易")) && strings.EqualFold(info["OriginalFilename"], "GameViewer.exe")
				}
			}
		}
	}
	f, exists := a.seen[h]
	if !exists || f.Identity != id {
		f = focus_state{HWND: h, Identity: id, Token: new_id()}
		a.seen[h] = f
	}
	f.Scope = scope
	if len(a.seen) > 512 {
		a.seen = map[uintptr]focus_state{h: f}
		a.mark_source_gap(gap_focus_cache_overflow)
	}
	a.focus.Store(&f)
}
func (a *native_app) health() {
	var m uint32
	for _, v := range []struct {
		vk  uintptr
		bit uint32
	}{{0xa2, 1}, {0xa3, 2}, {0x5b, 4}, {0x5c, 8}, {0xa4, 16}, {0xa5, 32}, {0xa0, 64}, {0xa1, 128}} {
		n, _, _ := async_key.Call(v.vk)
		if uint16(n)&0x8000 != 0 {
			m |= v.bit
		}
	}
	if old := a.mods.Swap(m); old != m {
		a.mark_source_gap(gap_modifier_state_mismatch)
	}
	status := source_event{ID: a.event_id.Load(), Time: now_us(), Kind: "health", Mods: uint16(m)}
	select {
	case a.input <- status:
	default:
		a.mark_source_gap(gap_health_queue_overflow)
	}
}
func run_native() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	a := &native_app{commands: make(chan ui_command, 16), input: make(chan source_event, 512), lifecycle: make(chan uintptr, 512), seen: map[uintptr]focus_state{}, stop: make(chan struct{}), hook_ready: make(chan error, 1), hook_done: make(chan struct{}), network_done: make(chan struct{}), diag: &diagnostics{}, status: "未配置 Mac IP"}
	native = a
	var mutex_error error
	a.mutex, _, mutex_error = kernel32.NewProc("CreateMutexW").Call(0, 0, uintptr(unsafe.Pointer(utf(`Local\UUCommandBridgeSingleton`))))
	if a.mutex == 0 {
		return fmt.Errorf("无法创建单实例锁：%v", mutex_error)
	}
	if mutex_error == syscall.Errno(183) {
		call(kernel32, "CloseHandle", a.mutex)
		h := call(user32, "FindWindowW", uintptr(unsafe.Pointer(utf("UUBridgeTray"))), 0)
		if h != 0 {
			var pid uint32
			call(user32, "GetWindowThreadProcessId", h, uintptr(unsafe.Pointer(&pid)))
			call(user32, "AllowSetForegroundWindow", uintptr(pid))
			if call(user32, "PostMessageW", h, 0x8005, 0, 0) != 0 {
				return nil
			}
		}
		return errors.New("程序已启动，但设置窗口暂未就绪；请稍后再次双击。若持续无反应，可在任务管理器结束 UUCommandBridge 后重新打开")
	}
	defer call(kernel32, "CloseHandle", a.mutex)
	p, e := config_file()
	if e != nil {
		return e
	}
	a.cfg_path = p
	if b, e := os.ReadFile(p); e == nil {
		json.Unmarshal(b, &a.cfg)
		if a.cfg.Peer != "" {
			if _, e := ipv4(a.cfg.Peer); e != nil {
				a.cfg.Peer = ""
			}
		}
	}
	a.roots = install_roots()
	proc := syscall.NewCallback(wnd_proc)
	setting := syscall.NewCallback(settings_proc)
	a.callbacks = append(a.callbacks, proc, setting)
	for _, c := range []struct {
		name string
		proc uintptr
	}{{"UUBridgeTray", proc}, {"UUBridgeSettings", setting}} {
		wc := wndclass{Size: uint32(unsafe.Sizeof(wndclass{})), Proc: c.proc, Instance: call(kernel32, "GetModuleHandleW", 0), Name: utf(c.name), Cursor: call(user32, "LoadCursorW", 0, 32512), Background: 6, Icon: application_icon(ui_scale(32, window_dpi(0))), SmallIcon: application_icon(ui_scale(16, window_dpi(0)))}
		if call(user32, "RegisterClassExW", uintptr(unsafe.Pointer(&wc))) == 0 {
			return errors.New("窗口注册失败")
		}
	}
	a.hwnd = call(user32, "CreateWindowExW", 0, uintptr(unsafe.Pointer(utf("UUBridgeTray"))), uintptr(unsafe.Pointer(utf("UU 局域网辅助"))), 0, 0, 0, 0, 0, 0, 0, 0, 0)
	if a.hwnd == 0 {
		return errors.New("托盘窗口创建失败")
	}
	a.taskbar_created = uint32(call(user32, "RegisterWindowMessageW", uintptr(unsafe.Pointer(utf("TaskbarCreated")))))
	if a.taskbar_created == 0 {
		call(user32, "DestroyWindow", a.hwnd)
		return errors.New("无法注册任务栏恢复通知")
	}
	if e = a.tray(true); e != nil {
		call(user32, "DestroyWindow", a.hwnd)
		return e
	}
	if e = a.settings(); e != nil {
		call(user32, "DestroyWindow", a.hwnd)
		return e
	}
	go a.hooks()
	if e = <-a.hook_ready; e != nil {
		call(user32, "DestroyWindow", a.hwnd)
		return e
	}
	go a.network()
	a.ui_loop_started = true
	var m msg
	for {
		v := call(user32, "GetMessageW", uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if v == 0 || int32(v) == -1 {
			break
		}
		if a.dialog == 0 || call(user32, "IsDialogMessageW", a.dialog, uintptr(unsafe.Pointer(&m))) == 0 {
			call(user32, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
			call(user32, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
		}
	}
	select {
	case <-a.hook_done:
	case <-time.After(time.Second):
	}
	select {
	case <-a.network_done:
	case <-time.After(time.Second):
	}
	return nil
}

func native_offline_check() (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("Win32 回调 ABI: %v", p)
		}
	}()
	if unsafe.Sizeof(msg{}) != 48 || unsafe.Sizeof(wndclass{}) != 80 || unsafe.Sizeof(notifyicon{}) != 976 || unsafe.Sizeof(keyboard{}) != 24 || unsafe.Sizeof(mouse{}) != 32 {
		return errors.New("Win32 结构大小错误")
	}
	// Windows x64 的 lpTemplateName 位于 128，之后的 pvReserved 位于 136。
	if unsafe.Sizeof(open_file_name{}) != 152 || unsafe.Offsetof(open_file_name{}.File) != 48 || unsafe.Offsetof(open_file_name{}.Flags) != 96 || unsafe.Offsetof(open_file_name{}.Reserved) != 136 {
		return fmt.Errorf("Win32 保存对话框结构布局错误: size=%d File=%d Flags=%d Reserved=%d", unsafe.Sizeof(open_file_name{}), unsafe.Offsetof(open_file_name{}.File), unsafe.Offsetof(open_file_name{}.Flags), unsafe.Offsetof(open_file_name{}.Reserved))
	}
	syscall.NewCallback(wnd_proc)
	syscall.NewCallback(settings_proc)
	syscall.NewCallback(keyboard_proc)
	syscall.NewCallback(mouse_proc)
	syscall.NewCallback(event_proc)
	return nil
}
