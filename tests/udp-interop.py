#!/usr/bin/env python3
"""Real Go/Swift UDP loopback; synthesized in-memory events are never posted."""
from pathlib import Path
import os
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
driver = r'''
extension RemotePeerBridge {
    func feed_fixture_events(_ seen: inout Set<UInt64>, corrections: inout Int) {
        guard matcher.healthy(Int64(peer_now_us())) else { return }
        for source in matcher.source.sorted(by: { $0.id < $1.id }) where !seen.contains(source.id) {
            seen.insert(source.id)
            guard let event = CGEvent(source: nil) else { fatalError("in-memory event creation failed") }
            let instant = min(Int64(peer_now_us()), matcher.mapped(source.time_us) + 5_000)
            event.timestamp = UInt64(max(0, instant)) * 1000
            var expected_flags: UInt64 = 0
            if source.mods & 3 != 0 { expected_flags |= CGEventFlags.maskCommand.rawValue }
            if source.mods & 1 != 0 { expected_flags |= 8 }
            if source.mods & 2 != 0 { expected_flags |= 16 }
            let type: CGEventType
            switch source.kind {
            case "modifier":
                precondition(source.key == 224 || source.key == 228, "fixture modifier must be physical Ctrl")
                type = .flagsChanged; event.type = type
                event.setIntegerValueField(.keyboardEventKeycode, value: source.key == 224 ? 55 : 54)
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
                if source.kind == "key" && source.mods & 3 != 0 && result.class_mask & 1 != 0 {
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
try bridge.configure(peer_ip: "127.0.0.1", enabled: true)
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
precondition(corrections > 0, "real cross-language packets did not repair a keyboard event")
while peer_now_us() - start < 7_500_000 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
bridge.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
print("PASS: Swift decoded real Go packets, clock calibrated, both Ctrl sides verified, keyboard flags repaired, window learned and idle stopped; no input taps or posted events")
'''
with tempfile.TemporaryDirectory(prefix="uu-udp-interop-") as folder:
    source = Path(folder) / "main.swift"
    binary = Path(folder) / "swift-peer"
    source.write_text((project / "remote-peer.swift").read_text() + "\n" + driver)
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(source), "-o", str(binary)], check=True)
    env = os.environ.copy()
    env.update(UU_BRIDGE_INTEROP_LOCAL_PORT="47732", UU_BRIDGE_INTEROP_PEER_PORT="47733")
    go_peer = subprocess.Popen(["go", "test", "-run", "^TestUDPInteropPeer$", "-v", "-count=1"],
                               cwd=project / "windows", env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    try:
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=12)
        print(result.stdout)
        if result.returncode:
            print(result.stderr)
            raise RuntimeError("Swift UDP integration driver failed")
        output, _ = go_peer.communicate(timeout=15)
        print(output)
        assert go_peer.returncode == 0
        assert "bind=true" in output
    finally:
        if go_peer.poll() is None:
            go_peer.kill()
            final_output, _ = go_peer.communicate()
            if final_output: print(final_output)
