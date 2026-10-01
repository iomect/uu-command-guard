import Foundation
import CoreGraphics
import Darwin

struct RemoteFlagDecision { let flags: UInt64; let class_mask: UInt8; var preserve_mask: UInt8 = 0; var keypad_plus_text: Bool = false }
struct PeerInput: Codable {
    let id: UInt64; let time_us: UInt64; let window: String
    let kind: String; let key: Int; let action: String; let mods: UInt16
    var valid: Bool {
        guard id > 0, time_us <= UInt64(Int64.max), !window.isEmpty, window.count <= 128, mods < 256 else { return false }
        switch kind {
        case "key": return key >= 4 && key <= 231 && (action == "down" || action == "up")
        case "modifier": return [224,228,227,231,226,230,225,229].contains(key) && (action == "down" || action == "up")
        case "button": return (1...5).contains(key) && (action == "down" || action == "up")
        case "wheel": return (1...4).contains(key) && action == "pulse"
        case "motion": return key == 0 && action == "move"
        default: return false
        }
    }
}
struct PeerPacket: Codable {
    var v = 1; var kind: String; var instance: String; var peer: String
    var epoch: String; var generation: UInt64; var seq: UInt64; var time_us: UInt64
    var echo_us: UInt64?; var recv_us: UInt64?; var window: String?
    var scope: Bool?; var mods: UInt16?; var event_seq: UInt64?; var gap: Bool?
    var events: [PeerInput]?
}
func peer_event_time_valid(_ timestamp: UInt64, now: UInt64) -> Bool {
    timestamp != 0 && timestamp <= now && now-timestamp <= 500_000
}
func peer_now_us() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
// Physical ANSI positions, expressed as USB HID usages. Unlisted layouts/keys pass through.
func peer_usb_key(_ code: Int64) -> Int? {
    let table: [Int64:Int] = [0:4,1:22,2:7,3:9,4:11,5:10,6:29,7:27,8:6,9:25,11:5,12:20,13:26,14:8,15:21,16:28,17:23,18:30,19:31,20:32,21:33,22:35,23:34,24:46,25:38,26:36,27:45,28:37,29:39,30:48,31:18,32:24,33:47,34:12,35:19,36:40,37:15,38:13,39:52,40:14,41:51,42:49,43:54,44:56,45:17,46:16,47:55,48:43,49:44,50:53,51:42,53:41,65:99,67:85,69:87,71:83,75:84,76:88,78:86,81:103,82:98,83:89,84:90,85:91,86:92,87:93,88:94,89:95,91:96,92:97,96:62,97:63,98:64,99:60,100:65,101:66,103:68,109:67,111:69,114:73,115:74,116:75,117:76,118:61,119:77,120:59,121:78,122:58,123:80,124:79,125:81,126:82]
    return table[code]
}
struct PeerObservation {
    var time: Int64; var kind: String; var key: Int; var action: String
    var flags: UInt64; var modifier_class: Int?; var side_bit: UInt64 = 0; var keypad_plus_alias: Bool = false
}
let peer_modifier_sides: [(bit: Int, name: String)] = [
    (1,"左Ctrl"),(2,"右Ctrl"),(4,"左Win"),(8,"右Win"),(16,"左Alt"),(32,"右Alt")
]
let peer_required_modifier_sides = peer_modifier_sides.filter { $0.bit & (1 | 4 | 16) != 0 }
// Explicit class and device-side choices for the three left Windows modifiers.
// Right source keys remain independently learned; configuration is never input history.
struct PeerManualMapping: Equatable {
    let targets: [Int]
    let mappings: [Int:(Int,UInt64)]
    static let target_names = ["Command（左侧）","Command（右侧）","Option（左侧）","Option（右侧）","Control（左侧）","Control（右侧）"]
    static let default_mapping = PeerManualMapping(targets:[0,4,2])!
    init?(targets: [Int]) {
        guard targets.count == 3, targets.allSatisfy({ (0..<6).contains($0) }) else { return nil }
        self.targets = targets
        let sides: [UInt64] = [8,16,32,64,1,8192]
        self.mappings = Dictionary(uniqueKeysWithValues:zip([1,4,16],targets).map { ($0.0,($0.1/2,sides[$0.1])) })
    }
    static func == (lhs: PeerManualMapping, rhs: PeerManualMapping) -> Bool { lhs.targets == rhs.targets }
}
final class PeerMatcher {
    var source: [PeerInput] = []; var observations: [PeerObservation] = []
    var consumed: [UInt64:Int64] = [:]; var last_consumed_id: UInt64 = 0; var learned_window: String?
    var offset: Double?; var rtt: Double = .infinity; var clock_at: Int64 = 0
    var delays: [Int64] = []; var ordinary_pair = false
    var mappings: [Int: (Int, UInt64)] = [:]
    private(set) var manual_mapping: PeerManualMapping?
    private(set) var manual_mapping_conflict = false
    private(set) var keypad_plus_enabled = false
    private var manual_verified: Set<Int> = []
    private var configuration_boundary: Int64 = 0
    var mapping_edges: [Int: (Int, UInt64, UInt8)] = [:]
    var mapping_evidence: [Int: (UInt64, Int64)] = [:]
    var mapping_source_watermark: UInt64 = 0
    var mapping_observation_watermark: Int64 = 0
    var transitions: [(Int64, UInt16)] = []; var continuity = false
    var tentative_window: String?
    var pending_snapshots: [(UInt64, UInt16, UInt64, Int64)] = []
    var hole_since: Int64?
    var highest_id: UInt64 = 0; var corrected: UInt64 = 0; var skipped: UInt64 = 0
    private(set) var last_pair_reason = "not_attempted"
    private(set) var last_decision_reason = "not_attempted"
    private(set) var last_decision_source_mods: UInt16?
    private(set) var late_keyboard_calibrations: UInt64 = 0
    private(set) var last_decision_future_ahead_us: Int64 = 0
    private(set) var future_tolerance_accepts: UInt64 = 0
    let aggregate: [UInt64] = [CGEventFlags.maskCommand.rawValue,CGEventFlags.maskAlternate.rawValue,CGEventFlags.maskControl.rawValue]
    let devices: [UInt64] = [0x18,0x60,0x2001]
    func valid_mapping(_ mapping: (Int, UInt64)?) -> Bool {
        guard let mapping = mapping, aggregate.indices.contains(mapping.0), mapping.1 != 0 else { return false }
        return mapping.1 & devices[mapping.0] == mapping.1 && mapping.1 & (mapping.1-1) == 0
    }
    func configure_mapping(_ configuration: PeerManualMapping?, now: Int64 = 0) {
        manual_mapping = configuration
        manual_mapping_conflict = false
        configuration_boundary = now
        last_consumed_id = max(last_consumed_id,max(highest_id,source.map(\.id).max() ?? 0))
        window_clear(now:now)
    }
    func configure_keypad_plus(enabled: Bool, now: Int64 = 0) {
        guard keypad_plus_enabled != enabled else { return }
        keypad_plus_enabled = enabled
        configuration_boundary = max(configuration_boundary,now)
        last_consumed_id = max(last_consumed_id,max(highest_id,source.map(\.id).max() ?? 0))
        window_clear(now:now)
    }
    func verified_mapping(_ bit: Int) -> Bool {
        !manual_mapping_conflict && valid_mapping(mappings[bit]) && (manual_mapping?.mappings[bit] == nil || manual_verified.contains(bit))
    }
    var unverified_modifier_names: [String] {
        peer_required_modifier_sides.filter { !valid_mapping(mappings[$0.bit]) }.map(\.name)
    }
    var mapping_status_text: String {
        if manual_mapping_conflict { return "映射配置与 UU 实际按键冲突，已暂停修正，请检查映射设置" }
        if manual_mapping != nil { return "辅助同步中，使用手动修饰键映射" }
        let pending = unverified_modifier_names
        if !pending.isEmpty { return "辅助同步中，左侧修饰键映射待验证（\(3-pending.count)/3）：\(pending.joined(separator:"、"))" }
        let names = ["Command","Option","Control"]
        let relationships = peer_required_modifier_sides.map { "\($0.name)→\(names[mappings[$0.bit]!.0])" }
        return "辅助同步中，左侧修饰键映射已验证（3/3）：\(relationships.joined(separator:"、"))"
    }
    var readiness_status_text: String {
        if manual_mapping_conflict { return mapping_status_text }
        if manual_mapping != nil { return ready ? mapping_status_text : "手动映射已保存，正在重新同步远程输入" }
        return ready ? mapping_status_text : "辅助同步中，正在重新学习远程窗口（左侧修饰键映射\(3-unverified_modifier_names.count)/3）"
    }
    func modifier_mapping_diagnostic() -> [[String:Any]] {
        peer_modifier_sides.map { side in
            let confirmed = mappings[side.bit]
            let edges = mapping_edges[side.bit]
            let target = confirmed?.0 ?? edges?.0
            let target_name = target.flatMap { aggregate.indices.contains($0) ? ["Command","Option","Control"][$0] : nil } ?? "待学习"
            let matched_edges = edges?.2 ?? 0
            return ["source_modifier":side.name,"target_modifier":target_name,
                    "required":peer_required_modifier_sides.contains { $0.bit == side.bit },
                    "configured":manual_mapping?.mappings[side.bit] != nil,
                    "verified":verified_mapping(side.bit),
                    "matched_down":matched_edges & 1 != 0,"matched_up":matched_edges & 2 != 0]
        }
    }
    func class_mapping_available(_ index: Int, state: UInt16) -> Bool {
        unverified_modifier_names.isEmpty || mappings.values.contains { valid_mapping($0) && $0.0 == index }
    }
    private func reset_mapping_evidence(now: Int64, revoke: Bool) {
        let verified = mappings.filter { verified_mapping($0.key) }
        mapping_source_watermark = max(mapping_source_watermark,max(last_consumed_id,max(highest_id,source.map(\.id).max() ?? 0)))
        mapping_observation_watermark = max(mapping_observation_watermark,max(now,observations.map(\.time).max() ?? 0))
        mapping_evidence.removeAll(); mapping_edges.removeAll()
        if revoke { mappings = manual_mapping?.mappings ?? [:]; manual_verified.removeAll() }
        else { for (bit,mapping) in verified { mapping_edges[bit] = (mapping.0,mapping.1,3) } }
    }
    func clear(keep_consumed: Bool = true, now: Int64 = 0) {
        reset_mapping_evidence(now:now,revoke:true)
        source.removeAll(); observations.removeAll(); delays.removeAll(); pending_snapshots.removeAll(); hole_since = nil
        ordinary_pair = false; learned_window = nil; transitions.removeAll()
        continuity = false; tentative_window = nil; highest_id = 0; offset = nil; rtt = .infinity; clock_at = 0
        if !keep_consumed { consumed.removeAll(); last_consumed_id = 0; mapping_source_watermark = 0 }
    }
    func window_clear(now: Int64 = 0) {
        reset_mapping_evidence(now:now,revoke:true)
        stream_clear(now:now); delays.removeAll(); ordinary_pair = false
        tentative_window = nil; learned_window = nil
    }
    func stream_clear(new_generation: Bool = false, now: Int64 = 0) {
        reset_mapping_evidence(now:now,revoke:false)
        source.removeAll(); observations.removeAll(); transitions.removeAll(); continuity = false
        pending_snapshots.removeAll(); hole_since = nil
        if new_generation { highest_id = 0 }
    }
    func prune(_ now: Int64) {
        expire_pending(now)
        source.removeAll { now - mapped($0.time_us) > 1_000_000 }
        observations.removeAll { now - $0.time > 1_000_000 }
        consumed = consumed.filter { now - $0.value <= 1_000_000 }
        transitions.removeAll { now - $0.0 > 1_000_000 }
    }
    func mapped(_ time: UInt64) -> Int64 {
        // Int64.max rounds up to 2^63 as Double; clamp to a representable value.
        Int64(max(0, min(Double(Int64.max).nextDown, Double(time) + (offset ?? 0))))
    }
    var ready: Bool { learned_window != nil && delays.count >= 3 }
    func healthy(_ now: Int64) -> Bool { offset != nil && rtt <= 40_000 && now >= clock_at && now-clock_at <= 10_000_000 }
    func delay() -> Int64 { let sorted = delays.sorted(); return sorted.isEmpty ? 0 : sorted[sorted.count/2] }
    func compatible(_ event: PeerInput, _ observation: PeerObservation) -> Bool {
        guard event.kind == observation.kind && event.action == observation.action else { return false }
        if observation.kind == "modifier" {
            return bit(event.key) != 0 && observation.modifier_class.map { aggregate.indices.contains($0) } == true
        }
        return event.key == observation.key || (keypad_plus_enabled && observation.keypad_plus_alias &&
            observation.kind == "key" && event.key == 87 && [46,103].contains(observation.key))
    }
    func candidates(_ observation: PeerObservation, now: Int64) -> [PeerInput] {
        source.filter { event in
            guard event.id > last_consumed_id, consumed[event.id] == nil, compatible(event, observation), learned_window == nil || event.window == learned_window else { return false }
            guard mapped(event.time_us) > configuration_boundary else { return false }
            if observation.kind == "modifier" && event.id <= mapping_source_watermark { return false }
            let difference = observation.time - mapped(event.time_us)
            if ready { return abs(Double(difference) - Double(delay())) <= 25_000 + rtt/2 }
            return difference >= -50_000 && difference <= 250_000
        }
    }
    func pair(_ observation: PeerObservation, now: Int64) -> PeerInput? {
        guard healthy(now) else { last_pair_reason = "clock_unhealthy"; return nil }
        guard observation.time > configuration_boundary else { last_pair_reason = "stale_configuration_observation"; return nil }
        guard hole_since == nil else { last_pair_reason = "sequence_hole"; return nil }
        guard observation.kind != "motion" else { last_pair_reason = "motion_not_paired"; return nil }
        guard observation.kind != "modifier" || observation.time > mapping_observation_watermark else { last_pair_reason = "stale_mapping_observation"; return nil }
        let matches = candidates(observation, now: now)
        guard !matches.isEmpty else { last_pair_reason = "no_candidate"; return nil }
        guard matches.count == 1, let event = matches.first else { last_pair_reason = "ambiguous_candidates"; return nil }
        let source_time = mapped(event.time_us)
        if observation.kind == "modifier" {
            // Mapping evidence must pass the same source-age and clock uncertainty
            // bounds as a correction, before it can consume or revoke any evidence.
            let observed_now = min(now,observation.time)
            guard source_time <= observed_now || source_time-observed_now <= Int64(rtt/2) else { last_pair_reason = "source_from_future"; return nil }
            guard now-source_time <= 500_000 else { last_pair_reason = "source_stale"; return nil }
        }
        let d = observation.time - source_time
        if !ready, !delays.isEmpty, abs(Double(d) - Double(delay())) > 20_000 { last_pair_reason = "inconsistent_learning_delay"; return nil }
        // Calibration cannot combine windows: restart tentative samples on candidate change.
        if learned_window == nil, let first = tentative_window, first != event.window {
            reset_mapping_evidence(now:now,revoke:true); delays.removeAll(); ordinary_pair = false
        }
        tentative_window = event.window
        consumed[event.id] = now; last_consumed_id = event.id
        if consumed.count > 512, let oldest = consumed.min(by: { $0.value < $1.value })?.key { consumed.removeValue(forKey: oldest) }
        delays.append(d)
        if delays.count > 8 { delays.removeFirst() }
        ordinary_pair = ordinary_pair || observation.kind == "key" || observation.kind == "button"
        if learned_window == nil && delays.count >= 3 && ordinary_pair { learned_window = event.window }
        learn_mapping(event,observation:observation)
        last_pair_reason = "matched"
        return event
    }
    private func learn_mapping(_ event: PeerInput, observation: PeerObservation) {
        guard event.kind == "modifier", let index = observation.modifier_class, aggregate.indices.contains(index),
              event.id > mapping_source_watermark, observation.time > mapping_observation_watermark else { return }
        let source_bit = bit(event.key)
        let side = observation.side_bit
        let down = event.action == "down"
        guard source_bit != 0, (event.mods & source_bit != 0) == down,
              valid_mapping((index,side)), (observation.flags & side != 0) == down,
              observation.flags & devices[index] == (down ? side : 0),
              (observation.flags & aggregate[index] != 0) == down else { return }
        let key = Int(source_bit)
        if let evidence = mapping_evidence[key], event.id <= evidence.0 || observation.time <= evidence.1 { return }
        let prior = mapping_edges[key]
        let known = mappings[key].map { ($0.0,$0.1) } ?? prior.map { ($0.0,$0.1) }
        if let configured = manual_mapping?.mappings[key], configured.0 != index || configured.1 != side {
            // Never reinterpret a user setting from one observed edge. Stop repairs
            // until the user explicitly saves a corrected configuration.
            manual_mapping_conflict = true
            return
        }
        if let known = known, known.0 != index || known.1 != side {
            // A reliable conflicting edge changes the whole configuration. Its opposite
            // edge must come from newer source and Mac observations, never old history.
            mappings = manual_mapping?.mappings ?? [:]; mapping_edges.removeAll(); mapping_evidence.removeAll(); manual_verified.removeAll()
            mapping_source_watermark = max(mapping_source_watermark,event.id)
            mapping_observation_watermark = max(mapping_observation_watermark,observation.time)
        }
        let edge: UInt8 = down ? 1 : 2
        let current = mapping_edges[key]
        let combined: UInt8
        if down { combined = 1 }
        else if current?.0 == index && current?.1 == side && current?.2 == 1 { combined = 3 }
        else if verified_mapping(key) { combined = 3 }
        else { combined = edge }
        mapping_edges[key] = (index,side,combined)
        mapping_evidence[key] = (event.id,observation.time)
        if combined == 3 {
            mappings[key] = (index,side)
            if manual_mapping?.mappings[key] != nil { manual_verified.insert(key) }
        }
    }
    func bit(_ key: Int) -> UInt16 {
        switch key { case 224:return 1;case 228:return 2;case 227:return 4;case 231:return 8;case 226:return 16;case 230:return 32;default:return 0 }
    }
    private func expire_pending(_ now: Int64) {
        let timed = pending_snapshots.filter { now >= $0.3 && now-$0.3 >= 100_000 }
        guard (hole_since.map { now >= $0 && now-$0 >= 100_000 } ?? false) || !timed.isEmpty else { return }
        let watermark = max(highest_id, max(source.map(\.id).max() ?? 0, timed.map { $0.2 }.max() ?? 0))
        let last = timed.last
        window_clear(now:now); highest_id = watermark; last_consumed_id = max(last_consumed_id,watermark)
        if let state = last { apply_snapshot(time:state.0,mods:state.1) }
    }
    private func apply_snapshot(time: UInt64, mods: UInt16) {
        let instant = mapped(time)
        guard transitions.last.map({ instant >= $0.0 }) ?? true else { return }
        if !continuity { transitions.removeAll(); continuity = true }
        transitions.append((instant,mods))
        if transitions.count > 512 { transitions.removeFirst(transitions.count-512) }
    }
    func ingest(_ events: [PeerInput], gap: Bool, now: Int64) {
        prune(now)
        if gap { window_clear(now:now) }
        let ordered = events.filter(\.valid).sorted { $0.id < $1.id }
        if highest_id == 0, let first = ordered.first { highest_id = max(last_consumed_id, first.id-1) }
        for event in ordered where consumed[event.id] == nil && !source.contains(where: { $0.id == event.id }) {
            source.append(event)
        }
        // Preserve a contiguous watermark. A later UDP batch can arrive before its predecessor.
        while highest_id < UInt64.max, let next = source.first(where: { $0.id == highest_id+1 }) {
            if continuity {
                let instant = mapped(next.time_us)
                if transitions.last.map({ instant >= $0.0 }) ?? true { transitions.append((instant,next.mods)) }
                else { continuity = false; transitions.removeAll() }
            }
            highest_id = next.id
        }
        if transitions.count > 512 { transitions.removeFirst(transitions.count-512) }
        let has_hole = source.contains { $0.id > highest_id }
        if has_hole { if hole_since == nil { hole_since = now } }
        else { hole_since = nil }
        if source.count > 512 {
            let watermark = source.map(\.id).max() ?? highest_id
            window_clear(now:now); highest_id = watermark; last_consumed_id = max(last_consumed_id,watermark)
        }
        let available = pending_snapshots.filter { $0.2 <= highest_id }
        pending_snapshots.removeAll { $0.2 <= highest_id }
        if hole_since == nil { for state in available { apply_snapshot(time:state.0,mods:state.1) } }
        var remaining: [PeerObservation] = []
        for observation in observations {
            if pair(observation, now: now) == nil { remaining.append(observation) }
            else if observation.kind == "key" { late_keyboard_calibrations &+= 1 }
        }
        observations = remaining
    }
    func snapshot(time: UInt64, mods: UInt16, event_seq: UInt64, now: Int64) {
        prune(now)
        guard healthy(now), mods < 256, time <= UInt64(Int64.max) else { return }
        if event_seq > highest_id {
            pending_snapshots.append((time,mods,event_seq,now))
            if pending_snapshots.count > 16 { window_clear(now:now) }
            return
        }
        if hole_since == nil { apply_snapshot(time:time,mods:mods) }
    }
    func decide(_ observation: PeerObservation, now: Int64, protected: UInt8) -> RemoteFlagDecision? {
        prune(now)
        last_decision_source_mods = nil
        last_decision_future_ahead_us = 0
        last_decision_reason = "motion_history_unavailable"
        let was_ready = ready
        var mods: UInt16?
        var matched_keypad_plus = false
        if observation.kind == "motion" {
            if healthy(now), ready, continuity, hole_since == nil {
                let center = observation.time - delay(); let radius = Int64(25_000+rtt/2)
                let lo = center-radius, hi = center+radius
                if let before = transitions.last(where: { $0.0 <= lo }), let after = transitions.first(where: { $0.0 >= hi }), before.1 == after.1,
                   !transitions.contains(where: { $0.0 > lo && $0.0 < hi && $0.1 != before.1 }) { mods = before.1 }
            }
        } else if let matched = pair(observation, now: now) {
            last_decision_source_mods = matched.mods
            let source_time = mapped(matched.time_us)
            last_decision_future_ahead_us = max(0,source_time-now)
            if !was_ready { last_decision_reason = "window_learning" }
            // Offset is the midpoint of the ping interval, not an exact clock reading.
            else if last_decision_future_ahead_us > Int64(rtt/2) { last_decision_reason = "source_from_future" }
            else if now-source_time > 500_000 { last_decision_reason = "source_stale" }
            else {
                mods = matched.mods
                matched_keypad_plus = keypad_plus_enabled && observation.kind == "key" &&
                    observation.action == "down" && matched.key == 87 &&
                    matched.mods & 63 == 0 && protected == 0 &&
                    observation.flags & aggregate.reduce(0, |) == 0
                if last_decision_future_ahead_us > 0 { future_tolerance_accepts &+= 1 }
            }
        } else {
            last_decision_reason = last_pair_reason
            observations.append(observation)
            if observations.count > 512 { observations.removeFirst(); continuity = false; transitions.removeAll() }
        }
        if observation.kind == "modifier" { last_decision_reason = "modifier_observation"; skipped &+= 1; return nil }
        if manual_mapping_conflict {
            last_decision_reason = "manual_mapping_conflict"
            skipped &+= 1
            return RemoteFlagDecision(flags:observation.flags,class_mask:0,preserve_mask:7)
        }
        guard let state = mods else { skipped &+= 1; return nil }
        let active_unknown = peer_modifier_sides.filter { state & UInt16($0.bit) != 0 && !valid_mapping(mappings[$0.bit]) }
        if !active_unknown.isEmpty {
            last_decision_reason = active_unknown.contains { $0.bit & (2|8|32) != 0 } ? "unverified_active_right_modifier" : "unverified_active_modifier"
            skipped &+= 1
            return RemoteFlagDecision(flags:observation.flags,class_mask:0,preserve_mask:7)
        }
        var flags = observation.flags; var mask: UInt8 = 0; var preserve_mask: UInt8 = protected & 7
        for index in 0..<3 {
            let class_bit = UInt8(1 << index)
            guard protected & class_bit == 0, class_mapping_available(index,state:state) else {
                preserve_mask |= class_bit
                continue
            }
            mask |= class_bit; flags &= ~(aggregate[index] | devices[index])
            let active = peer_modifier_sides.compactMap { side -> (Int, UInt64)? in
                guard state & UInt16(side.bit) != 0, let mapping = mappings[side.bit], mapping.0 == index else { return nil }
                return mapping
            }
            if !active.isEmpty { flags |= aggregate[index] }
            for mapping in active { flags |= mapping.1 }
        }
        guard mask != 0 else {
            last_decision_reason = matched_keypad_plus ? "keypad_plus_text_corrected" :
                (mappings.values.contains { valid_mapping($0) } ? "local_modifier_protected" : "mapping_unverified")
            if matched_keypad_plus { corrected &+= 1 } else { skipped &+= 1 }
            return RemoteFlagDecision(flags:observation.flags,class_mask:0,preserve_mask:preserve_mask,keypad_plus_text:matched_keypad_plus)
        }
        last_decision_reason = matched_keypad_plus ? "keypad_plus_text_corrected" :
            (flags == observation.flags ? "matched_flags_unchanged" : "flags_corrected")
        if flags != observation.flags || matched_keypad_plus { corrected &+= 1 }
        return RemoteFlagDecision(flags: flags, class_mask: mask, preserve_mask: preserve_mask, keypad_plus_text:matched_keypad_plus)
    }
}
struct PeerPublication {
    let body: ()->Void
    let time_us: UInt64
    let work: Int
}
enum PeerPublicationBatch {
    case ready([PeerPublication], overflow: Bool)
    case busy
    case backlog
}
// Input callbacks take only already decoded memory, with no lock wait or partial batch.
// A partial batch could hide a queued gap/revocation behind an apparently usable event.
final class PeerPublicationQueue {
    private let lock: NSLock
    private var pending: [PeerPublication] = []
    private var scheduled = false
    private var overflow = false
    init(lock: NSLock = NSLock()) { self.lock = lock }
    func append(_ body: @escaping ()->Void, work: Int = 1, now: UInt64 = peer_now_us()) -> Bool {
        lock.lock()
        if pending.count >= 512 { pending.removeAll(); overflow = true }
        pending.append(PeerPublication(body:body,time_us:now,work:max(1,work)))
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        return schedule
    }
    func take(input_callback: Bool, can_apply: Bool = true) -> PeerPublicationBatch {
        if input_callback {
            guard lock.try() else { return .busy }
        } else { lock.lock() }
        defer { lock.unlock() }
        if !overflow && input_callback && ((!pending.isEmpty && !can_apply) || pending.count > 8 || pending.reduce(0,{ $0+$1.work }) > 32) { return .backlog }
        let batch = overflow ? [] : pending
        let lost = overflow
        pending.removeAll(keepingCapacity:true); overflow = false; scheduled = false
        return .ready(batch,overflow:lost)
    }
}
enum PeerTransportReason: String, CaseIterable {
    case send_error, receive_error, rejected_address, rejected_port, rejected_header
    case rejected_session, rejected_acknowledgement, rejected_duplicate
}
struct PeerTransportDiagnostics {
    private(set) var counters: [String:UInt64] = [:]
    private(set) var last_send_errno: Int32 = 0
    private(set) var last_receive_errno: Int32 = 0
    private(set) var send_error_active = false
    private(set) var receive_error_active = false
    private(set) var send_successes: UInt64 = 0
    private(set) var received_datagrams: UInt64 = 0
    var error_active: Bool { send_error_active || receive_error_active }
    mutating func reject(_ reason: PeerTransportReason) { counters[reason.rawValue,default:0] &+= 1 }
    mutating func sent(result: Int, error: Int32) {
        if result < 0 { last_send_errno = error; send_error_active = true; reject(.send_error) }
        else { send_successes &+= 1; send_error_active = false }
    }
    // A drained nonblocking socket is healthy; an interrupted call consumes only
    // its current receive budget and must not invent a transport failure.
    mutating func received(result: Int, error: Int32) {
        if result >= 0 { received_datagrams &+= 1; receive_error_active = false }
        else if error != EAGAIN && error != EWOULDBLOCK && error != EINTR {
            last_receive_errno = error; receive_error_active = true; reject(.receive_error)
        }
    }
    var status_text: String? {
        guard error_active else { return nil }
        let code = send_error_active ? last_send_errno : last_receive_errno
        let operation = send_error_active ? "发送" : "接收"
        if code == EACCES || code == EPERM { return "UDP\(operation)被系统拒绝（errno \(code)），检查本地网络权限/防火墙" }
        if code == EHOSTUNREACH || code == ENETUNREACH { return "UDP\(operation)失败：网络不可达（errno \(code)）" }
        return "UDP\(operation)失败（errno \(code)），等待重试"
    }
    var summary: [String:Any] {
        ["counters":counters,"last_send_errno":last_send_errno,"last_receive_errno":last_receive_errno,
         "send_error_active":send_error_active,"receive_error_active":receive_error_active,
         "send_successes":send_successes,"received_datagrams":received_datagrams]
    }
}
typealias PeerDatagramSender = (Int32, Data, sockaddr_in) -> (result: Int, error: Int32)
func peer_send_datagram(_ fd: Int32, _ bytes: Data, _ destination: sockaddr_in) -> (result: Int, error: Int32) {
    var address = destination
    return bytes.withUnsafeBytes { buffer in
        withUnsafePointer(to:&address) { pointer in
            let result = pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.sendto(fd,buffer.baseAddress,bytes.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
            let saved_errno = result < 0 ? errno : 0
            return (result,saved_errno)
        }
    }
}
final class RemotePeerBridge {
    private let queue = DispatchQueue(label: "uu.peer.network")
    private let datagram_sender: PeerDatagramSender
    private var transport = PeerTransportDiagnostics()
    private var cached_transport = PeerTransportDiagnostics()
    private var last_transport_publication: UInt64 = 0
    private var cache_connected = false
    private let notice: (String)->Void
    private let local_port: UInt16
    private let peer_port: UInt16
    private let matcher = PeerMatcher()
    private var timer: DispatchSourceTimer?
    private var read_source: DispatchSourceRead?
    private var socket_closing = false
    private var shutdown_callbacks: [()->Void] = []
    private var configuration_revision: UInt64 = 0
    private var main_configuration_token = ""
    private var network_configuration_token = ""
    private var activity_source: DispatchSourceUserDataOr?
    private let publications = PeerPublicationQueue()
    private var callback_publications: UInt64 = 0
    private var max_publication_wait_us: UInt64 = 0
    private var binding_requested = ""
    private var socket_fd: Int32 = -1
    private var address = sockaddr_in()
    private var peer_ip = ""; private var enabled = false
    private var instance = UUID().uuidString; private var win_instance = ""
    private var epoch = UUID().uuidString; private var retired: Set<String> = []
    private var generation: UInt64 = 0; private var seq: UInt64 = 0
    private var received_data: Set<UInt64> = []
    private var received_seq: UInt64 = 0; private var active = false; private var acknowledged = false
    private var scope = false; private var window = ""; private var bound_window = ""
    private var last_activity: UInt64 = 0; private var last_peer: UInt64 = 0
    private var last_hello: UInt64 = 0; private var last_start: UInt64 = 0
    private var pending_pings: Set<UInt64> = []
    private var main_enabled = false
    private var clock_samples: [(UInt64, Double, Double)] = []
    private var cache_generation: UInt64 = 0
    private var cache_epoch = ""
    private var status_value = "辅助同步未配置"
    private var keyboard_decisions: [String:UInt64] = [:]
    private var last_keyboard_decision: [String:Any] = [:]
    var status_text: String { status_value }
    var corrected_count: UInt64 { matcher.corrected }
    var skipped_count: UInt64 { matcher.skipped }
    var manual_mapping: PeerManualMapping? { matcher.manual_mapping }
    var keypad_plus_enabled: Bool { matcher.keypad_plus_enabled }
    func configure_keypad_plus(enabled: Bool) {
        _ = drain_publications()
        guard matcher.keypad_plus_enabled != enabled else { return }
        matcher.configure_keypad_plus(enabled:enabled,now:Int64(peer_now_us()))
        binding_requested = ""
        if main_enabled && cache_connected && !cached_transport.error_active {
            status_value = matcher.readiness_status_text
            notice(status_value)
        }
    }
    var keyboard_decision_reason: String { last_keyboard_decision["reason"] as? String ?? "not_attempted" }
    func configure_mapping(_ configuration: PeerManualMapping?) {
        _ = drain_publications()
        matcher.configure_mapping(configuration,now:Int64(peer_now_us()))
        binding_requested = ""
        if main_enabled && cache_connected && !cached_transport.error_active {
            status_value = matcher.readiness_status_text
            notice(status_value)
        }
    }
    init(status_notice: @escaping (String)->Void, local_port: UInt16 = 47731, peer_port: UInt16 = 47731, datagram_sender: @escaping PeerDatagramSender = peer_send_datagram) {
        self.datagram_sender = datagram_sender
        notice = status_notice; self.local_port = local_port; self.peer_port = peer_port
        let source = DispatchSource.makeUserDataOrSource(queue: queue)
        source.setEventHandler { [weak self] in self?.activity() }
        activity_source = source; source.activate()
    }
    private func publish(work: Int = 1, _ body: @escaping ()->Void) {
        let token = network_configuration_token
        if publications.append({ [weak self] in
            guard let self = self, self.main_configuration_token == token else { return }
            body()
        },work:work) {
            RunLoop.main.perform(inModes: [.common]) { [weak self] in _ = self?.drain_publications() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
    private func drain_publications(input_callback: Bool = false) -> String? {
        // ingest also matches cached observations; bound that cross-product in the tap.
        let can_apply = matcher.source.count <= 128 && matcher.observations.count <= 8
        switch publications.take(input_callback:input_callback,can_apply:can_apply) {
        case .busy: return "publication_busy"
        case .backlog: return "publication_backlog"
        case let .ready(pending,overflow):
            if overflow { reset(reason:"publication_overflow"); return "publication_overflow" }
            let now = peer_now_us()
            for entry in pending {
                max_publication_wait_us = max(max_publication_wait_us,now >= entry.time_us ? now-entry.time_us : 0)
                entry.body()
            }
            if input_callback { callback_publications &+= UInt64(pending.count) }
            return nil
        }
    }
    private func status(_ text: String) { publish { [weak self] in
        guard let self = self else { return }
        let shown = self.cached_transport.status_text ?? text
        guard self.status_value != shown else { return }
        self.status_value = shown; self.notice(shown)
    } }
    private func publish_transport(force: Bool = false) {
        let now = peer_now_us()
        guard force || now-last_transport_publication >= 1_000_000 else { return }
        last_transport_publication = now
        let snapshot = transport
        let connected = acknowledged
        publish { [weak self] in
            guard let self = self else { return }
            let prior_error = self.cached_transport.error_active
            self.cached_transport = snapshot
            if let text = snapshot.status_text {
                if self.status_value != text { self.status_value = text; self.notice(text) }
            } else if prior_error {
                self.status_value = connected && self.cache_connected ? "已连接，等待 UU 输入" : "等待 Windows 连接"
                self.notice(self.status_value)
            }
        }
    }
    func configure(peer_ip: String, enabled: Bool) throws {
        var parsed = in_addr()
        guard peer_ip.isEmpty || (peer_ip.split(separator: ".").count == 4 && inet_pton(AF_INET, peer_ip, &parsed) == 1) else {
            throw NSError(domain: "UUBridge", code: 1, userInfo: [NSLocalizedDescriptionKey:"请输入有效 IPv4 地址"])
        }
        main_enabled = enabled && !peer_ip.isEmpty
        let token = UUID().uuidString
        main_configuration_token = token
        cache_connected = false; cached_transport = PeerTransportDiagnostics()
        matcher.clear(now:Int64(peer_now_us())); cache_epoch = ""; binding_requested = ""
        queue.async { [weak self] in
            guard let self = self else { return }
            self.network_configuration_token = token
            self.configuration_revision &+= 1
            let revision = self.configuration_revision
            self.shutdown {
                guard revision == self.configuration_revision else { return }
                self.open_socket(peer_ip:peer_ip,enabled:enabled,parsed:parsed)
            }
        }
    }
    private func open_socket(peer_ip: String, enabled: Bool, parsed: in_addr) {
        transport = PeerTransportDiagnostics(); last_transport_publication = 0
        publish_transport(force:true)
        self.peer_ip = peer_ip; self.enabled = enabled
        self.new_epoch(); self.address = sockaddr_in()
        self.address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        self.address.sin_family = sa_family_t(AF_INET); self.address.sin_port = self.peer_port.bigEndian
        self.address.sin_addr = parsed
        guard enabled && !peer_ip.isEmpty else { self.status(enabled ? "辅助同步未配置" : "辅助同步已暂停"); return }
        self.socket_fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard self.socket_fd >= 0 else { self.status("UDP 创建失败"); return }
        var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET); local.sin_port = self.local_port.bigEndian
        let result = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(self.socket_fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(self.socket_fd); self.socket_fd = -1; self.status("UDP 47731 端口不可用"); return }
        _ = fcntl(self.socket_fd,F_SETFL,O_NONBLOCK)
        let fd = self.socket_fd
        let source = DispatchSource.makeReadSource(fileDescriptor:fd,queue:self.queue)
        source.setEventHandler { [weak self] in
            guard let self = self, self.socket_fd == fd else { return }
            self.receive_pending(fd:fd)
        }
        self.read_source = source; source.activate()
        let timer = DispatchSource.makeTimerSource(queue:self.queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        self.status("等待 Windows 连接")
    }
    private func new_epoch() {
        if !epoch.isEmpty { retired.insert(epoch) }
        if retired.count > 32 { retired.removeAll(); retired.insert(epoch) }
        epoch = UUID().uuidString; generation = 0; received_seq = 0; received_data.removeAll()
        active = false; acknowledged = false; scope = false; window = ""; bound_window = ""
        clock_samples.removeAll(); pending_pings.removeAll(); last_activity = 0; last_peer = 0
        let fresh = epoch
        let boundary_now = Int64(peer_now_us())
        publish { [weak self] in self?.cache_connected = false; self?.cache_epoch = fresh; self?.cache_generation = 0; self?.binding_requested = ""; self?.matcher.clear(now:boundary_now) }
    }
    private func packet(_ kind: String) -> PeerPacket {
        seq &+= 1
        return PeerPacket(kind:kind,instance:instance,peer:win_instance,epoch:epoch,generation:generation,seq:seq,time_us:peer_now_us())
    }
    private func send(_ packet: PeerPacket) {
        guard socket_fd >= 0, let bytes = try? JSONEncoder().encode(packet), bytes.count <= 1200 else { return }
        let previous_error = transport.status_text
        let outcome = datagram_sender(socket_fd,bytes,address)
        transport.sent(result:outcome.result,error:outcome.error)
        publish_transport(force:previous_error != transport.status_text)
    }

    private func invalidate_main() {
        let boundary_now = Int64(peer_now_us())
        publish { [weak self] in self?.matcher.window_clear(now:boundary_now) }
    }
    private func cease(boundary: Bool = false, now: Int64 = 0) {
        active = false; generation &+= 1; send(packet("stop"))
        let revoked = generation
        let boundary_now = now == 0 ? Int64(peer_now_us()) : now
        if boundary { bound_window = "" }
        publish { [weak self] in
            guard let self = self else { return }
            self.cache_generation = revoked
            if boundary { self.matcher.window_clear(now:boundary_now); self.binding_requested = "" }
            else { self.matcher.stream_clear(now:boundary_now) }
        }
        status("已连接，等待 UU 输入")
    }
    private func receive_pending(fd: Int32) {
        // Socket readiness wakes the network queue; input callbacks never read it.
        for _ in 0..<32 {
            var bytes = [UInt8](repeating:0,count:1201); var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to:&sender) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.recvfrom(fd,&bytes,bytes.count,0,$0,&length) } }
            let saved_errno = count < 0 ? errno : 0
            let previous_error = transport.status_text
            transport.received(result:count,error:saved_errno)
            publish_transport(force:previous_error != transport.status_text)
            if count < 0 { if saved_errno == EINTR { continue }; break }
            let receipt_now = peer_now_us()
            guard sender.sin_addr.s_addr == address.sin_addr.s_addr else { transport.reject(.rejected_address); continue }
            guard sender.sin_port == address.sin_port else { transport.reject(.rejected_port); continue }
            guard count <= 1200,
                  let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(bytes.prefix(count))), p.v == 1,
                  p.time_us <= UInt64(Int64.max), !p.instance.isEmpty, p.instance.count <= 128,
                  UUID(uuidString:p.instance) != nil,
                  (UUID(uuidString:p.epoch) != nil || (p.kind == "hello" && p.peer.isEmpty && p.epoch.isEmpty)), (p.window?.count ?? 0) <= 128 else { transport.reject(.rejected_header); continue }
            receive(p,now:receipt_now)
        }
    }
    private func tick() {
        let now = peer_now_us()
        publish_transport()
        if now-last_hello >= 1_000_000 {
            last_hello = now; send(packet("hello"))
            if acknowledged {
                let p = packet("ping"); pending_pings.insert(p.time_us)
                let ping_now = peer_now_us()
                pending_pings = pending_pings.filter { ping_now >= $0 && ping_now-$0 <= 2_000_000 }; send(p)
            }
        }
        if last_peer != 0 && now-last_peer > 3_000_000 {
            new_epoch(); invalidate_main(); status("Windows 连接已失效")
        }
        if active && now-last_activity >= 2_000_000 { cease(now:Int64(now)) }
        if active && now-last_start >= 100_000 {
            last_start = now; var p = packet("start"); p.window = window; send(p)
        }
    }
    private func update_scope(_ p: PeerPacket, now: Int64) {
        let next_scope = p.scope ?? scope
        let next_window = p.window ?? window
        let known_boundary = (!window.isEmpty || scope) && (next_scope != scope || next_window != window)
        scope = next_scope; window = next_window
        if known_boundary || (active && (!scope || (!bound_window.isEmpty && window != bound_window))) {
            bound_window = ""
            if active { cease(boundary:true,now:now) }
            else {
                publish { [weak self] in
                    guard let self = self else { return }
                    self.matcher.window_clear(now:now); self.binding_requested = ""
                    self.update_mapping_status()
                }
            }
        }
    }
    private func receive(_ p: PeerPacket, now: UInt64) {
        guard p.peer == instance || (p.kind == "hello" && p.peer.isEmpty) else { transport.reject(.rejected_session); return }
        if p.kind == "hello" && p.peer.isEmpty {
            guard !retired.contains(p.instance) else { transport.reject(.rejected_session); return }
            if !win_instance.isEmpty && win_instance != p.instance {
                retired.insert(win_instance); new_epoch(); publish { [weak self] in self?.matcher.clear(keep_consumed:false,now:Int64(now)) }
            }
            win_instance = p.instance
            if acknowledged { last_peer = now; return }
            if let w = p.window { window = w }; scope = p.scope ?? false
            send(packet("hello")); last_peer = now; return
        }
        guard p.instance == win_instance, p.epoch == epoch else { transport.reject(.rejected_session); return }
        if p.kind == "hello" {
            let first_ack = !acknowledged
            guard first_ack || p.seq > received_seq else { transport.reject(.rejected_duplicate); return }
            acknowledged = true; last_peer = now; received_seq = max(received_seq,p.seq)
            update_scope(p,now:Int64(now))
            if first_ack { publish { [weak self] in self?.cache_connected = true }; status("已连接，等待 UU 输入") }; return
        }
        guard acknowledged else { transport.reject(.rejected_acknowledgement); return }
        if p.kind == "events" || p.kind == "snapshot" {
            guard !received_data.contains(p.seq), p.seq > (received_seq > 512 ? received_seq-512 : 0) else { transport.reject(.rejected_duplicate); return }
            received_data.insert(p.seq)
            received_data = received_data.filter { $0 > (max(received_seq,p.seq) > 512 ? max(received_seq,p.seq)-512 : 0) }
        } else { guard p.seq > received_seq else { transport.reject(.rejected_duplicate); return } }
        received_seq = max(received_seq,p.seq); last_peer = now
        if p.kind == "pong", let echo = p.echo_us, let receipt = p.recv_us, pending_pings.remove(echo) != nil,
           now >= echo, p.time_us >= receipt, now-echo >= p.time_us-receipt {
            let rtt = Double((now-echo)-(p.time_us-receipt))
            let packet_epoch = epoch
            let offset = (Double(echo)-Double(receipt)+Double(now)-Double(p.time_us))/2
            clock_samples.append((now,rtt,offset))
            clock_samples.removeAll { now-$0.0 > 10_000_000 }
            if clock_samples.count > 16 { clock_samples.removeFirst(clock_samples.count-16) }
            guard let best = clock_samples.min(by: { $0.1 < $1.1 }) else { return }
            let best_rtt = best.1; let best_offset = best.2
            publish { [weak self] in
                guard let self = self, self.cache_epoch == packet_epoch else { return }
                if let prior = self.matcher.offset, abs(prior-best_offset) > 50_000 { self.matcher.clear(now:Int64(now)) }
                self.matcher.rtt = best_rtt; self.matcher.offset = best_offset
                self.matcher.clock_at = Int64(now)
            }; return
        }
        if p.kind == "prepare" || p.kind == "heartbeat" {
            update_scope(p,now:Int64(now))
            return
        }
        if p.kind == "stop", p.generation == generation { cease(boundary:true,now:Int64(now)); return }
        guard active, p.generation == generation else { return }
        if p.kind == "events" {
            guard let events = p.events, events.count <= 512,
                  events.allSatisfy({ $0.valid && $0.window == window && $0.time_us <= p.time_us }) else { return }
            publish(work:events.count) { [weak self] in
                guard let self = self, self.cache_epoch == p.epoch, self.cache_generation == p.generation else { return }
                self.matcher.ingest(events,gap:p.gap ?? false,now:Int64(now)); self.bind_if_ready(); self.update_mapping_status()
            }
        } else if p.kind == "snapshot", p.window == window, let mods = p.mods, let id = p.event_seq {
            publish { [weak self] in
                guard let self = self, self.cache_epoch == p.epoch, self.cache_generation == p.generation else { return }
                if p.gap == true { self.matcher.ingest([], gap: true, now: Int64(now)) }
                self.matcher.snapshot(time:p.time_us,mods:mods,event_seq:id,now:Int64(now))
            }
        }
    }
    private func bind_if_ready() {
        guard let learned = matcher.learned_window, binding_requested != learned else { return }
        binding_requested = learned
        let requested_epoch = cache_epoch
        let manual = matcher.manual_mapping != nil
        queue.async { [weak self] in
            guard let self = self, self.active, self.epoch == requested_epoch, self.bound_window != learned else { return }
            self.bound_window = learned; var p = self.packet("bind"); p.window = learned; self.send(p)
            self.status(manual ? "远程输入已同步，使用手动修饰键映射" : "远程窗口已学习，等待修饰键映射验证")
        }
    }
    private func activity() {
        guard enabled, acknowledged else { return }
        last_activity = peer_now_us()
        if !active && scope && !window.isEmpty {
            active = true; generation &+= 1; last_start = 0
            let fresh_generation = generation
            let boundary_now = Int64(peer_now_us())
            let changing_window = !bound_window.isEmpty && bound_window != window
            if changing_window { bound_window = "" }
            publish { [weak self] in
                self?.cache_generation = fresh_generation
                self?.matcher.stream_clear(new_generation:true,now:boundary_now)
                if changing_window { self?.matcher.window_clear(now:boundary_now); self?.binding_requested = "" }
            }
            status("正在学习远程窗口")
        }
    }
    func observe(type:CGEventType,event:CGEvent,now_ns:UInt64,protected_mask:UInt8) -> RemoteFlagDecision? {
        let decision = observe_input(type:type,event:event,now_ns:now_ns,protected_mask:protected_mask)
        // Even a rejected/unmatched event must preserve flags across the offline
        // mouse path while an explicit configuration conflict is latched.
        if main_enabled, matcher.manual_mapping_conflict, type != .flagsChanged {
            update_mapping_status()
            return RemoteFlagDecision(flags:event.flags.rawValue,class_mask:0,preserve_mask:7)
        }
        return decision
    }
    private func observe_input(type:CGEventType,event:CGEvent,now_ns:UInt64,protected_mask:UInt8) -> RemoteFlagDecision? {
        guard main_enabled else { return nil }
        let now = now_ns/1000
        activity_source?.or(data: 1)
        let event_time = event.timestamp / 1000
        guard peer_event_time_valid(event_time,now:now) else {
            record_keyboard_decision(type:event.type,event:event,now_ns:now_ns,protected:protected_mask,reason:"invalid_event_time",decision:nil)
            matcher.skipped &+= 1; return nil
        }
        guard let observation = observation(type,event,now:event_time) else {
            record_keyboard_decision(type:event.type,event:event,now_ns:now_ns,protected:protected_mask,reason:"unsupported_physical_key",decision:nil)
            matcher.skipped &+= 1; return nil
        }
        if let reason = drain_publications(input_callback:true) {
            record_keyboard_decision(type:type,event:event,now_ns:now_ns,protected:protected_mask,reason:reason,decision:nil)
            matcher.skipped &+= 1; return nil
        }
        let decision = matcher.decide(observation,now:Int64(max(now,peer_now_us())),protected:protected_mask)
        record_keyboard_decision(type:type,event:event,now_ns:now_ns,protected:protected_mask,reason:matcher.last_decision_reason,decision:decision,source_mods:matcher.last_decision_source_mods)
        bind_if_ready()
        update_mapping_status()
        return decision
    }
    private func update_mapping_status() {
        if cache_connected && !cached_transport.error_active && (matcher.ready || cache_generation > 0) {
            let text = matcher.readiness_status_text
            if status_value != text { status_value = text; notice(text) }
        }
    }
    private func record_keyboard_decision(type:CGEventType,event:CGEvent,now_ns:UInt64,protected:UInt8,reason:String,decision:RemoteFlagDecision?,source_mods:UInt16? = nil) {
        guard type == .keyDown || type == .keyUp else { return }
        keyboard_decisions[reason,default:0] &+= 1
        last_keyboard_decision = ["reason":reason,"action":type == .keyDown ? "down" : "up",
            "event_ns":String(event.timestamp),"callback_ns":String(now_ns),"protected_mask":protected,
            "corrected_class_mask":decision?.class_mask ?? 0,
            "before":String(event.flags.rawValue,radix:16),"after":String(decision?.flags ?? event.flags.rawValue,radix:16)]
        if let mods = source_mods {
            last_keyboard_decision["matched_source_modifiers"] = mods
            last_keyboard_decision["source_future_ahead_us"] = matcher.last_decision_future_ahead_us
        }
    }
    private func observation(_ type:CGEventType,_ event:CGEvent,now:UInt64) -> PeerObservation? {
        var result = PeerObservation(time:Int64(now),kind:"",key:0,action:"",flags:event.flags.rawValue)
        if type == .flagsChanged {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let classes: [Int64:(Int,UInt64)] = [55:(0,8),54:(0,16),58:(1,32),61:(1,64),59:(2,1),62:(2,8192)]
            guard let spec = classes[key] else { return nil }
            result.kind = "modifier"; result.modifier_class = spec.0; result.side_bit = spec.1
            result.action = result.flags & spec.1 != 0 ? "down" : "up"
        } else if type == .keyDown || type == .keyUp {
            guard let key = peer_usb_key(event.getIntegerValueField(.keyboardEventKeycode)) else { return nil }
            result.kind = "key"; result.key = key; result.action = type == .keyDown ? "down" : "up"
            result.keypad_plus_alias = matcher.keypad_plus_enabled && [46,87,103].contains(key)
        } else if [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp].contains(type) {
            result.kind = "button"; result.key = Int(event.getIntegerValueField(.mouseEventButtonNumber))+1
            result.action = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type) ? "down":"up"
        } else if type == .scrollWheel {
            let y = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let x = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            guard (x == 0) != (y == 0) else { return nil }
            result.kind = "wheel"; result.action = "pulse"; result.key = y != 0 ? (y > 0 ? 1:2):(x > 0 ? 3:4)
        } else if [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type) {
            result.kind = "motion"; result.action = "move"
        } else { return nil }
        return result
    }
    func reset(reason:String) {
        let token = UUID().uuidString
        main_configuration_token = token
        cache_connected = false
        matcher.clear(now:Int64(peer_now_us())); cache_epoch = ""; binding_requested = ""
        queue.async { [weak self] in
            guard let self = self else { return }
            self.network_configuration_token = token
            if self.active { self.send(self.packet("stop")) }
            self.new_epoch(); self.status("辅助同步重新学习")
        }
    }
    private func shutdown(completion: @escaping ()->Void) {
        if active { send(packet("stop")) }
        timer?.cancel(); timer = nil
        active = false; enabled = false; acknowledged = false
        shutdown_callbacks.append(completion)
        if socket_closing { return }
        if let source = read_source {
            let fd = socket_fd
            socket_fd = -1; read_source = nil; socket_closing = true
            source.setCancelHandler {
                Darwin.close(fd)
                self.socket_closing = false
                self.finish_shutdown()
            }
            source.cancel()
        } else {
            if socket_fd >= 0 { Darwin.close(socket_fd); socket_fd = -1 }
            finish_shutdown()
        }
    }
    private func finish_shutdown() {
        let callbacks = shutdown_callbacks; shutdown_callbacks.removeAll()
        for completion in callbacks { completion() }
    }
    // Shutdown callers only: input callbacks never invoke this bounded wait.
    func stop() {
        main_configuration_token = UUID().uuidString
        main_enabled = false; cache_connected = false; cache_epoch = ""; matcher.clear(now:Int64(peer_now_us()))
        let completion = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self = self else { completion.signal(); return }
            self.configuration_revision &+= 1
            self.shutdown { completion.signal() }
        }
        _ = completion.wait(timeout: .now() + .milliseconds(200))
    }
    func diagnostic_summary()->[String:Any] {
        ["status":status_value,"connected":cache_connected,"transport":cached_transport.summary,"corrected":matcher.corrected,"skipped":matcher.skipped,
         "window_learned":matcher.ready,"verified_modifier_sides":peer_modifier_sides.filter { matcher.verified_mapping($0.bit) }.count,
         "mapping_mode":matcher.manual_mapping == nil ? "automatic" : "manual",
         "manual_mapping_conflict":matcher.manual_mapping_conflict,"keypad_plus_enabled":matcher.keypad_plus_enabled,
         "required_modifiers":peer_required_modifier_sides.map(\.name),"required_modifier_sides":3,
         "verified_required_modifier_sides":peer_required_modifier_sides.filter { matcher.verified_mapping($0.bit) }.count,
         "unverified_modifiers":peer_required_modifier_sides.filter { !matcher.verified_mapping($0.bit) }.map(\.name),
         "modifier_mapping_details":matcher.modifier_mapping_diagnostic(),
         "keyboard_decisions":keyboard_decisions,"last_keyboard_decision":last_keyboard_decision,
         "late_keyboard_calibrations":matcher.late_keyboard_calibrations,
         "future_tolerance_accepts":matcher.future_tolerance_accepts,
         "clock_future_tolerance_us":matcher.rtt.isFinite ? matcher.rtt/2 : -1,
         "callback_publications":callback_publications,"max_publication_wait_us":max_publication_wait_us,
         "source_cache_count":matcher.source.count,"observation_cache_count":matcher.observations.count,
         "clock_rtt_us":matcher.rtt.isFinite ? matcher.rtt : -1]
    }
}
