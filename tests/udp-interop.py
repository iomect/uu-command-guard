#!/usr/bin/env python3
"""Real Go/Swift UDP loopback; synthesized in-memory events are never posted."""
from pathlib import Path
import os
import subprocess
import time
import tempfile

project = Path(__file__).resolve().parents[1]
driver = r'''
let fixture_manual_mode = __MANUAL_MODE__
let fixture_target_flag = __TARGET_FLAG__
let fixture_left_side: UInt64 = __LEFT_SIDE__
let fixture_right_side: UInt64 = __RIGHT_SIDE__
let fixture_left_key: Int64 = __LEFT_KEY__
let fixture_right_key: Int64 = __RIGHT_KEY__
let fixture_target_mask: UInt8 = __TARGET_MASK__
let fixture_scope_reset_file = "__SCOPE_RESET_FILE__"
let fixture_scope_resume_file = "__SCOPE_RESUME_FILE__"
let fixture_target_name = "__TARGET_NAME__"
extension RemotePeerBridge {
    func check_manual_fixture_configuration() {
        guard fixture_manual_mode else { return }
        precondition(manual_mapping == PeerManualMapping.default_mapping,
                     "manual mapping did not survive the input boundary")
        precondition(!matcher.readiness_status_text.contains("0/3"),
                     "manual configuration returned to automatic mapping learning")
    }
    func check_manual_conflict_early_returns() {
        guard fixture_manual_mode else { return }
        let now = Int64(peer_now_us())
        let fixture_window = matcher.learned_window ?? "manual-conflict-fixture"
        matcher.stream_clear(now: now - 1)
        matcher.offset = 0; matcher.rtt = 1000; matcher.clock_at = now
        matcher.learned_window = fixture_window; matcher.delays = [0,0,0]; matcher.ordinary_pair = true
        let source_id = max(matcher.highest_id, max(matcher.last_consumed_id, matcher.mapping_source_watermark)) + 1
        matcher.ingest([PeerInput(id: source_id, time_us: UInt64(now), window: fixture_window,
                                  kind: "modifier", key: 224, action: "down", mods: 1)], gap: false, now: now)
        let conflicting_flags = CGEventFlags.maskControl.rawValue | 1
        let modifier = PeerObservation(time: now, kind: "modifier", key: 0, action: "down",
                                       flags: conflicting_flags, modifier_class: 2, side_bit: 1)
        precondition(matcher.decide(modifier, now: now, protected: 0) == nil,
                     "flagsChanged conflict evidence must stay observation only")
        precondition(matcher.manual_mapping_conflict, "reliable configured Ctrl-to-Control conflict did not latch")
        let original_flags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue | 8 | 32 | 1
        func check_preserved(_ type: CGEventType, _ label: String, prepare: (CGEvent) -> Void = { _ in }) {
            let event = CGEvent(source: nil)!
            event.type = type; event.timestamp = peer_now_us() * 1000
            event.flags = CGEventFlags(rawValue: original_flags)
            prepare(event)
            let original_time = event.timestamp
            let original_key = event.getIntegerValueField(.keyboardEventKeycode)
            let decision = observe(type: type, event: event, now_ns: peer_now_us() * 1000, protected_mask: 0)
            guard let decision = decision else { preconditionFailure("conflict protection returned nil: " + label) }
            precondition(decision.flags == original_flags && decision.class_mask == 0 && decision.preserve_mask == 7,
                         "conflict early-return protection failed: " + label)
            precondition(event.type == type && event.timestamp == original_time
                         && event.getIntegerValueField(.keyboardEventKeycode) == original_key && event.flags.rawValue == original_flags,
                         "conflict protection mutated the in-memory event: " + label)
        }
        check_preserved(.leftMouseDown, "invalid mouse timestamp") { $0.timestamp = 0 }
        check_preserved(.scrollWheel, "unsupported two-axis scroll") {
            $0.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 1)
            $0.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 1)
        }
        matcher.offset = nil
        check_preserved(.leftMouseDown, "unhealthy clock and unmatched button")
        matcher.offset = 0; matcher.clock_at = Int64(peer_now_us())
        check_preserved(.keyDown, "unsupported ordinary physical key") {
            $0.setIntegerValueField(.keyboardEventKeycode, value: 255)
        }
        var applied_publications = 0
        for _ in 0..<9 { _ = publications.append { applied_publications += 1 } }
        check_preserved(.leftMouseDown, "publication backlog")
        precondition(applied_publications == 0, "input callback partially consumed the publication backlog")
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged; event.timestamp = peer_now_us() * 1000
        event.setIntegerValueField(.keyboardEventKeycode, value: 55)
        event.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 8)
        precondition(observe(type: .flagsChanged, event: event, now_ns: peer_now_us() * 1000, protected_mask: 0) == nil,
                     "flagsChanged must remain observation only during a configured mapping conflict")
        precondition(manual_mapping == PeerManualMapping.default_mapping, "conflict altered the saved manual mapping")
        print("PASS: manual conflict preserves all three classes across invalid timestamps, two-axis scroll, unhealthy clock, unsupported keys and publication backlog; flagsChanged stays observation only")
    }
    func feed_fixture_events(_ seen: inout Set<UInt64>, corrections: inout Int) {
        guard matcher.healthy(Int64(peer_now_us())) else { return }
        for source in matcher.source.sorted(by: { $0.id < $1.id }) where !seen.contains(source.id) {
            seen.insert(source.id)
            guard let event = CGEvent(source: nil) else { fatalError("in-memory event creation failed") }
            let instant = min(Int64(peer_now_us()), matcher.mapped(source.time_us) + 5_000)
            event.timestamp = UInt64(max(0, instant)) * 1000
            var expected_flags: UInt64 = 0
            if source.mods & 3 != 0 { expected_flags |= fixture_target_flag }
            if source.mods & 1 != 0 { expected_flags |= fixture_left_side }
            if source.mods & 2 != 0 { expected_flags |= fixture_right_side }
            let type: CGEventType
            switch source.kind {
            case "modifier":
                precondition(source.key == 224 || source.key == 228, "fixture modifier must be physical Ctrl")
                type = .flagsChanged; event.type = type
                event.setIntegerValueField(.keyboardEventKeycode, value: source.key == 224 ? fixture_left_key : fixture_right_key)
                event.flags = CGEventFlags(rawValue: expected_flags)
            case "key":
                precondition(source.key == 25, "fixture ordinary key must be physical V")
                type = source.action == "down" ? .keyDown : .keyUp; event.type = type
                event.setIntegerValueField(.keyboardEventKeycode, value: 9)
                // Simulate the observed UU defect; the source packet is authoritative.
                event.flags = []
            case "button":
                type = source.action == "down" ? .leftMouseDown : .leftMouseUp; event.type = type
                event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
                event.flags = CGEventFlags(rawValue: expected_flags)
            default: continue
            }
            let original_type = event.type
            let original_time = event.timestamp
            let original_key = event.getIntegerValueField(.keyboardEventKeycode)
            let result = observe(type: type, event: event, now_ns: peer_now_us() * 1000, protected_mask: 0)
            if let result = result {
                event.flags = CGEventFlags(rawValue: result.flags)
                if source.kind == "key" && source.mods & 3 != 0 && result.class_mask & fixture_target_mask != 0 {
                    precondition(event.flags.rawValue == expected_flags, "remote source modifiers were not restored")
                    corrections += 1
                }
            }
            precondition(event.type == original_type && event.timestamp == original_time && event.getIntegerValueField(.keyboardEventKeycode) == original_key,
                         "correction changed event type, timestamp or key")
        }
    }
}
let bridge = RemotePeerBridge(status_notice: { _ in }, local_port: 47733, peer_port: 47732)
if fixture_manual_mode { bridge.configure_mapping(PeerManualMapping.default_mapping) }
try bridge.configure(peer_ip: "127.0.0.1", enabled: true)
bridge.check_manual_fixture_configuration()
var seen: Set<UInt64> = []
var corrections = 0
let start = peer_now_us()
while peer_now_us() - start < 5_000_000 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    bridge.feed_fixture_events(&seen, corrections: &corrections)
    let event = CGEvent(source: nil)!
    event.type = .mouseMoved
    event.timestamp = peer_now_us() * 1000
    _ = bridge.observe(type: .mouseMoved, event: event, now_ns: peer_now_us() * 1000, protected_mask: 0)
}
print("Swift interop diagnostics:", bridge.diagnostic_summary(), "fixture observations:", seen.count, "source flag corrections:", corrections)
fflush(stdout)
precondition(bridge.diagnostic_summary()["window_learned"] as? Bool == true, "real Go event batches did not learn window")
precondition(bridge.diagnostic_summary()["verified_modifier_sides"] as? Int == 2, "left/right Ctrl mapping was not verified")
let mapping_details = bridge.diagnostic_summary()["modifier_mapping_details"] as? [[String: Any]] ?? []
for source_name in ["左Ctrl", "右Ctrl"] {
    precondition(mapping_details.contains { $0["source_modifier"] as? String == source_name && $0["target_modifier"] as? String == fixture_target_name && $0["verified"] as? Bool == true },
                 "real source modifier did not prove its configured target class")
}
precondition(corrections > 0, "real cross-language packets did not repair a keyboard event")
bridge.check_manual_fixture_configuration()
try Data().write(to: URL(fileURLWithPath: fixture_scope_reset_file))
let scope_deadline = peer_now_us() + 2_000_000
while peer_now_us() < scope_deadline && bridge.diagnostic_summary()["window_learned"] as? Bool == true {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
precondition(bridge.diagnostic_summary()["window_learned"] as? Bool == false && bridge.diagnostic_summary()["verified_modifier_sides"] as? Int == 0,
             "leaving the same remote window scope did not revoke learned mappings")
bridge.check_manual_fixture_configuration()
try Data().write(to: URL(fileURLWithPath: fixture_scope_resume_file))
let resume_deadline = peer_now_us() + 5_000_000
let previous_corrections = corrections
while peer_now_us() < resume_deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    bridge.feed_fixture_events(&seen, corrections: &corrections)
    let activity = CGEvent(source: nil)!
    activity.type = .mouseMoved; activity.timestamp = peer_now_us() * 1000
    _ = bridge.observe(type: .mouseMoved, event: activity, now_ns: peer_now_us() * 1000, protected_mask: 0)
    if bridge.diagnostic_summary()["window_learned"] as? Bool == true && bridge.diagnostic_summary()["verified_modifier_sides"] as? Int == 2 && corrections > previous_corrections { break }
}
precondition(bridge.diagnostic_summary()["window_learned"] as? Bool == true && bridge.diagnostic_summary()["verified_modifier_sides"] as? Int == 2 && corrections > previous_corrections,
             "same-window scope return failed to prove mappings and correct new keyboard input")
bridge.check_manual_fixture_configuration()
RunLoop.main.run(until: Date().addingTimeInterval(2.5))
bridge.check_manual_conflict_early_returns()
bridge.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
print("PASS: Swift decoded real Go packets, clock calibrated, both Ctrl sides verified, keyboard flags repaired, window learned, scope exit revoked mappings, scope return relearned and idle stopped; no input taps or posted events")
'''
configurations = [
    dict(MANUAL_MODE="false", TARGET_NAME="Command", TARGET_MASK="1", TARGET_FLAG="CGEventFlags.maskCommand.rawValue",
         LEFT_SIDE="8", RIGHT_SIDE="16", LEFT_KEY="55", RIGHT_KEY="54"),
    dict(MANUAL_MODE="false", TARGET_NAME="Control", TARGET_MASK="4", TARGET_FLAG="CGEventFlags.maskControl.rawValue",
         LEFT_SIDE="1", RIGHT_SIDE="8192", LEFT_KEY="59", RIGHT_KEY="62"),
    dict(MANUAL_MODE="true", TARGET_NAME="Command", TARGET_MASK="1", TARGET_FLAG="CGEventFlags.maskCommand.rawValue",
         LEFT_SIDE="8", RIGHT_SIDE="16", LEFT_KEY="55", RIGHT_KEY="54"),
]
for configuration in configurations:
    print("Real UDP fixture target:", configuration["TARGET_NAME"], "manual:", configuration["MANUAL_MODE"], flush=True)
    with tempfile.TemporaryDirectory(prefix="uu-udp-interop-") as folder:
        source = Path(folder) / "main.swift"
        binary = Path(folder) / "swift-peer"
        configuration = dict(configuration, SCOPE_RESET_FILE=str(Path(folder) / "scope-reset"),
                             SCOPE_RESUME_FILE=str(Path(folder) / "scope-resume"))
        fixture_driver = driver
        for marker, value in configuration.items():
            fixture_driver = fixture_driver.replace("__" + marker + "__", value)
        source.write_text((project / "remote-peer.swift").read_text() + "\n" + fixture_driver)
        subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(source), "-o", str(binary)], check=True)
        go_binary = Path(folder) / "go-peer.test"
        ready_file = Path(folder) / "go-peer.ready"
        # Compile before starting the timed Swift fixture; a fresh runner may need
        # longer than its observation window to populate Go's test build cache.
        subprocess.run(["go", "test", "-c", "-o", str(go_binary)], cwd=project / "windows", check=True)
        env = os.environ.copy()
        env.update(UU_BRIDGE_INTEROP_LOCAL_PORT="47732", UU_BRIDGE_INTEROP_PEER_PORT="47733",
                   UU_BRIDGE_INTEROP_READY_FILE=str(ready_file),
                   UU_BRIDGE_INTEROP_SCOPE_RESET_FILE=configuration["SCOPE_RESET_FILE"],
                   UU_BRIDGE_INTEROP_SCOPE_RESUME_FILE=configuration["SCOPE_RESUME_FILE"])
        go_peer = subprocess.Popen([str(go_binary), "-test.run=^TestUDPInteropPeer$", "-test.v", "-test.count=1"],
                                   cwd=project / "windows", env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        try:
            ready_deadline = time.monotonic() + 10
            while not ready_file.exists():
                if go_peer.poll() is not None:
                    output, _ = go_peer.communicate()
                    print(output)
                    raise RuntimeError("Go UDP integration peer exited before binding its listener")
                if time.monotonic() >= ready_deadline:
                    raise TimeoutError("Go UDP integration peer did not bind its listener")
                time.sleep(0.01)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            print(result.stdout)
            if result.returncode:
                print(result.stderr)
                raise RuntimeError("Swift UDP integration driver failed")
            output, _ = go_peer.communicate(timeout=15)
            print(output)
            assert go_peer.returncode == 0
            assert "bind=true" in output
            assert "scope-restored=true" in output
        finally:
            if go_peer.poll() is None:
                go_peer.kill()
                final_output, _ = go_peer.communicate()
                if final_output: print(final_output)
