package main

import (
	"encoding/json"
	"net"
	"os"
	"strconv"
	"testing"
	"time"
)

// Opt-in loopback peer for a real Swift UDP integration driver. This is compiled
// only by go test; production never overrides the fixed LAN port or emits fixtures.
func TestUDPInteropPeer(t *testing.T) {
	lp := os.Getenv("UU_BRIDGE_INTEROP_LOCAL_PORT")
	pp := os.Getenv("UU_BRIDGE_INTEROP_PEER_PORT")
	if lp == "" || pp == "" {
		t.Skip("loopback driver not requested")
	}
	local, e := strconv.Atoi(lp)
	if e != nil {
		t.Fatal(e)
	}
	remote, e := strconv.Atoi(pp)
	if e != nil {
		t.Fatal(e)
	}
	conn, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: local})
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	if ready_file := os.Getenv("UU_BRIDGE_INTEROP_READY_FILE"); ready_file != "" {
		if e := os.WriteFile(ready_file, nil, 0600); e != nil {
			t.Fatal(e)
		}
	}
	peer := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: remote}
	s := stream_state{Instance: win_uuid, Window: window_uuid, Scope: true, retired: map[string]bool{}}
	var seq uint64
	var ids uint64
	scope := true
	send := func(p packet) {
		seq++
		p.V = 1
		p.Instance = s.Instance
		p.Peer = s.Peer
		p.Epoch = s.Epoch
		p.Generation = s.Generation
		p.Seq = seq
		p.Time = packet_time(p, now_us())
		b, e := json.Marshal(p)
		if e != nil || len(b) > max_packet {
			t.Fatal("fixture encoding")
		}
		if _, e = conn.WriteToUDP(b, peer); e != nil {
			t.Fatal(e)
		}
	}
	deadline := time.Now().Add(20 * time.Second)
	nextHello := time.Now()
	nextEvent := time.Now()
	var events []source_event
	var mods uint16
	hello, ping, start, stop, bound := false, false, false, false, false
	var received uint64
	for time.Now().Before(deadline) {
		if time.Now().After(nextHello) {
			kind := "heartbeat"
			if s.Peer == "" {
				kind = "hello"
			}
			send(packet{Kind: kind, Window: s.Window, Scope: &scope})
			nextHello = time.Now().Add(time.Second)
		}
		if s.Active && time.Now().After(nextEvent) {
			steps := []struct {
				kind   string
				key    uint16
				action string
				mods   uint16
			}{{"modifier", 224, "down", 1}, {"key", 25, "down", 1}, {"key", 25, "up", 1}, {"button", 1, "down", 1}, {"button", 1, "up", 1}, {"modifier", 224, "up", 0}, {"modifier", 228, "down", 2}, {"key", 25, "down", 2}, {"key", 25, "up", 2}, {"button", 1, "down", 2}, {"button", 1, "up", 2}, {"modifier", 228, "up", 0}}
			v := steps[ids%uint64(len(steps))]
			ids++
			mods = v.mods
			ev := source_event{ID: ids, Time: now_us(), Window: s.Window, Kind: v.kind, Key: v.key, Action: v.action, Mods: v.mods}
			events = append(events, ev)
			if len(events) > 6 {
				events = events[len(events)-6:]
			}
			send(packet{Kind: "events", Window: s.Window, Events: []source_event{ev}})
			send(packet{Kind: "snapshot", Time: ev.Time, Window: s.Window, Mods: &mods, EventSeq: &ids})
			nextEvent = time.Now().Add(100 * time.Millisecond)
		}
		b := make([]byte, max_packet+1)
		conn.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
		n, addr, e := conn.ReadFromUDP(b)
		if e != nil {
			continue
		}
		if !addr.IP.Equal(peer.IP) || addr.Port != peer.Port {
			continue
		}
		p, e := decode_packet(b[:n])
		if e != nil {
			t.Fatalf("Swift packet rejected: %v", e)
		}
		received++
		if !s.accept(p, now_us()) {
			continue
		}
		switch p.Kind {
		case "hello":
			hello = true
			send(packet{Kind: "hello", Window: s.Window, Scope: &scope})
			send(packet{Kind: "prepare", Window: s.Window, Scope: &scope})
		case "ping":
			ping = true
			r := now_us()
			echo := p.Time
			gen := s.Generation
			s.Generation = p.Generation
			send(packet{Kind: "pong", Echo: &echo, Recv: &r})
			s.Generation = gen
		case "start":
			start = true
		case "bind":
			bound = true
		case "stop":
			stop = true
		}
		if hello && ping && start && stop {
			t.Logf("real UDP verified: handshake, ping/pong, start, fixture events=%d, bind=%v, stop; received=%d", ids, bound, received)
			return
		}
	}
	t.Fatalf("loopback interop timed out: hello=%v ping=%v start=%v stop=%v bound=%v", hello, ping, start, stop, bound)
}
