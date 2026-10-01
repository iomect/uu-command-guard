package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

const udp_port = 47731
const max_packet = 1200

var monotonic_start = time.Now()

func now_us() int64 { return time.Since(monotonic_start).Microseconds() }
func new_id() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return hex.EncodeToString(b[:4]) + "-" + hex.EncodeToString(b[4:6]) + "-" + hex.EncodeToString(b[6:8]) + "-" + hex.EncodeToString(b[8:10]) + "-" + hex.EncodeToString(b[10:])
}

type source_event struct {
	ID     uint64 `json:"id"`
	Time   int64  `json:"time_us"`
	Window string `json:"window"`
	Kind   string `json:"kind"`
	Key    uint16 `json:"key"`
	Action string `json:"action"`
	Mods   uint16 `json:"mods"`
}
type packet struct {
	V          int            `json:"v"`
	Kind       string         `json:"kind"`
	Instance   string         `json:"instance"`
	Peer       string         `json:"peer"`
	Epoch      string         `json:"epoch"`
	Generation uint64         `json:"generation"`
	Seq        uint64         `json:"seq"`
	Time       int64          `json:"time_us"`
	Echo       *int64         `json:"echo_us,omitempty"`
	Recv       *int64         `json:"recv_us,omitempty"`
	Window     string         `json:"window,omitempty"`
	Scope      *bool          `json:"scope,omitempty"`
	Mods       *uint16        `json:"mods,omitempty"`
	EventSeq   *uint64        `json:"event_seq,omitempty"`
	Gap        bool           `json:"gap,omitempty"`
	Events     []source_event `json:"events,omitempty"`
}

func ipv4(s string) (net.IP, error) {
	s = strings.TrimSpace(s)
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() == nil || strings.Contains(s, ":") || ip.IsUnspecified() || ip.IsMulticast() || ip.Equal(net.IPv4bcast) {
		return nil, errors.New("请输入有效的对端 IPv4 地址")
	}
	return ip.To4(), nil
}
func valid_uuid(s string) bool {
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return false
	}
	_, e := hex.DecodeString(strings.ReplaceAll(s, "-", ""))
	return e == nil
}
func unique_json_keys(b []byte) error {
	d := json.NewDecoder(bytes.NewReader(b))
	var walk func() error
	walk = func() error {
		t, e := d.Token()
		if t == nil && e == nil {
			return errors.New("null")
		}
		if e != nil {
			return e
		}
		if delim, ok := t.(json.Delim); ok {
			switch delim {
			case '{':
				keys := map[string]bool{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return e
					}
					key, ok := k.(string)
					if !ok || keys[key] {
						return errors.New("duplicate field")
					}
					keys[key] = true
					if e = walk(); e != nil {
						return e
					}
				}
				_, e = d.Token()
				return e
			case '[':
				for d.More() {
					if e = walk(); e != nil {
						return e
					}
				}
				_, e = d.Token()
				return e
			default:
				return errors.New("json delimiter")
			}
		}
		return nil
	}
	if e := walk(); e != nil {
		return e
	}
	if _, e := d.Token(); e != io.EOF {
		return errors.New("trailing")
	}
	return nil
}
func decode_packet(b []byte) (packet, error) {
	var p packet
	if len(b) > max_packet || len(b) == 0 {
		return p, errors.New("size")
	}
	if e := unique_json_keys(b); e != nil {
		return p, e
	}
	var raw map[string]json.RawMessage
	if e := json.Unmarshal(b, &raw); e != nil {
		return p, e
	}
	for _, k := range []string{"v", "kind", "instance", "peer", "epoch", "generation", "seq", "time_us"} {
		r, ok := raw[k]
		if !ok || bytes.Equal(r, []byte("null")) {
			return p, fmt.Errorf("missing %s", k)
		}
	}
	for _, r := range raw {
		if bytes.Equal(r, []byte("null")) {
			return p, errors.New("null")
		}
	}
	if r, ok := raw["events"]; ok {
		var records []map[string]json.RawMessage
		if e := json.Unmarshal(r, &records); e != nil {
			return p, e
		}
		for _, record := range records {
			for _, k := range []string{"id", "time_us", "window", "kind", "key", "action", "mods"} {
				if _, ok := record[k]; !ok {
					return p, errors.New("missing event field")
				}
			}
		}
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e := d.Decode(&p); e != nil {
		return p, e
	}
	if e := d.Decode(new(any)); e != io.EOF {
		return p, errors.New("trailing")
	}
	if p.V != 1 || !valid_uuid(p.Instance) || (p.Peer != "" && !valid_uuid(p.Peer)) || (p.Epoch != "" && !valid_uuid(p.Epoch)) || (p.Window != "" && !valid_uuid(p.Window)) || (p.Peer == "" && p.Kind != "hello") || (p.Epoch == "" && p.Kind != "hello") || len(p.Instance) > 80 || len(p.Peer) > 80 || len(p.Epoch) > 80 || len(p.Window) > 80 || p.Time < 0 || p.Seq == 0 {
		return p, errors.New("header")
	}
	switch p.Kind {
	case "hello", "ping", "pong", "prepare", "start", "stop", "bind", "events", "snapshot", "heartbeat":
	default:
		return p, errors.New("kind")
	}
	if p.Mods != nil && *p.Mods > 255 {
		return p, errors.New("mods")
	}
	if len(p.Events) > 512 {
		return p, errors.New("events")
	}
	for _, e := range p.Events {
		if e.ID == 0 || e.Time < 0 || e.Time > p.Time || !valid_uuid(e.Window) || len(e.Window) > 80 || e.Mods > 255 {
			return p, errors.New("event")
		}
		switch e.Kind {
		case "key":
			if e.Key < 4 || e.Key > 231 || e.Key >= 224 || e.Action != "down" && e.Action != "up" {
				return p, errors.New("key")
			}
		case "modifier":
			if e.Key < 224 || e.Key > 231 || e.Action != "down" && e.Action != "up" {
				return p, errors.New("modifier")
			}
		case "button":
			if e.Key < 1 || e.Key > 5 || e.Action != "down" && e.Action != "up" {
				return p, errors.New("button")
			}
		case "wheel":
			if e.Key < 1 || e.Key > 4 || e.Action != "pulse" {
				return p, errors.New("wheel")
			}
		case "motion":
			if e.Key != 0 || e.Action != "move" {
				return p, errors.New("motion")
			}
		default:
			return p, errors.New("event kind")
		}
	}
	return p, nil
}

// Split by the actual encoded datagram size. Never truncate source event identity.
func event_packets(base packet, events []source_event) ([]packet, error) {
	var out []packet
	for _, e := range events {
		if len(out) == 0 {
			out = append(out, base)
		}
		i := len(out) - 1
		out[i].Events = append(out[i].Events, e)
		b, err := json.Marshal(out[i])
		if err != nil {
			return nil, err
		}
		if len(b) > max_packet {
			out[i].Events = out[i].Events[:len(out[i].Events)-1]
			if len(out[i].Events) == 0 {
				return nil, errors.New("event too large")
			}
			next := base
			next.Events = []source_event{e}
			out = append(out, next)
		}
	}
	return out, nil
}
