package main

import (
	"encoding/json"
	"sync"
	"time"
)

type diagnostic struct {
	Time     string    `json:"time"`
	Reason   string    `json:"reason"`
	captured time.Time `json:"-"`
}
type diagnostics struct {
	mu      sync.Mutex
	records []diagnostic
	bytes   int
	counts  map[string]uint64
}

func (d *diagnostics) add(reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.counts == nil {
		d.counts = map[string]uint64{}
	}
	d.counts[reason]++
	n := time.Now()
	d.prune_expired(n)
	for len(d.records) > 0 && (len(d.records) >= 512 || d.bytes+len(reason)+64 > 1024*1024) {
		d.bytes -= len(d.records[0].Reason) + 64
		d.records = d.records[1:]
	}
	d.records = append(d.records, diagnostic{n.Format(time.RFC3339Nano), reason, n})
	d.bytes += len(reason) + 64
}
func (d *diagnostics) export(status any) []byte {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.prune_expired(time.Now())
	b, _ := json.MarshalIndent(struct {
		Status   any               `json:"status"`
		Counters map[string]uint64 `json:"counters"`
		Recent   []diagnostic      `json:"recent"`
	}{status, d.counts, d.records}, "", "  ")
	return b
}

type stream_state struct {
	Instance, Peer, Epoch, Window, Bound string
	Generation                           uint64
	Stopped                              bool
	Active                               bool
	Scope                                bool
	Paused                               bool
	Lease                                int64
	last_seq                             uint64
	retired                              map[string]bool
	recent                               []source_event
	Gap                                  bool
	Boundary                             int64
}

func (s *stream_state) reset() {
	if s.retired == nil {
		s.retired = map[string]bool{}
	}
	if s.Epoch != "" {
		s.retired[s.Epoch] = true
	}
	s.Peer = ""
	s.Epoch = ""
	s.Generation = 0
	s.Stopped = true
	s.Active = false
	s.Bound = ""
	s.last_seq = 0
	s.recent = nil
	s.Gap = true
}
func (s *stream_state) eligible() bool {
	return s.Scope && !s.Paused && s.Window != "" && (s.Bound == "" || s.Bound == s.Window)
}
func (s *stream_state) stop() { s.Active = false; s.Stopped = true; s.Lease = 0 }
func (s *stream_state) focus(window string, scope bool) {
	if window != s.Window || scope != s.Scope {
		s.stop()
		s.recent = nil
		s.Gap = true
	}
	s.Window = window
	s.Scope = scope
}
func (s *stream_state) capture(e source_event, at int64) bool {
	if !s.Scope || s.Paused || e.Window != s.Window || e.Time < s.Boundary || e.Time < at-1000000 {
		return false
	}
	cut := at - 1000000
	for len(s.recent) > 0 && s.recent[0].Time < cut {
		s.recent = s.recent[1:]
	}
	if len(s.recent) >= 512 {
		s.recent = nil
		s.Gap = true
	}
	s.recent = append(s.recent, e)
	return true
}
func (s *stream_state) accept(p packet, at int64) bool {
	if p.Peer != s.Instance {
		return false
	}
	if p.Kind == "hello" {
		if p.Epoch == "" || s.retired[p.Epoch] {
			return false
		}
		if p.Epoch != s.Epoch || p.Instance != s.Peer {
			s.reset()
			s.Peer = p.Instance
			s.Epoch = p.Epoch
			s.last_seq = p.Seq
			s.Stopped = true
			return true
		}
		if p.Seq <= s.last_seq {
			return false
		}
		s.last_seq = p.Seq
		return true
	}
	if p.Instance != s.Peer || p.Epoch != s.Epoch || p.Seq <= s.last_seq {
		return false
	}
	s.last_seq = p.Seq
	switch p.Kind {
	case "start":
		if p.Generation < s.Generation || p.Generation == s.Generation && s.Stopped || !s.Scope || s.Paused || p.Window != s.Window {
			return false
		}
		if p.Generation > s.Generation {
			if s.Bound != s.Window {
				s.Bound = ""
			}
			s.Generation = p.Generation
			s.Stopped = false
		}
		s.Active = true
		s.Lease = at + 2500000
		return true
	case "stop":
		if p.Generation < s.Generation {
			return false
		}
		s.Generation = p.Generation
		s.stop()
		return true
	case "bind":
		if p.Generation != s.Generation || !s.Active || p.Window != s.Window {
			return false
		}
		s.Bound = p.Window
		return true
	case "ping":
		return p.Generation >= s.Generation
	default:
		return false
	}
}
func (s *stream_state) tick(at int64) {
	if s.Active && (at >= s.Lease || !s.eligible()) {
		s.stop()
	}
}

