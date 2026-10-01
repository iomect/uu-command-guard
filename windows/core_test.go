package main

import (
	"encoding/json"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

const win_uuid = "11111111-1111-4111-8111-111111111111"
const mac_uuid = "22222222-2222-4222-8222-222222222222"
const epoch_uuid = "33333333-3333-4333-8333-333333333333"
const window_uuid = "44444444-4444-4444-8444-444444444444"

func valid_packet() packet {
	return packet{V: 1, Kind: "events", Instance: win_uuid, Peer: mac_uuid, Epoch: epoch_uuid, Generation: 1, Seq: 1, Time: 1000000, Window: window_uuid, Events: []source_event{{ID: 1, Time: 999000, Window: window_uuid, Kind: "key", Key: 25, Action: "down", Mods: 1}}}
}
func TestProtocolSharedSample(t *testing.T) {
	b, e := os.ReadFile("../protocol/sample.json")
	if e != nil {
		t.Fatal(e)
	}
	p, e := decode_packet(b)
	if e != nil {
		t.Fatal(e)
	}
	if p.Kind != "events" || len(p.Events) != 1 || p.Events[0].Key != 25 || p.Events[0].Mods != 1 {
		t.Fatal("cross-language sample changed")
	}
}
func TestProtocolStrictTypes(t *testing.T) {
	b, _ := json.Marshal(valid_packet())
	for _, bad := range []string{strings.Replace(string(b), `"seq":1`, `"seq":1.5`, 1), strings.Replace(string(b), `"mods":1`, `"mods":"1"`, 1), strings.Replace(string(b), `"mods":1`, `"mods":null`, 1), strings.Replace(string(b), `"kind":"events"`, `"kind":"events","kind":"stop"`, 1), strings.Replace(string(b), `"key":25`, `"key":25,"key":4`, 1), strings.Replace(string(b), `"v":1`, `"v":2`, 1), strings.Replace(string(b), `"seq":1`, `"seq":1,"unknown":1`, 1), strings.Replace(string(b), win_uuid, "not-uuid", 1), strings.Replace(string(b), `"time_us":999000`, `"time_us":1000001`, 1), strings.Replace(string(b), `"mods":1`, `"mods":256`, 1), strings.Replace(string(b), `"kind":"key"`, `"kind":"text"`, 1)} {
		if _, e := decode_packet([]byte(bad)); e == nil {
			t.Fatalf("invalid accepted: %s", bad)
		}
	}
	if _, e := decode_packet(append(b, []byte("{}")...)); e == nil {
		t.Fatal("trailing JSON accepted")
	}
}
func TestPacketSizeAndSplit(t *testing.T) {
	p := valid_packet()
	events := []source_event{}
	for i := uint64(1); i <= 512; i++ {
		events = append(events, source_event{ID: i, Time: int64(i), Window: window_uuid, Kind: "key", Key: 4, Action: "down", Mods: 255})
	}
	p.Events = nil
	parts, e := event_packets(p, events)
	if e != nil {
		t.Fatal(e)
	}
	if len(parts) < 2 {
		t.Fatal("not split")
	}
	n := 0
	for _, v := range parts {
		b, _ := json.Marshal(v)
		if len(b) > 1200 {
			t.Fatal("oversize")
		}
		if _, e := decode_packet(b); e != nil {
			t.Fatal(e)
		}
		n += len(v.Events)
	}
	if n != 512 {
		t.Fatal("event dropped")
	}
	if _, e := decode_packet(make([]byte, 1201)); e == nil {
		t.Fatal("size accepted")
	}
}
func initialized_state(t *testing.T) *stream_state {
	s := &stream_state{Instance: win_uuid, Window: window_uuid, Scope: true, retired: map[string]bool{}}
	if !s.accept(packet{Kind: "hello", Instance: mac_uuid, Peer: win_uuid, Epoch: epoch_uuid, Seq: 1}, 0) {
		t.Fatal("hello")
	}
	return s
}
func control(kind string, gen, seq uint64) packet {
	return packet{Kind: kind, Instance: mac_uuid, Peer: win_uuid, Epoch: epoch_uuid, Generation: gen, Seq: seq, Window: window_uuid}
}
func TestGenerationAndLease(t *testing.T) {
	s := initialized_state(t)
	if !s.accept(control("start", 1, 2), 100) || !s.Active {
		t.Fatal("start")
	}
	if s.accept(control("start", 1, 2), 200) {
		t.Fatal("duplicate")
	}
	if !s.accept(control("start", 1, 3), 200) || s.Lease != 2500200 {
		t.Fatal("lease")
	}
	s.tick(2500200)
	if s.Active {
		t.Fatal("expired")
	}
	if s.accept(control("start", 1, 4), 2500201) {
		t.Fatal("stopped revived")
	}
	if !s.accept(control("start", 2, 5), 2500202) {
		t.Fatal("new generation")
	}
	if s.accept(control("stop", 1, 6), 2500203) || !s.Active {
		t.Fatal("old stop")
	}
	if !s.accept(control("stop", 2, 7), 2500204) || s.Active {
		t.Fatal("stop")
	}
	if s.accept(control("start", 2, 8), 2500205) {
		t.Fatal("stopped revived")
	}
}
func TestRestartRetiresEpoch(t *testing.T) {
	s := initialized_state(t)
	p := control("hello", 0, 2)
	p.Epoch = "55555555-5555-4555-8555-555555555555"
	if !s.accept(p, 1) {
		t.Fatal("new epoch")
	}
	p.Epoch = epoch_uuid
	p.Seq = 100
	if s.accept(p, 2) {
		t.Fatal("retired epoch revived")
	}
	p.Peer = mac_uuid
	if s.accept(p, 3) {
		t.Fatal("wrong recipient")
	}
}
func TestBindingFocusAndWindowRelearn(t *testing.T) {
	s := initialized_state(t)
	s.accept(control("start", 1, 2), 0)
	if !s.accept(control("bind", 1, 3), 1) || s.Bound != window_uuid {
		t.Fatal("bind")
	}
	newwindow := "66666666-6666-4666-8666-666666666666"
	s.focus(newwindow, true)
	if s.Active {
		t.Fatal("focus exit")
	}
	p := control("start", 1, 4)
	p.Window = newwindow
	if s.accept(p, 2) {
		t.Fatal("same-generation window change")
	}
	p.Generation = 2
	p.Seq = 5
	if !s.accept(p, 3) || s.Bound != "" {
		t.Fatal("new window must relearn")
	}
	s.Paused = true
	s.tick(4)
	if s.Active {
		t.Fatal("paused")
	}
}
func TestHistoryBoundsAndGap(t *testing.T) {
	s := initialized_state(t)
	for i := uint64(1); i <= 512; i++ {
		s.capture(source_event{ID: i, Time: int64(i), Window: window_uuid}, int64(i))
	}
	if len(s.recent) != 512 {
		t.Fatal(len(s.recent))
	}
	s.Gap = false
	s.capture(source_event{ID: 513, Time: 513, Window: window_uuid}, 513)
	if !s.Gap || len(s.recent) != 1 {
		t.Fatal("overflow retained uncertified past")
	}
	s.capture(source_event{ID: 514, Time: 1000514, Window: window_uuid}, 1000514)
	if len(s.recent) != 1 {
		t.Fatal("expired retained")
	}
	s.Boundary = 2000000
	s.capture(source_event{ID: 515, Time: 1999999, Window: window_uuid}, 2000000)
	if len(s.recent) != 1 {
		t.Fatal("pre-gap event entered")
	}
	s.capture(source_event{ID: 516, Time: 2000001, Window: "wrong"}, 2000001)
	if len(s.recent) != 1 {
		t.Fatal("other window entered")
	}
}
func TestModifiersAndScanMapping(t *testing.T) {
	for _, c := range []struct {
		scan       uint32
		ext        bool
		usage, bit uint16
	}{{0x1d, false, 224, 1}, {0x1d, true, 228, 2}, {0x5b, true, 227, 4}, {0x5c, true, 231, 8}, {0x38, false, 226, 16}, {0x38, true, 230, 32}, {0x2a, false, 225, 64}, {0x36, false, 229, 128}, {0x1e, false, 4, 0}, {0x2f, false, 25, 0}, {0x48, true, 82, 0}, {0xff, true, 0, 0}} {
		u := scan_usage(c.scan, c.ext)
		if u != c.usage || usage_mod(u) != c.bit {
			t.Fatal(c, u)
		}
	}
}
func TestDiagnosticsBoundedAndRedacted(t *testing.T) {
	d := diagnostics{}
	for i := 0; i < 2000; i++ {
		d.add("source_continuity_gap")
	}
	if len(d.records) > 512 || d.bytes > 1024*1024 {
		t.Fatal("unbounded")
	}
	b := string(d.export("已连接"))
	for _, s := range []string{`"key"`, `"events"`, `"mods"`, `"coordinates"`} {
		if strings.Contains(b, s) {
			t.Fatal("sensitive diagnostic")
		}
	}
	if !strings.Contains(b, "source_continuity_gap") {
		t.Fatal("missing counters")
	}
}
func TestOfflineCheck(t *testing.T) {
	if e := offline_check(); e != nil {
		t.Fatal(e)
	}
}
func TestColdHandshakeWire(t *testing.T) {
	w := stream_state{Instance: win_uuid, retired: map[string]bool{}}
	initial := packet{V: 1, Kind: "hello", Instance: win_uuid, Peer: "", Epoch: "", Seq: 1, Time: 0}
	b, _ := json.Marshal(initial)
	p, e := decode_packet(b)
	if e != nil || p.Peer != "" || p.Epoch != "" {
		t.Fatalf("cold hello: %v", e)
	}
	response := packet{V: 1, Kind: "hello", Instance: mac_uuid, Peer: p.Instance, Epoch: epoch_uuid, Seq: 1, Time: 100}
	b, _ = json.Marshal(response)
	p, e = decode_packet(b)
	if e != nil || !w.accept(p, 200) {
		t.Fatalf("targeted controller hello: %v", e)
	}
	ack := packet{V: 1, Kind: "hello", Instance: w.Instance, Peer: w.Peer, Epoch: w.Epoch, Seq: 2, Time: 250}
	b, _ = json.Marshal(ack)
	p, e = decode_packet(b)
	if e != nil || p.Peer != mac_uuid || p.Epoch != epoch_uuid {
		t.Fatalf("Win acknowledgement: %v", e)
	}
}
func TestIPv4Literal(t *testing.T) {
	for _, v := range []string{"", "localhost", "::1", "0.0.0.0", "255.255.255.255", "224.0.0.1", "10.0.0.1:47731"} {
		if _, e := ipv4(v); e == nil {
			t.Fatal(v)
		}
	}
	if _, e := ipv4("192.0.2.10"); e != nil {
		t.Fatal(e)
	}
}
func TestDelayedQueueSnapshotKeepsCaptureTime(t *testing.T) {
	var s processed_source_state
	s.consume(source_event{ID: 10, Time: 100000, Mods: 1})
	p := s.snapshot(window_uuid, false)
	p.Time = packet_time(p, 900000)
	if p.Time != 100000 || *p.EventSeq != 10 || *p.Mods != 1 {
		t.Fatal("snapshot extended old state to send time")
	}
	s.consume(source_event{ID: 11, Time: 150000, Mods: 0})
	p = s.snapshot(window_uuid, false)
	p.Time = packet_time(p, 1000000)
	if p.Time != 150000 || *p.Mods != 0 {
		t.Fatal("queued release incorrectly proves later state")
	}
	s.consume(source_event{ID: 11, Time: 200000, Kind: "health", Mods: 0})
	p = s.snapshot(window_uuid, true)
	p.Time = packet_time(p, 1100000)
	if p.Time != 200000 || *p.EventSeq != 11 || !p.Gap {
		t.Fatal("health capture timestamp lost")
	}
	if packet_time(packet{Kind: "pong", Time: 100}, 900) != 900 {
		t.Fatal("pong must use send time")
	}
}

func TestDelayedQueueSnapshotUDP(t *testing.T) {
	receiver, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if e != nil {
		t.Fatal(e)
	}
	defer receiver.Close()
	sender, e := net.DialUDP("udp4", nil, receiver.LocalAddr().(*net.UDPAddr))
	if e != nil {
		t.Fatal(e)
	}
	defer sender.Close()
	q := make(chan source_event, 2)
	q <- source_event{ID: 1, Time: 100000, Mods: 1}
	q <- source_event{ID: 2, Time: 150000, Mods: 0}
	var state processed_source_state
	state.consume(<-q)
	state.consume(<-q)
	p := state.snapshot(window_uuid, true)
	p.V = 1
	p.Instance = win_uuid
	p.Peer = mac_uuid
	p.Epoch = epoch_uuid
	p.Seq = 1
	p.Generation = 1
	p.Time = packet_time(p, 900000)
	wire, _ := json.Marshal(p)
	if _, e = sender.Write(wire); e != nil {
		t.Fatal(e)
	}
	receiver.SetReadDeadline(time.Now().Add(time.Second))
	b := make([]byte, 1201)
	n, _, e := receiver.ReadFromUDP(b)
	if e != nil {
		t.Fatal(e)
	}
	received, e := decode_packet(b[:n])
	if e != nil {
		t.Fatal(e)
	}
	if received.Time != 150000 || *received.EventSeq != 2 || *received.Mods != 0 || !received.Gap {
		t.Fatal("UDP delayed snapshot fabricated freshness")
	}
}

func TestDiscoveryRecoversSameOrRestartedController(t *testing.T) {
	for _, restarted := range []bool{false, true} {
		s := initialized_state(t)
		s.accept(control("start", 1, 2), 100)
		if s.discovery_due(100, 3000100) {
			t.Fatal("discovery before timeout")
		}
		if !s.discovery_due(100, 3000101) {
			t.Fatal("missing discovery")
		}
		s.stop()
		p := s.envelope(packet{Kind: "hello"}, 10, 3000101, true)
		b, _ := json.Marshal(p)
		wire, err := decode_packet(b)
		if err != nil || wire.Peer != "" || wire.Epoch != "" || s.Active {
			t.Fatalf("discovery still targets old controller: %+v, %v", wire, err)
		}
		response := control("hello", 0, 3)
		if restarted {
			response.Instance = "55555555-5555-4555-8555-555555555555"
			response.Epoch = "66666666-6666-4666-8666-666666666666"
			response.Seq = 1
		}
		if !s.accept(response, 3000200) {
			t.Fatal("controller recovery rejected")
		}
		ack := s.envelope(packet{Kind: "hello"}, 11, 3000201, false)
		if ack.Peer != response.Instance || ack.Epoch != response.Epoch {
			t.Fatal("acknowledgement must be targeted")
		}
		if restarted && s.accept(control("hello", 0, 100), 3000300) {
			t.Fatal("retired controller revived")
		}
		start := response
		start.Kind = "start"
		start.Generation = 1
		start.Seq++
		start.Window = window_uuid
		if !restarted {
			feedback := s.stopped_start(start)
			if s.accept(start, 3000350) || !feedback {
				t.Fatal("same-generation recovery requires stop feedback")
			}
			stop := s.envelope(packet{Kind: "stop", Window: s.Window}, 12, 3000351, false)
			b, _ := json.Marshal(stop)
			received, err := decode_packet(b)
			if err != nil || received.Kind != "stop" || received.Peer != response.Instance || received.Epoch != response.Epoch || received.Generation != start.Generation {
				t.Fatal("invalid recovery stop", err)
			}
			// Model the controller receiving stop and starting its next generation.
			start.Generation = received.Generation + 1
			start.Seq++
		}
		if !s.accept(start, 3000400) || !s.Active {
			t.Fatal("recovered controller cannot restart stream")
		}
	}
}
func TestPauseResumeRejectsQueuedInputAndHealth(t *testing.T) {
	s := initialized_state(t)
	var source processed_source_state
	source.consume(source_event{ID: 1, Time: 100, Mods: 1})
	s.recent = []source_event{{ID: 1, Time: 100, Window: window_uuid}}
	s.Gap = false
	s.set_paused(true, 200, &source)
	if s.Boundary != 200 || source.Ready || !s.Gap || len(s.recent) != 0 {
		t.Fatal("pause retained source continuity")
	}
	source.consume(source_event{ID: 2, Time: 250, Mods: 1})
	s.set_paused(false, 300, &source)
	if s.Boundary != 300 || source.Ready || !s.Gap || len(s.recent) != 0 {
		t.Fatal("resume retained paused samples")
	}
	for _, kind := range []string{"key", "health"} {
		if source.consume_after(source_event{ID: 3, Time: 299, Kind: kind, Mods: 1}, s.Boundary) || source.Ready {
			t.Fatal("queued pre-resume sample consumed", kind)
		}
	}
	if !source.consume_after(source_event{ID: 4, Time: 300, Kind: "health", Mods: 0}, s.Boundary) || !source.Ready || source.Time != 300 {
		t.Fatal("fresh health sample rejected")
	}
}

func TestDiagnosticExpiryUsesCapturedTime(t *testing.T) {
	for _, sample := range []struct{ captured, cutoff string }{
		{"2026-10-01T10:00:00.1Z", "2026-10-01T10:00:00.15Z"},
		{"2026-11-01T01:59:00-07:00", "2026-11-01T01:01:00-08:00"},
	} {
		captured, _ := time.Parse(time.RFC3339Nano, sample.captured)
		cutoff, _ := time.Parse(time.RFC3339Nano, sample.cutoff)
		d := diagnostics{records: []diagnostic{{Time: sample.captured, Reason: "old", captured: captured}}, bytes: 67}
		d.prune_expired(cutoff.Add(2 * time.Minute))
		if len(d.records) != 0 || d.bytes != 0 {
			t.Fatal("expired diagnostic retained by string ordering", sample)
		}
	}
}
func TestSourceBoundaryInvalidatesOldWindowSnapshot(t *testing.T) {
	s := initialized_state(t)
	source := processed_source_state{}
	source.consume(source_event{ID: 1, Time: 100, Mods: 1})
	s.source_boundary(200, &source)
	if source.Ready || !s.Gap || s.Boundary != 200 {
		t.Fatal("boundary retained source state")
	}
	if source.consume_after(source_event{ID: 2, Time: 199, Kind: "health"}, s.Boundary) || source.Ready {
		t.Fatal("old health restored invalid snapshot")
	}
}

func TestStoppedStartFeedbackRejectsOtherIdentityAndGeneration(t *testing.T) {
	s := initialized_state(t)
	s.accept(control("start", 2, 2), 100)
	s.stop()
	valid := control("start", 2, 3)
	if !s.stopped_start(valid) {
		t.Fatal("missing valid stop feedback")
	}
	for _, changed := range []string{"recipient", "instance", "epoch", "older_generation", "newer_generation", "duplicate", "kind"} {
		p := valid
		switch changed {
		case "recipient":
			p.Peer = mac_uuid
		case "instance":
			p.Instance = win_uuid
		case "epoch":
			p.Epoch = "55555555-5555-4555-8555-555555555555"
		case "older_generation":
			p.Generation = 1
		case "newer_generation":
			p.Generation = 3
		case "duplicate":
			p.Seq = 2
		case "kind":
			p.Kind = "ping"
		}
		if s.stopped_start(p) {
			t.Fatal("unrelated packet triggers stop feedback", changed)
		}
	}
	s.Stopped = false
	if s.stopped_start(valid) {
		t.Fatal("live generation triggers stop feedback")
	}
}

func TestSnapshotCyclePreservesGapUntilFreshSample(t *testing.T) {
	s := initialized_state(t)
	var source processed_source_state
	s.source_boundary(200, &source)
	source.consume_after(source_event{ID: 1, Time: 199, Kind: "health"}, s.Boundary)
	var snapshots []packet
	send := func(p packet) { snapshots = append(snapshots, p) }
	resend := func(events []source_event) {
		if !s.Gap {
			t.Fatal("resend lost boundary gap before snapshot cycle ended")
		}
	}
	s.snapshot_cycle(&source, 300, send, resend)
	if len(snapshots) != 0 || !s.Gap {
		t.Fatal("empty snapshot cycle swallowed boundary gap")
	}
	source.consume_after(source_event{ID: 2, Time: 400, Kind: "health"}, s.Boundary)
	s.snapshot_cycle(&source, 500, send, resend)
	if len(snapshots) != 1 || !snapshots[0].Gap || snapshots[0].Time != 400 || s.Gap {
		t.Fatal("fresh snapshot failed to publish boundary gap")
	}
}
