import Foundation
import CoreGraphics
import Darwin

struct RemoteFlagDecision { let flags: UInt64; let class_mask: UInt8; var preserve_mask: UInt8 = 0 }
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
    var flags: UInt64; var modifier_class: Int?; var side_bit: UInt64 = 0
}
let peer_modifier_sides: [(bit: Int, name: String, group: Int)] = [
    (1,"左Ctrl",0),(2,"右Ctrl",0),(4,"左Win",2),(8,"右Win",2),(16,"左Alt",1),(32,"右Alt",1)
]
let peer_required_modifier_sides = peer_modifier_sides.filter { $0.bit & (1 | 4 | 16) != 0 }
final class PeerMatcher {
    var source: [PeerInput] = []; var observations: [PeerObservation] = []
    var consumed: [UInt64:Int64] = [:]; var last_consumed_id: UInt64 = 0; var learned_window: String?
    var offset: Double?; var rtt: Double = .infinity; var clock_at: Int64 = 0
    var delays: [Int64] = []; var ordinary_pair = false
    var mappings: [Int: (Int, UInt64)] = [:]
    var mapping_edges: [Int: (Int, UInt64, UInt8)] = [:]
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
    let source_sides: [(left: Int, right: Int)] = [(1,2),(16,32),(4,8)]
    var unverified_modifier_names: [String] {
        peer_required_modifier_sides.filter { mappings[$0.bit]?.0 != $0.group }.map(\.name)
    }
    var mapping_status_text: String {
        let pending = unverified_modifier_names
        return pending.isEmpty ? "辅助同步中，左侧修饰键映射已验证（3/3）" : "辅助同步中，左侧修饰键映射待验证（\(3-pending.count)/3）：\(pending.joined(separator:"、"))"
    }
    var readiness_status_text: String {
        ready ? mapping_status_text : "辅助同步中，正在重新学习远程窗口（左侧修饰键映射\(3-unverified_modifier_names.count)/3）"
    }
    func modifier_mapping_diagnostic() -> [[String:Any]] {
        peer_modifier_sides.map { side in
            let edges = mapping_edges[side.bit]
            let compatible_edges = edges?.0 == side.group ? (edges?.2 ?? 0) : 0
            return ["source_modifier":side.name,"target_modifier":["Command","Option","Control"][side.group],
                    "required":peer_required_modifier_sides.contains { $0.bit == side.bit },
                    "verified":mappings[side.bit]?.0 == side.group,
                    "matched_down":compatible_edges & 1 != 0,"matched_up":compatible_edges & 2 != 0]
        }
    }
    func class_mapping_available(_ index: Int, state: UInt16) -> Bool {
        let sides = source_sides[index]
        guard mappings[sides.left]?.0 == index else { return false }
        // 右侧不要求预先学习，但按住未验证的右侧时不能清除或推断整类标记。
        return state & UInt16(sides.right) == 0 || mappings[sides.right]?.0 == index
    }
    func clear(keep_consumed: Bool = true) {
        source.removeAll(); observations.removeAll(); delays.removeAll(); pending_snapshots.removeAll(); hole_since = nil
        ordinary_pair = false; learned_window = nil; mappings.removeAll(); mapping_edges.removeAll(); transitions.removeAll()
        continuity = false; tentative_window = nil; highest_id = 0; offset = nil; rtt = .infinity; clock_at = 0
        if !keep_consumed { consumed.removeAll(); last_consumed_id = 0 }
    }
    func window_clear() {
        stream_clear(); delays.removeAll(); ordinary_pair = false
        tentative_window = nil; learned_window = nil
    }
    func stream_clear(new_generation: Bool = false) {
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
    func group(_ key: Int) -> Int? {
        switch key { case 224,228: return 0; case 226,230: return 1; case 227,231: return 2; default: return nil }
    }
    func compatible(_ event: PeerInput, _ observation: PeerObservation) -> Bool {
        guard event.kind == observation.kind && event.action == observation.action else { return false }
        if observation.kind == "modifier" { return group(event.key) == observation.modifier_class }
        return event.key == observation.key
    }
    func candidates(_ observation: PeerObservation, now: Int64) -> [PeerInput] {
        source.filter { event in
            guard event.id > last_consumed_id, consumed[event.id] == nil, compatible(event, observation), learned_window == nil || event.window == learned_window else { return false }
            let difference = observation.time - mapped(event.time_us)
            if ready { return abs(Double(difference) - Double(delay())) <= 25_000 + rtt/2 }
            return difference >= -50_000 && difference <= 250_000
        }
    }
    func pair(_ observation: PeerObservation, now: Int64) -> PeerInput? {
        guard healthy(now) else { last_pair_reason = "clock_unhealthy"; return nil }
        guard hole_since == nil else { last_pair_reason = "sequence_hole"; return nil }
        guard observation.kind != "motion" else { last_pair_reason = "motion_not_paired"; return nil }
        let matches = candidates(observation, now: now)
        guard !matches.isEmpty else { last_pair_reason = "no_candidate"; return nil }
        guard matches.count == 1, let event = matches.first else { last_pair_reason = "ambiguous_candidates"; return nil }
        let d = observation.time - mapped(event.time_us)
        if !ready, !delays.isEmpty, abs(Double(d) - Double(delay())) > 20_000 { last_pair_reason = "inconsistent_learning_delay"; return nil }
        // Calibration cannot combine windows: restart tentative samples on candidate change.
        if learned_window == nil, let first = tentative_window, first != event.window { delays.removeAll(); ordinary_pair = false }
        tentative_window = event.window
        consumed[event.id] = now; last_consumed_id = event.id
        if consumed.count > 512, let oldest = consumed.min(by: { $0.value < $1.value })?.key { consumed.removeValue(forKey: oldest) }
        delays.append(d)
        if delays.count > 8 { delays.removeFirst() }
        ordinary_pair = ordinary_pair || observation.kind == "key" || observation.kind == "button"
        if learned_window == nil && delays.count >= 3 && ordinary_pair { learned_window = event.window }
        if let index = observation.modifier_class, let source_group = group(event.key), source_group == index {
            let source_bit = bit(event.key)
            let down = event.action == "down"
            let aggregate_down = observation.flags & aggregate[index] != 0
            // Device mapping is proven by the physical modifier's own matched edge.
            if source_bit != 0 && aggregate_down == down && observation.side_bit != 0 {
                let side_down = observation.flags & observation.side_bit != 0
                if side_down == down {
                    let prior = mapping_edges[Int(source_bit)]
                    let edge: UInt8 = down ? 1 : 2
                    let combined = prior?.0 == index && prior?.1 == observation.side_bit ? (prior!.2 | edge) : edge
                    if let verified = mappings[Int(source_bit)], verified.0 != index || verified.1 != observation.side_bit {
                        mappings.removeValue(forKey: Int(source_bit))
                    }
                    mapping_edges[Int(source_bit)] = (index, observation.side_bit, combined)
                    if combined == 3 { mappings[Int(source_bit)] = (index, observation.side_bit) }
                }
            }
        }
        last_pair_reason = "matched"
        return event
    }
    func bit(_ key: Int) -> UInt16 {
        switch key { case 224:return 1;case 228:return 2;case 227:return 4;case 231:return 8;case 226:return 16;case 230:return 32;default:return 0 }
    }
    private func expire_pending(_ now: Int64) {
        let timed = pending_snapshots.filter { now >= $0.3 && now-$0.3 >= 100_000 }
        guard (hole_since.map { now >= $0 && now-$0 >= 100_000 } ?? false) || !timed.isEmpty else { return }
        let watermark = max(highest_id, max(source.map(\.id).max() ?? 0, timed.map { $0.2 }.max() ?? 0))
        let last = timed.last
        window_clear(); highest_id = watermark; last_consumed_id = max(last_consumed_id,watermark)
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
        if gap { window_clear() }
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
            window_clear(); highest_id = watermark; last_consumed_id = max(last_consumed_id,watermark)
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
            if pending_snapshots.count > 16 { window_clear() }
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
                if last_decision_future_ahead_us > 0 { future_tolerance_accepts &+= 1 }
            }
        } else {
            last_decision_reason = last_pair_reason
            observations.append(observation)
            if observations.count > 512 { observations.removeFirst(); continuity = false; transitions.removeAll() }
        }
        if observation.kind == "modifier" { last_decision_reason = "modifier_observation"; skipped &+= 1; return nil }
        guard let state = mods else { skipped &+= 1; return nil }
        var flags = observation.flags; var mask: UInt8 = 0; var preserve_mask: UInt8 = 0
        let groups: [UInt16] = [3,48,12]
        for index in 0..<3 where protected & (1 << index) == 0 {
            let bits: [UInt16] = (0..<8).map { UInt16(1 << $0) }.filter { groups[index] & $0 != 0 }
            if state & UInt16(source_sides[index].right) != 0 && mappings[source_sides[index].right]?.0 != index {
                preserve_mask |= 1 << index
                continue
            }
            guard class_mapping_available(index,state:state) else { continue }
            mask |= 1 << index; flags &= ~(aggregate[index] | devices[index])
            if state & groups[index] != 0 { flags |= aggregate[index] }
            for bit in bits where state & bit != 0 { flags |= mappings[Int(bit)]!.1 }
        }
        guard mask != 0 else {
            if preserve_mask != 0 {
                last_decision_reason = "unverified_active_right_modifier"; skipped &+= 1
                return RemoteFlagDecision(flags:flags,class_mask:0,preserve_mask:preserve_mask)
            }
            let any_verified = (0..<3).contains { class_mapping_available($0,state:state) }
            last_decision_reason = any_verified ? "local_modifier_protected" : "mapping_unverified"
            skipped &+= 1; return nil
        }
        last_decision_reason = flags == observation.flags ? "matched_flags_unchanged" : "flags_corrected"
        if flags != observation.flags { corrected &+= 1 }
        return RemoteFlagDecision(flags: flags, class_mask: mask, preserve_mask: preserve_mask)
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
final class RemotePeerBridge {
    private let queue = DispatchQueue(label: "uu.peer.network")
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
    var keyboard_decision_reason: String { last_keyboard_decision["reason"] as? String ?? "not_attempted" }
    init(status_notice: @escaping (String)->Void, local_port: UInt16 = 47731, peer_port: UInt16 = 47731) {
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
    private func status(_ text: String) { publish { [weak self] in guard let self = self, self.status_value != text else { return }; self.status_value = text; self.notice(text) } }
    func configure(peer_ip: String, enabled: Bool) throws {
        var parsed = in_addr()
        guard peer_ip.isEmpty || (peer_ip.split(separator: ".").count == 4 && inet_pton(AF_INET, peer_ip, &parsed) == 1) else {
            throw NSError(domain: "UUBridge", code: 1, userInfo: [NSLocalizedDescriptionKey:"请输入有效 IPv4 地址"])
        }
        main_enabled = enabled && !peer_ip.isEmpty
        let token = UUID().uuidString
        main_configuration_token = token
        matcher.clear(); cache_epoch = ""; binding_requested = ""
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
        publish { [weak self] in self?.cache_epoch = fresh; self?.cache_generation = 0; self?.binding_requested = ""; self?.matcher.clear() }
    }
    private func packet(_ kind: String) -> PeerPacket {
        seq &+= 1
        return PeerPacket(kind:kind,instance:instance,peer:win_instance,epoch:epoch,generation:generation,seq:seq,time_us:peer_now_us())
    }
    private func send(_ packet: PeerPacket) {
        guard socket_fd >= 0, let bytes = try? JSONEncoder().encode(packet), bytes.count <= 1200 else { return }
        bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to:&address) { pointer in
                _ = pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.sendto(socket_fd,buffer.baseAddress,bytes.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }
    private func invalidate_main() { publish { [weak self] in self?.matcher.stream_clear() } }
    private func cease() {
        active = false; generation &+= 1; send(packet("stop"))
        let revoked = generation
        publish { [weak self] in self?.cache_generation = revoked; self?.matcher.stream_clear() }
        status("已连接，等待 UU 输入")
    }
    private func receive_pending(fd: Int32) {
        // Socket readiness wakes the network queue; input callbacks never read it.
        for _ in 0..<32 {
            var bytes = [UInt8](repeating:0,count:1201); var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to:&sender) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.recvfrom(fd,&bytes,bytes.count,0,$0,&length) } }
            if count < 0 { break }
            let receipt_now = peer_now_us()
            guard count <= 1200, sender.sin_addr.s_addr == address.sin_addr.s_addr, sender.sin_port == address.sin_port,
                  let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(bytes.prefix(count))), p.v == 1,
                  p.time_us <= UInt64(Int64.max), !p.instance.isEmpty, p.instance.count <= 128,
                  UUID(uuidString:p.instance) != nil,
                  (UUID(uuidString:p.epoch) != nil || (p.kind == "hello" && p.peer.isEmpty && p.epoch.isEmpty)), (p.window?.count ?? 0) <= 128 else { continue }
            receive(p,now:receipt_now)
        }
    }
    private func tick() {
        let now = peer_now_us()
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
        if active && now-last_activity >= 2_000_000 { cease() }
        if active && now-last_start >= 100_000 {
            last_start = now; var p = packet("start"); p.window = window; send(p)
        }
    }
    private func update_scope(_ p: PeerPacket) {
        scope = p.scope ?? scope; window = p.window ?? window
        if active && (!scope || (!bound_window.isEmpty && window != bound_window)) { cease() }
    }
    private func receive(_ p: PeerPacket, now: UInt64) {
        guard p.peer == instance || (p.kind == "hello" && p.peer.isEmpty) else { return }
        if p.kind == "hello" && p.peer.isEmpty {
            guard !retired.contains(p.instance) else { return }
            if !win_instance.isEmpty && win_instance != p.instance {
                retired.insert(win_instance); new_epoch(); publish { [weak self] in self?.matcher.clear(keep_consumed: false) }
            }
            win_instance = p.instance
            if acknowledged { last_peer = now; return }
            if let w = p.window { window = w }; scope = p.scope ?? false
            send(packet("hello")); last_peer = now; return
        }
        guard p.instance == win_instance, p.epoch == epoch else { return }
        if p.kind == "hello" {
            let first_ack = !acknowledged
            guard first_ack || p.seq > received_seq else { return }
            acknowledged = true; last_peer = now; received_seq = max(received_seq,p.seq)
            update_scope(p)
            if first_ack { status("已连接，等待 UU 输入") }; return
        }
        guard acknowledged else { return }
        if p.kind == "events" || p.kind == "snapshot" {
            guard !received_data.contains(p.seq), p.seq > (received_seq > 512 ? received_seq-512 : 0) else { return }
            received_data.insert(p.seq)
            received_data = received_data.filter { $0 > (max(received_seq,p.seq) > 512 ? max(received_seq,p.seq)-512 : 0) }
        } else { guard p.seq > received_seq else { return } }
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
                if let prior = self.matcher.offset, abs(prior-best_offset) > 50_000 { self.matcher.clear() }
                self.matcher.rtt = best_rtt; self.matcher.offset = best_offset
                self.matcher.clock_at = Int64(now)
            }; return
        }
        if p.kind == "prepare" || p.kind == "heartbeat" {
            update_scope(p)
            return
        }
        guard active, p.generation == generation else { return }
        if p.kind == "stop" { cease(); return }
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
        queue.async { [weak self] in
            guard let self = self, self.active, self.epoch == requested_epoch, self.bound_window != learned else { return }
            self.bound_window = learned; var p = self.packet("bind"); p.window = learned; self.send(p)
            self.status("远程窗口已学习，等待修饰键映射验证")
        }
    }
    private func activity() {
        guard enabled, acknowledged else { return }
        last_activity = peer_now_us()
        if !active && scope && !window.isEmpty {
            active = true; generation &+= 1; last_start = 0
            let fresh_generation = generation
            let changing_window = !bound_window.isEmpty && bound_window != window
            if changing_window { bound_window = "" }
            publish { [weak self] in
                self?.cache_generation = fresh_generation
                self?.matcher.stream_clear(new_generation:true)
                if changing_window { self?.matcher.window_clear(); self?.binding_requested = "" }
            }
            status("正在学习远程窗口")
        }
    }
    func observe(type:CGEventType,event:CGEvent,now_ns:UInt64,protected_mask:UInt8) -> RemoteFlagDecision? {
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
        if matcher.ready || cache_generation > 0 {
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
        matcher.clear(); cache_epoch = ""; binding_requested = ""
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
        main_enabled = false; cache_epoch = ""; matcher.clear()
        let completion = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self = self else { completion.signal(); return }
            self.configuration_revision &+= 1
            self.shutdown { completion.signal() }
        }
        _ = completion.wait(timeout: .now() + .milliseconds(200))
    }
    func diagnostic_summary()->[String:Any] {
        ["status":status_value,"corrected":matcher.corrected,"skipped":matcher.skipped,
         "window_learned":matcher.ready,"verified_modifier_sides":matcher.mappings.count,
         "required_modifiers":peer_required_modifier_sides.map(\.name),"required_modifier_sides":3,
         "verified_required_modifier_sides":3-matcher.unverified_modifier_names.count,
         "unverified_modifiers":matcher.unverified_modifier_names,"modifier_mapping_details":matcher.modifier_mapping_diagnostic(),
         "keyboard_decisions":keyboard_decisions,"last_keyboard_decision":last_keyboard_decision,
         "late_keyboard_calibrations":matcher.late_keyboard_calibrations,
         "future_tolerance_accepts":matcher.future_tolerance_accepts,
         "clock_future_tolerance_us":matcher.rtt.isFinite ? matcher.rtt/2 : -1,
         "callback_publications":callback_publications,"max_publication_wait_us":max_publication_wait_us,
         "source_cache_count":matcher.source.count,"observation_cache_count":matcher.observations.count,
         "clock_rtt_us":matcher.rtt.isFinite ? matcher.rtt : -1]
    }
}