// Physical scan-code mapping, independent of keyboard layout and characters.
func scan_usage(scan uint32, extended bool) uint16 {
	if extended {
		switch scan {
		case 0x1c:
			return 88
		case 0x1d:
			return 228
		case 0x38:
			return 230
		case 0x47:
			return 74
		case 0x48:
			return 82
		case 0x49:
			return 75
		case 0x4b:
			return 80
		case 0x4d:
			return 79
		case 0x4f:
			return 77
		case 0x50:
			return 81
		case 0x51:
			return 78
		case 0x52:
			return 73
		case 0x53:
			return 76
		case 0x35:
			return 84
		case 0x5b:
			return 227
		case 0x5c:
			return 231
		case 0x5d:
			return 101
		default:
			return 0
		}
	}
	m := map[uint32]uint16{0x01: 41, 0x02: 30, 0x03: 31, 0x04: 32, 0x05: 33, 0x06: 34, 0x07: 35, 0x08: 36, 0x09: 37, 0x0a: 38, 0x0b: 39, 0x0c: 45, 0x0d: 46, 0x0e: 42, 0x0f: 43, 0x10: 20, 0x11: 26, 0x12: 8, 0x13: 21, 0x14: 23, 0x15: 28, 0x16: 24, 0x17: 12, 0x18: 18, 0x19: 19, 0x1a: 47, 0x1b: 48, 0x1c: 40, 0x1d: 224, 0x1e: 4, 0x1f: 22, 0x20: 7, 0x21: 9, 0x22: 10, 0x23: 11, 0x24: 13, 0x25: 14, 0x26: 15, 0x27: 51, 0x28: 52, 0x29: 53, 0x2a: 225, 0x2b: 49, 0x2c: 29, 0x2d: 27, 0x2e: 6, 0x2f: 25, 0x30: 5, 0x31: 17, 0x32: 16, 0x33: 54, 0x34: 55, 0x35: 56, 0x36: 229, 0x37: 85, 0x38: 226, 0x39: 44, 0x3a: 57, 0x3b: 58, 0x3c: 59, 0x3d: 60, 0x3e: 61, 0x3f: 62, 0x40: 63, 0x41: 64, 0x42: 65, 0x43: 66, 0x44: 67, 0x45: 83, 0x46: 71, 0x47: 95, 0x48: 96, 0x49: 97, 0x4a: 86, 0x4b: 92, 0x4c: 93, 0x4d: 94, 0x4e: 87, 0x4f: 89, 0x50: 90, 0x51: 91, 0x52: 98, 0x53: 99, 0x56: 100, 0x57: 68, 0x58: 69}
	return m[scan]
}
func usage_mod(usage uint16) uint16 {
	switch usage {
	case 224:
		return 1
	case 228:
		return 2
	case 227:
		return 4
	case 231:
		return 8
	case 226:
		return 16
	case 230:
		return 32
	case 225:
		return 64
	case 229:
		return 128
	}
	return 0
}

// A snapshot describes the last consumed source sample, never the later UDP send.
// Keeping its capture time prevents a delayed queue from proving a future interval.
type processed_source_state struct {
	Mods      uint16
	HighestID uint64
	Time      int64
	Ready     bool
}

func (s *processed_source_state) consume(e source_event) {
	if e.ID > s.HighestID {
		s.HighestID = e.ID
	}
	s.Mods = e.Mods
	s.Time = e.Time
	s.Ready = true
}
func (s *processed_source_state) snapshot(window string, gap bool) packet {
	mods, id := s.Mods, s.HighestID
	return packet{Kind: "snapshot", Time: s.Time, Window: window, Mods: &mods, EventSeq: &id, Gap: gap}
}
func packet_time(p packet, sent int64) int64 {
	if p.Kind == "snapshot" && p.Time > 0 {
		return p.Time
	}
	return sent
}

// Shared by the native UDP sender and offline protocol regressions.
func (s *stream_state) envelope(p packet, seq uint64, at int64, discovery bool) packet {
	p.V = 1
	p.Instance = s.Instance
	p.Peer = s.Peer
	p.Epoch = s.Epoch
	if discovery && p.Kind == "hello" {
		p.Peer = ""
		p.Epoch = ""
	}
	p.Generation = s.Generation
	p.Seq = seq
	p.Time = packet_time(p, at)
	return p
}
func (s *stream_state) discovery_due(last_heard, at int64) bool {
	return s.Peer == "" || at-last_heard > 3000000
}
func (s *stream_state) set_paused(paused bool, at int64, source *processed_source_state) {
	s.stop()
	s.Paused = paused
	s.source_boundary(at, source)
}
func (s *processed_source_state) consume_after(e source_event, boundary int64) bool {
	if e.Time < boundary {
		return false
	}
	s.consume(e)
	return true
}

func (s *stream_state) source_boundary(at int64, source *processed_source_state) {
	s.Boundary = at
	s.recent = nil
	s.Gap = true
	*source = processed_source_state{}
}

func (d *diagnostics) prune_expired(at time.Time) {
	cut := at.Add(-2 * time.Minute)
	for len(d.records) > 0 && d.records[0].captured.Before(cut) {
		d.bytes -= len(d.records[0].Reason) + 64
		d.records = d.records[1:]
	}
}

// Evaluate before accept advances the incoming sequence.
func (s *stream_state) stopped_start(p packet) bool {
	return p.Kind == "start" && p.Peer == s.Instance && p.Instance == s.Peer && p.Epoch != "" && p.Epoch == s.Epoch && p.Seq > s.last_seq && p.Generation == s.Generation && s.Stopped
}

// A cycle with only discarded queued samples cannot certify the boundary.
func (s *stream_state) snapshot_cycle(source *processed_source_state, at int64, send_snapshot func(packet), send_events func([]source_event)) {
	sent := source.Ready && source.Time > 0
	if sent {
		send_snapshot(source.snapshot(s.Window, s.Gap))
	}
	cut := at - 1000000
	for len(s.recent) > 0 && s.recent[0].Time < cut {
		s.recent = s.recent[1:]
	}
	send_events(s.recent)
	if sent {
		s.Gap = false
	}
}
