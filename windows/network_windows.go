//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type incoming struct {
	p  packet
	at int64
}

func (a *native_app) record_source_gap() {
	// 并发标记可归入相邻边界；原因仅用于诊断，不作为历史连续性的证明。
	reasons := a.gap_reasons.Swap(0)
	a.diag.add("source_continuity_gap")
	for _, reason := range []struct {
		Bit  uint32
		Name string
	}{
		{gap_modifier_state_mismatch, "modifier_state_mismatch"},
		{gap_input_queue_overflow, "input_queue_overflow"},
		{gap_health_queue_overflow, "health_queue_overflow"},
		{gap_foreground_changed_before_verify, "foreground_changed_before_verify"},
		{gap_lifecycle_queue_overflow, "lifecycle_queue_overflow"},
		{gap_focused_window_lifecycle_changed, "focused_window_lifecycle_changed"},
		{gap_focus_cache_overflow, "focus_cache_overflow"},
	} {
		if reasons&reason.Bit != 0 {
			a.diag.add(reason.Name)
		}
	}
}

func (a *native_app) network() {
	defer close(a.network_done)
	s := stream_state{Instance: new_id(), Paused: a.cfg.Paused, retired: map[string]bool{}}
	conn, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: udp_port})
	if e != nil {
		a.diag.add("udp_bind_failed")
		a.set_status("UDP 47731 无法监听；退出后检查端口")
	}
	if conn != nil {
		defer conn.Close()
	}
	done := make(chan struct{})
	defer close(done)
	rx := make(chan incoming, 512)
	var peerIP net.IP
	if a.cfg.Peer != "" {
		peerIP, _ = ipv4(a.cfg.Peer)
	}
	var peerMu = make(chan struct{}, 1)
	peerMu <- struct{}{}
	go func() {
		if conn == nil {
			return
		}
		b := make([]byte, max_packet+1)
		for {
			conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
			n, addr, e := conn.ReadFromUDP(b)
			if e != nil {
				select {
				case <-done:
					return
				default:
					continue
				}
			}
			<-peerMu
			ip := peerIP
			peerMu <- struct{}{}
			if ip == nil || addr.Port != udp_port || !addr.IP.Equal(ip) {
				continue
			}
			p, e := decode_packet(b[:n])
			if e != nil {
				a.diag.add("packet_rejected")
				continue
			}
			select {
			case rx <- incoming{p, now_us()}:
			default:
				a.diag.add("receive_queue_overflow")
			}
		}
	}()
	var seq uint64
	send_to := func(p packet, discovery bool) {
		if s.Peer == "" && p.Kind != "hello" {
			return
		}
		<-peerMu
		ip := peerIP
		peerMu <- struct{}{}
		if ip == nil || conn == nil {
			return
		}
		seq++
		p = s.envelope(p, seq, now_us(), discovery)
		b, e := json.Marshal(p)
		if e != nil || len(b) > max_packet {
			a.diag.add("send_packet_rejected")
			return
		}
		conn.SetWriteDeadline(time.Now().Add(200 * time.Millisecond))
		if _, e = conn.WriteToUDP(b, &net.UDPAddr{IP: ip, Port: udp_port}); e != nil {
			a.diag.add("udp_send_failed")
		}
	}
	send := func(p packet) { send_to(p, false) }
	scope_packet := func(kind string) packet {
		scope := s.Scope && !s.Paused
		return packet{Kind: kind, Window: s.Window, Scope: &scope}
	}
	stop := func() {
		if s.Active {
			send(scope_packet("stop"))
			a.diag.add("stream_stopped")
		}
		s.stop()
	}
	send_events := func(events []source_event) {
		f := a.fast_focus()
		if !s.Active || len(events) == 0 || f == nil || !f.Scope || f.Token != s.Window {
			return
		}
		base := packet{V: 1, Kind: "events", Instance: s.Instance, Peer: s.Peer, Epoch: s.Epoch, Generation: s.Generation, Seq: seq + 1, Time: now_us(), Window: s.Window, Gap: s.Gap}
		parts, e := event_packets(base, events)
		if e != nil {
			a.diag.add("event_batch_rejected")
			return
		}
		for _, p := range parts {
			send(p)
		}
	}
	var source_state processed_source_state
	process_input := func(ev source_event) {
		if a.overflow.Swap(false) {
			s.source_boundary(now_us(), &source_state)
			a.record_source_gap()
		}
		if !source_state.consume_after(ev, s.Boundary) {
			return
		}
		if ev.Kind == "health" {
			return
		}
		if !s.Paused && s.capture(ev, now_us()) && s.Active {
			send_events([]source_event{ev})
		}
	}
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	lastHello, lastSnapshot, lastHealth, lastVerify, lastHeard := int64(-1000000), int64(0), int64(0), int64(-1000000), int64(0)
	var last_status string
	a.dirty.Store(true)
	for {
		select {
		case <-a.stop:
			stop()
			return
		case c := <-a.commands:
			switch c.Kind {
			case "peer":
				a.mu.Lock()
				unchanged := a.cfg.Peer == c.Value
				a.mu.Unlock()
				if unchanged {
					continue
				}
				stop()
				s.reset()
				<-peerMu
				peerIP = nil
				if c.Value != "" {
					peerIP, _ = ipv4(c.Value)
				}
				peerMu <- struct{}{}
				a.mu.Lock()
				a.cfg.Peer = c.Value
				e = a.save()
				a.mu.Unlock()
				if e != nil {
					message("配置保存失败", e.Error())
				}
				lastHeard = 0
				lastHello = -1000000
				a.diag.add("peer_configuration_changed")
			case "pause":
				stop()
				s.set_paused(!s.Paused, now_us(), &source_state)
				a.mu.Lock()
				a.cfg.Paused = s.Paused
				e = a.save()
				a.mu.Unlock()
				if e != nil {
					message("配置保存失败", e.Error())
				}
				a.diag.add("pause_changed")
			case "export":
				if c.Value == "" {
					continue
				}
				a.mu.Lock()
				status := a.status
				a.mu.Unlock()
				data := a.diag.export(struct {
					State      string `json:"state"`
					Configured bool   `json:"configured"`
					Paused     bool   `json:"paused"`
					Active     bool   `json:"active"`
				}{status, peerIP != nil, s.Paused, s.Active})
				go func(path string, data []byte) {
					if write_error := os.WriteFile(path, data, 0600); write_error != nil {
						a.finish_diagnostic_export("导出失败", write_error.Error())
					} else {
						a.finish_diagnostic_export("诊断已导出", path)
					}
				}(c.Value, data)
			}
		case in := <-rx:
			p := in.p
			wasActive := s.Active
			feedback_stop := s.stopped_start(p)
			if !s.accept(p, in.at) {
				if feedback_stop {
					send(scope_packet("stop"))
				}
				continue
			}
			lastHeard = in.at
			switch p.Kind {
			case "hello":
				send(scope_packet("hello"))
			case "ping":
				if p.Generation >= s.Generation {
					recv := in.at
					echo := p.Time
					pong := packet{Kind: "pong", Echo: &echo, Recv: &recv}
					saved := s.Generation
					s.Generation = p.Generation
					send(pong)
					s.Generation = saved
				}
			case "start":
				if !wasActive {
					a.diag.add("stream_started")
					send_events(s.recent)
				}
			case "stop":
				a.diag.add("controller_stopped")
			case "bind":
				a.diag.add("window_bound")
			}
		case ev := <-a.input:
			process_input(ev)

		case <-ticker.C:
			at := now_us()
			if a.dirty.Swap(false) || at-lastVerify >= 1000000 {
				a.verify_focus()
				lastVerify = at
			}
			f := a.focus.Load()
			window := ""
			scope := false
			if f != nil {
				window = f.Token
				scope = f.Scope
			}
			if window != s.Window || scope != s.Scope {
				stop()
				s.focus(window, scope)
				s.source_boundary(at, &source_state)
				if scope && !s.Paused {
					send(scope_packet("prepare"))
					a.diag.add("eligible_window_changed")
				}
			}
			if a.overflow.Swap(false) {
				s.source_boundary(at, &source_state)
				a.record_source_gap()
			}
			if at-lastHealth >= 100000 {
				call(user32, "PostThreadMessageW", uintptr(a.hook_thread.Load()), 0x8004, 0, 0)
				lastHealth = at
			}
			if s.discovery_due(lastHeard, at) {
				stop()
			}
			before := s.Active
			s.tick(at)
			if before && !s.Active {
				send(scope_packet("stop"))
				a.diag.add("lease_expired")
			}
			if s.Active && at-lastSnapshot >= 100000 {
				for i := 0; i < 512; i++ {
					select {
					case ev := <-a.input:
						process_input(ev)
					default:
						goto input_drained
					}
				}
			input_drained:
				s.snapshot_cycle(&source_state, at, send, send_events)
				lastSnapshot = at
			}
			if at-lastHello >= 1000000 {
				kind := "heartbeat"
				discovery := s.discovery_due(lastHeard, at)
				if discovery {
					kind = "hello"
				}
				send_to(scope_packet(kind), discovery)
				lastHello = at
			}
			status := "等待 Mac 连接"
			if peerIP == nil {
				status = "未配置 Mac IP"
			} else if s.Paused {
				status = "同步已暂停"
			} else if lastHeard > 0 && at-lastHeard <= 3000000 {
				if s.Active {
					status = "正在同步 · 等待 Mac 校验/学习"
					if s.Bound == s.Window {
						status = "正在同步 · 远程窗口已绑定"
					}
				} else if !s.Scope {
					status = "已连接 · 正在操作 Windows 本地"
				} else {
					status = "已连接 · 等待 Mac 的 UU 输入"
				}
			}
			if conn == nil {
				status = "UDP 47731 无法监听；退出后检查端口"
			}
			if status != last_status {
				a.set_status(status)
				last_status = status
			}
		}
	}
}
func self_report(path string) error {
	roots := install_roots()
	h := call(user32, "GetForegroundWindow")
	id, e := identity(h)
	type report struct {
		Architecture   string            `json:"architecture"`
		InstallRoots   []string          `json:"uu_install_roots"`
		ForegroundPID  uint32            `json:"foreground_pid"`
		ForegroundPath string            `json:"foreground_exe_path"`
		QueryError     string            `json:"query_error,omitempty"`
		Product        map[string]string `json:"product"`
		Port           int               `json:"udp_port"`
		Notes          []string          `json:"notes"`
	}
	r := report{Architecture: "windows/amd64", InstallRoots: roots, ForegroundPID: id.PID, ForegroundPath: id.Path, Port: udp_port, Notes: []string{"此报告不包含窗口标题、普通键码、坐标或真实输入。", "实际托盘、焦点切换和 UDP 仍须 Windows 实机确认。"}}
	if e != nil {
		r.QueryError = e.Error()
	} else if strings.EqualFold(filepath.Base(id.Path), "GameViewer.exe") {
		r.Product = product_info(id.Path)
	}
	b, e := json.MarshalIndent(r, "", "  ")
	if e != nil {
		return e
	}
	if path == "" {
		return fmt.Errorf("--report 需要指定输出文件")
	}
	return os.WriteFile(path, b, 0600)
}
