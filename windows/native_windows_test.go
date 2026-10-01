//go:build windows

package main

import (
	"runtime"
	"sync"
	"testing"
)

func TestNativeABI(t *testing.T) {
	if e := native_offline_check(); e != nil {
		t.Fatal(e)
	}
}

func TestMouseMotionDoesNotPublish(t *testing.T) {
	previous := native
	a := &native_app{input: make(chan source_event, 512), diag: &diagnostics{}}
	a.event_id.Store(17)
	a.mods.Store(1)
	native = a
	defer func() { native = previous }()
	for i := 0; i < 1000; i++ {
		// A nil payload must be safe: motion is ignored before decoding or scope work.
		mouse_proc(0, 0x200, 0)
	}
	if a.event_id.Load() != 17 || a.mods.Load() != 1 || len(a.input) != 0 || a.overflow.Load() || a.gap_reasons.Load() != 0 {
		t.Fatal("mouse motion changed input state or published evidence")
	}
}

func TestSourceGapReasonsAccumulateAndConsume(t *testing.T) {
	a := &native_app{diag: &diagnostics{}}
	a.mark_source_gap(gap_modifier_state_mismatch)
	a.mark_source_gap(gap_input_queue_overflow)
	a.mark_source_gap(gap_input_queue_overflow)
	if !a.overflow.Swap(false) {
		t.Fatal("gap did not retain continuity invalidation")
	}
	a.record_source_gap()
	if a.gap_reasons.Load() != 0 || a.overflow.Load() {
		t.Fatal("consumed gap was not cleared")
	}
	for _, reason := range []string{"source_continuity_gap", "modifier_state_mismatch", "input_queue_overflow"} {
		if a.diag.counts[reason] != 1 {
			t.Fatal("coalesced gap reason missing or duplicated", reason, a.diag.counts)
		}
	}
	a.mark_source_gap(gap_health_queue_overflow | 1<<31)
	if !a.overflow.Swap(false) {
		t.Fatal("new gap was swallowed after consumption")
	}
	a.record_source_gap()
	if a.diag.counts["source_continuity_gap"] != 2 || a.diag.counts["health_queue_overflow"] != 1 || len(a.diag.counts) != 4 {
		t.Fatal("new gap or fixed diagnostic whitelist incorrect", a.diag.counts)
	}
}

func TestSourceGapConcurrentMarkAndConsume(t *testing.T) {
	a := &native_app{diag: &diagnostics{}}
	var producers sync.WaitGroup
	for bit := gap_modifier_state_mismatch; bit <= gap_focus_cache_overflow; bit <<= 1 {
		producers.Add(1)
		go func(reason uint32) {
			defer producers.Done()
			for i := 0; i < 100; i++ {
				a.mark_source_gap(reason)
				runtime.Gosched()
			}
		}(bit)
	}
	done := make(chan struct{})
	go func() {
		producers.Wait()
		close(done)
	}()
	for {
		if a.overflow.Swap(false) {
			a.record_source_gap()
		}
		select {
		case <-done:
			if a.overflow.Swap(false) {
				a.record_source_gap()
			}
			if a.gap_reasons.Load() != 0 {
				t.Fatal("completed producers left unconsumed reasons")
			}
			for _, reason := range []string{"modifier_state_mismatch", "input_queue_overflow", "health_queue_overflow", "foreground_changed_before_verify", "lifecycle_queue_overflow", "focused_window_lifecycle_changed", "focus_cache_overflow"} {
				if a.diag.counts[reason] == 0 {
					t.Fatal("concurrent gap reason lost", reason)
				}
			}
			return
		default:
			runtime.Gosched()
		}
	}
}
