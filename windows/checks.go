package main

import "errors"

func offline_check() error {
	if scan_usage(0x1d, false) != 224 || scan_usage(0x1d, true) != 228 || usage_mod(227) != 4 {
		return errors.New("scan mapping")
	}
	s := stream_state{Instance: "win", Window: "window", Scope: true, retired: map[string]bool{}}
	p := packet{Kind: "hello", Instance: "mac", Peer: "win", Epoch: "epoch", Seq: 1}
	if !s.accept(p, 0) {
		return errors.New("hello")
	}
	p.Kind = "start"
	p.Window = "window"
	p.Generation = 1
	p.Seq = 2
	if !s.accept(p, 0) || !s.Active {
		return errors.New("start")
	}
	p.Kind = "stop"
	p.Seq = 3
	if !s.accept(p, 1) || s.Active {
		return errors.New("stop")
	}
	p.Kind = "start"
	p.Seq = 4
	if s.accept(p, 2) {
		return errors.New("stale generation revived")
	}
	return nil
}
