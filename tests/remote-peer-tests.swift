import Foundation
import CoreGraphics
import Darwin

@main struct RemotePeerTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(label)") }
    }
    static func input(_ id:UInt64,_ time:UInt64,_ key:Int = 4,_ mods:UInt16 = 0,_ kind:String = "key",_ action:String = "down",_ window:String = "window") -> PeerInput {
        PeerInput(id:id,time_us:time,window:window,kind:kind,key:key,action:action,mods:mods)
    }
    static func observation(_ time:Int64,_ key:Int = 4,_ flags:UInt64 = 0,_ kind:String = "key",_ action:String = "down") -> PeerObservation {
        PeerObservation(time:time,kind:kind,key:key,action:action,flags:flags)
    }
    static func fresh() -> PeerMatcher {
        let m = PeerMatcher(); m.offset = 0; m.rtt = 1000; m.clock_at = 1_000_000
        return m
    }
    static func ready() -> PeerMatcher {
        let m = fresh()
        for n in 1...3 {
            let time = UInt64(1_000_000 + n*10_000)
            m.ingest([input(UInt64(n),time)],gap:false,now:Int64(time))
            _ = m.decide(observation(Int64(time)+5000),now:Int64(time)+5000,protected:0)
        }
        return m
    }
    static func cold_handshake() throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        check(fd >= 0, "test UDP socket")
        defer { Darwin.close(fd) }
        var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET); local.sin_port = UInt16(49002).bigEndian
        local.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&local) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(bound == 0, "test peer port bound")
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        var dest = local; dest.sin_port = UInt16(49001).bigEndian
        let remote = RemotePeerBridge(status_notice:{ _ in },local_port:49001,peer_port:49002)
        try remote.configure(peer_ip:"127.0.0.1",enabled:true)
        try remote.configure(peer_ip:"127.0.0.1",enabled:true)
        defer { remote.stop(); RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let win = UUID().uuidString
        func send(_ p:PeerPacket) throws {
            let data = try JSONEncoder().encode(p)
            data.withUnsafeBytes { bytes in withUnsafePointer(to:&dest) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { _ = Darwin.sendto(fd,bytes.baseAddress,data.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
        try send(PeerPacket(kind:"hello",instance:win,peer:"",epoch:"",generation:0,seq:1,time_us:peer_now_us()))
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        var response:PeerPacket?
        for _ in 0..<20 {
            var bytes = [UInt8](repeating:0,count:1201)
            let n = Darwin.recv(fd,&bytes,bytes.count,0)
            if n < 0 { break }
            if let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(bytes.prefix(n))), p.kind == "hello", p.peer == win { response = p }
        }
        check(response != nil && UUID(uuidString:response?.epoch ?? "") != nil,"consecutive same-port configurations receive targeted Mac hello session")
        guard let response = response else { return }
        try send(PeerPacket(kind:"hello",instance:win,peer:response.instance,epoch:response.epoch,generation:0,seq:2,time_us:peer_now_us()))
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(remote.status_text == "已连接，等待 UU 输入","Win acknowledgement completes cold handshake")
        try send(PeerPacket(kind:"hello",instance:win,peer:"",epoch:"",generation:0,seq:3,time_us:peer_now_us()))
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        var buffer = [UInt8](repeating:0,count:1201)
        check(Darwin.recv(fd,&buffer,buffer.count,0) < 0,"acknowledged peer does not create hello feedback loop")
        let window = UUID().uuidString
        var prepare = PeerPacket(kind:"prepare",instance:win,peer:response.instance,epoch:response.epoch,generation:0,seq:4,time_us:peer_now_us())
        prepare.window = window; prepare.scope = true; try send(prepare)
        var stale_hello = PeerPacket(kind:"hello",instance:win,peer:response.instance,epoch:response.epoch,generation:0,seq:2,time_us:peer_now_us())
        stale_hello.window = UUID().uuidString; stale_hello.scope = false; try send(stale_hello)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let activity = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
        activity.timestamp = DispatchTime.now().uptimeNanoseconds
        _ = remote.observe(type:.keyDown,event:activity,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0)
        let decision_summary = remote.diagnostic_summary()
        let decision_counts = decision_summary["keyboard_decisions"] as? [String:UInt64]
        check(decision_counts?["clock_unhealthy"] == 1,"keyboard diagnostics distinguish missing clock evidence")
        let decision_fields = decision_summary["last_keyboard_decision"] as? [String:Any] ?? [:]
        check(Set(decision_fields.keys) == Set(["reason","action","event_ns","callback_ns","protected_mask","corrected_class_mask","before","after"]),
              "keyboard decision diagnostics expose only allowed metadata")
        RunLoop.main.run(until:Date().addingTimeInterval(0.04))
        var start: PeerPacket?
        for _ in 0..<20 {
            var bytes = [UInt8](repeating:0,count:1201)
            let n = Darwin.recv(fd,&bytes,bytes.count,0)
            if n < 0 { break }
            if let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(bytes.prefix(n))), p.kind == "start" { start = p }
        }
        check(start?.window == window,"stale same-epoch hello cannot roll foreground scope back")
        guard let start = start else { return }
        let instant = peer_now_us()
        var snapshot = PeerPacket(kind:"snapshot",instance:win,peer:response.instance,epoch:response.epoch,generation:start.generation,seq:10,time_us:instant)
        snapshot.window = window; snapshot.mods = 0; snapshot.event_seq = 3; try send(snapshot)
        var later = PeerPacket(kind:"events",instance:win,peer:response.instance,epoch:response.epoch,generation:start.generation,seq:9,time_us:instant)
        later.window = window; later.events = [input(3,instant,6,0,"key","down",window)]; try send(later)
        var earlier = later; earlier.seq = 8; earlier.events = [input(1,instant-2000,4,0,"key","down",window),input(2,instant-1000,5,0,"key","down",window)]; try send(earlier)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(remote.diagnostic_summary()["source_cache_count"] as? Int == 3,"real UDP older split event packets remain receivable after newer snapshot")
        var invalid_time = later; invalid_time.seq = 12
        invalid_time.events = [input(4,instant,7,0,"key","down",window),input(5,instant+1,8,0,"key","down",window)]
        try send(invalid_time)
        RunLoop.main.run(until:Date().addingTimeInterval(0.04))
        check(remote.diagnostic_summary()["source_cache_count"] as? Int == 3,
              "one source time after packet send time rejects the complete UDP event batch")
        activity.timestamp = DispatchTime.now().uptimeNanoseconds+1_000_000_000
        check(remote.observe(type:.keyDown,event:activity,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0) == nil,
              "enabled bridge still rejects a future Mac event timestamp")
        RunLoop.main.run(until:Date().addingTimeInterval(1.05))
        var ping:PeerPacket?
        for _ in 0..<40 {
            var bytes = [UInt8](repeating:0,count:1201)
            let n = Darwin.recv(fd,&bytes,bytes.count,0)
            if n < 0 { break }
            if let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(bytes.prefix(n))), p.kind == "ping" { ping = p }
        }
        check(ping != nil,"real periodic ping emitted after handshake")
        if let ping = ping {
            var pong = PeerPacket(kind:"pong",instance:win,peer:response.instance,epoch:response.epoch,generation:start.generation,seq:13,time_us:peer_now_us())
            pong.echo_us = ping.time_us; pong.recv_us = pong.time_us
            try send(pong)
            RunLoop.main.run(until:Date().addingTimeInterval(0.04))
            check((remote.diagnostic_summary()["clock_rtt_us"] as? Double ?? -1) >= 0,"pending ping survives insertion and correlates real pong")
        }
        let stop_at = DispatchTime.now().uptimeNanoseconds
        remote.stop()
        check(DispatchTime.now().uptimeNanoseconds-stop_at < 250_000_000,"stop returns within bounded shutdown wait")
        let stopped_status = remote.status_text
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(remote.status_text == stopped_status,"queued main publications cannot revive status after stop")
        let replacement = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        defer { Darwin.close(replacement) }
        var replacement_address = local; replacement_address.sin_port = UInt16(49001).bigEndian
        let replacement_bound = withUnsafePointer(to:&replacement_address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(replacement,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(replacement_bound == 0,"stop closes UDP listener before normal return")



    }
    static func future_source_boundaries() {
        let cmd = CGEventFlags.maskCommand.rawValue
        let at_boundary = ready(); at_boundary.mappings[1] = (0,8)
        at_boundary.ingest([input(4,1_055_500,25,1)],gap:false,now:1_055_000)
        check(at_boundary.decide(observation(1_055_000,25),now:1_055_000,protected:0)?.flags == cmd|8,
              "uniquely paired source ahead by exactly half RTT corrects flags")
        check(at_boundary.last_decision_future_ahead_us == 500 && at_boundary.future_tolerance_accepts == 1,
              "accepted clock uncertainty exposes bounded ahead distance and count")
        at_boundary.ingest([input(5,1_060_000,25,1)],gap:false,now:1_060_000)
        _ = at_boundary.decide(observation(1_065_000,25),now:1_065_000,protected:0)
        check(at_boundary.last_decision_future_ahead_us == 0 && at_boundary.future_tolerance_accepts == 1,
              "each decision clears ahead distance without counting ordinary past sources")
        let beyond = ready(); beyond.mappings[1] = (0,8)
        beyond.ingest([input(4,1_055_501,25,1)],gap:false,now:1_055_000)
        check(beyond.decide(observation(1_055_000,25),now:1_055_000,protected:0) == nil && beyond.last_decision_reason == "source_from_future",
              "source ahead by half RTT plus one microsecond remains rejected")
        check(beyond.future_tolerance_accepts == 0,"rejected future source does not count as an acceptance")
        let unhealthy = ready(); unhealthy.mappings[1] = (0,8); unhealthy.rtt = 40_001
        unhealthy.ingest([input(4,1_055_500,25,1)],gap:false,now:1_055_000)
        check(unhealthy.decide(observation(1_055_000,25),now:1_055_000,protected:0) == nil && unhealthy.last_decision_reason == "clock_unhealthy",
              "future tolerance cannot bypass clock health")
        let protected = ready(); protected.mappings[1] = (0,8)
        protected.ingest([input(4,1_055_500,25,1)],gap:false,now:1_055_000)
        check(protected.decide(observation(1_055_000,25),now:1_055_000,protected:1) == nil && protected.last_decision_reason == "local_modifier_protected",
              "future tolerance cannot bypass local modifier protection")
        let ambiguous = ready(); ambiguous.mappings[1] = (0,8)
        ambiguous.ingest([input(4,1_055_499,25,1),input(5,1_055_500,25,1)],gap:false,now:1_055_000)
        check(ambiguous.decide(observation(1_055_000,25),now:1_055_000,protected:0) == nil && ambiguous.last_decision_reason == "ambiguous_candidates",
              "future tolerance cannot choose between repeated candidate inputs")
    }
    static func publication_queue() {
        let queued = PeerPublicationQueue()
        let matcher = ready(); matcher.mappings[1] = (0,8)
        check(queued.append({ matcher.ingest([input(4,1_050_000,25,1)],gap:false,now:1_051_000) }),
              "first queued publication requests main scheduling")
        if case .ready(let batch,let overflow) = queued.take(input_callback:true) {
            check(!overflow && batch.count == 1,"input callback takes already decoded evidence")
            batch.forEach { $0.body() }
        } else { check(false,"small publication batch remains available to input callback") }
        check(matcher.decide(observation(1_055_000,25),now:1_055_000,protected:0)?.flags == CGEventFlags.maskCommand.rawValue|8,
              "queued source evidence is consumed before the current decision")
        _ = queued.append({ matcher.ingest([input(5,1_060_000,25,1)],gap:false,now:1_061_000) })
        _ = queued.append({ matcher.ingest([],gap:true,now:1_061_001) })
        if case .ready(let batch,_) = queued.take(input_callback:true) { batch.forEach { $0.body() } }
        else { check(false,"ordered source and gap publications are taken together") }
        check(matcher.decide(observation(1_065_000,25),now:1_065_000,protected:0) == nil && !matcher.ready,
              "queued gap is applied in order before correction and cannot be skipped")
        var received = [Int]()
        for n in 0..<8 { _ = queued.append({ received.append(n) },work:4) }
        if case .ready(let batch,let overflow) = queued.take(input_callback:true) {
            check(batch.count == 8 && !overflow,"callback accepts exactly eight publications totaling thirty-two work units")
            batch.forEach { $0.body() }
        } else { check(false,"callback count and work boundary remains usable") }
        check(received == Array(0..<8),"bounded callback batch preserves publication order")
        received.removeAll()
        for n in 0..<9 { _ = queued.append({ received.append(n) }) }
        if case .backlog = queued.take(input_callback:true) { check(true,"callback refuses more than eight publications") }
        else { check(false,"callback batch count bound") }
        if case .ready(let batch,_) = queued.take(input_callback:false) { batch.forEach { $0.body() } }
        check(received == Array(0..<9),"backlog rejection leaves all publications for ordinary draining")
        _ = queued.append({ received.append(9) },work:33)
        if case .backlog = queued.take(input_callback:true) { check(true,"callback refuses excess aggregate work") }
        else { check(false,"callback work bound") }
        if case .ready(let batch,_) = queued.take(input_callback:false) { batch.forEach { $0.body() } }
        check(received.last == 9,"work rejection leaves publication intact")
        let blocked = PeerPublicationQueue()
        _ = blocked.append({ received.append(11) })
        _ = blocked.append({ received.append(12) })
        if case .backlog = blocked.take(input_callback:true,can_apply:false) {
            check(true,"a prohibited callback leaves a nonempty publication batch intact")
        } else { check(false,"callback publication application gate") }
        if case .ready(let batch,let overflow) = blocked.take(input_callback:false,can_apply:false) {
            batch.forEach { $0.body() }
            check(!overflow && batch.count == 2 && Array(received.suffix(2)) == [11,12],
                  "ordinary draining consumes the complete prohibited callback batch in order")
        } else { check(false,"ordinary draining remains available while callback application is prohibited") }
        if case .ready(let batch,let overflow) = blocked.take(input_callback:true,can_apply:false) {
            check(batch.isEmpty && !overflow,"an empty callback batch is usable even when publication application is prohibited")
        } else { check(false,"empty batch must not falsely report backlog") }
        let lock = NSLock(); let busy = PeerPublicationQueue(lock:lock)
        _ = busy.append({ received.append(10) })
        lock.lock()
        if case .busy = busy.take(input_callback:true) { check(true,"callback lock contention returns without waiting") }
        else { check(false,"callback uses nonblocking publication lock") }
        lock.unlock()
        if case .ready(let batch,_) = busy.take(input_callback:false) { batch.forEach { $0.body() } }
        check(received.last == 10,"lock contention does not consume evidence")
        let overflowing = PeerPublicationQueue()
        for _ in 0..<513 { _ = overflowing.append({ matcher.mappings[1] = (0,8) }) }
        if case .ready(let batch,let overflow) = overflowing.take(input_callback:false) {
            check(batch.isEmpty && overflow,"publication overflow exposes invalidation without stale closures")
            if overflow { matcher.ingest([],gap:true,now:1_070_000) }
        } else { check(false,"ordinary drain receives overflow invalidation") }
        check(!matcher.ready,"overflow publication invalidates learning before any further decision")
    }
    static func main() throws {
        future_source_boundaries()
        publication_queue()
        let data = try Data(contentsOf:URL(fileURLWithPath:"protocol/sample.json"))
        let packet = try JSONDecoder().decode(PeerPacket.self,from:data)
        check(packet.v == 1 && packet.events?.first?.mods == 1,"cross-language fixture")
        let extreme_time = fresh()
        check(extreme_time.mapped(UInt64(Int64.max)) > 0,"maximum decoded timestamp maps without an integer conversion trap")
        let extreme_ready = ready()
        extreme_ready.ingest([input(4,UInt64(Int64.max))],gap:false,now:1_050_000)
        check(extreme_ready.decide(observation(1_055_000),now:1_055_000,protected:0) == nil,
              "extreme future source timestamp is rejected without overflowing delay comparison")
        let encoded = try JSONEncoder().encode(packet)
        check(encoded.count <= 1200,"packet size")
        check(peer_usb_key(9) == 25 && peer_usb_key(999) == nil,"physical key mapping")
        let m = ready(); check(m.ready && m.learned_window == "window","three-pair window learning")
        m.mappings[1] = (0,8); m.mappings[2] = (0,16)
        let cmd = CGEventFlags.maskCommand.rawValue
        m.ingest([input(4,1_050_000,25,1)],gap:false,now:1_051_000)
        let corrected = m.decide(observation(1_055_000,25),now:1_055_000,protected:0)
        check(corrected?.flags == cmd|8 && corrected?.class_mask == 1,"event-specific snapshot repairs missing command")
        check(m.last_decision_reason == "flags_corrected","successful correction has a distinct diagnostic outcome")
        check(m.pair(observation(1_055_000,25),now:1_055_000) == nil,"single consumption")
        m.ingest([input(5,1_060_000,25,0)],gap:false,now:1_061_000)
        let released = m.decide(observation(1_065_000,25,cmd|8|CGEventFlags.maskShift.rawValue),now:1_065_000,protected:0)
        check(released?.flags == CGEventFlags.maskShift.rawValue,"clear stale class, preserve shift")
        m.ingest([input(6,1_070_000,25,0)],gap:false,now:1_071_000)
        check(m.decide(observation(1_075_000,25,cmd),now:1_075_000,protected:1) == nil,"foreign class protection")
        check(m.last_decision_reason == "local_modifier_protected","local protection is diagnosed without bypassing it")
        let ambiguous = ready(); ambiguous.mappings = m.mappings
        ambiguous.ingest([input(4,1_050_000),input(5,1_051_000)],gap:false,now:1_052_000)
        check(ambiguous.decide(observation(1_055_000),now:1_055_000,protected:0) == nil,"ambiguous repeats skip")
        check(ambiguous.last_decision_reason == "ambiguous_candidates","high-frequency ambiguity is distinguishable from missing evidence")
        let old = ready(); old.mappings = m.mappings
        old.ingest([input(4,1_050_000)],gap:false,now:1_051_000)
        check(old.decide(observation(1_055_000),now:1_600_001,protected:0) == nil,"late evidence cannot repair")
        check(old.last_decision_reason == "source_stale","stale evidence receives no current-state fallback")
        let unhealthy = ready(); unhealthy.rtt = 40_001
        check(unhealthy.decide(observation(1_055_000),now:1_055_000,protected:0) == nil,"RTT gate")
        check(unhealthy.last_decision_reason == "clock_unhealthy","clock rejection has a separate diagnostic reason")
        check(!m.healthy(12_000_000),"clock expires")
        let late = fresh()
        for n in 1...3 {
            let time = Int64(1_000_000+n*10_000)
            check(late.decide(observation(time+5000),now:time+5000,protected:0) == nil,"forwarded observation unchanged")
            late.ingest([input(UInt64(n),UInt64(time))],gap:false,now:time+6000)
        }
        check(late.ready && late.corrected == 0,"late observations calibrate only")
        check(late.late_keyboard_calibrations == 3,"forwarded keyboard observations count as late calibration, never correction")
        let motion = ready(); motion.mappings = m.mappings
        motion.snapshot(time:1_050_000,mods:1,event_seq:3,now:1_050_000)
        motion.snapshot(time:1_150_000,mods:1,event_seq:3,now:1_150_000)
        check(motion.decide(observation(1_105_000,0,0,"motion","move"),now:1_150_000,protected:0)?.flags == cmd|8,"whole motion interval stable proof")
        motion.ingest([],gap:true,now:1_160_000)
        check(motion.transitions.isEmpty && !motion.continuity,"gap destroys continuity")
        check(motion.mappings.count == 2 && !motion.ready && motion.readiness_status_text.contains("重新学习"),
              "gap status reports relearning even when modifier mapping remains verified")
        motion.snapshot(time:1_170_000,mods:0,event_seq:5,now:1_170_000)
        check(motion.decide(observation(1_105_000,0,cmd,"motion","move"),now:1_180_000,protected:0) == nil,"snapshot never proves historical gap")
        let edges = fresh()
        var down = observation(1_015_000,0,cmd|8,"modifier","down"); down.modifier_class = 0; down.side_bit = 8
        edges.ingest([input(1,1_010_000,224,1,"modifier","down")],gap:false,now:1_010_000)
        check(edges.decide(down,now:1_015_000,protected:0) == nil && edges.mappings.isEmpty,"down alone does not verify mapping")
        let pending_left_ctrl = edges.modifier_mapping_diagnostic()[0]
        check(pending_left_ctrl["matched_down"] as? Bool == true && pending_left_ctrl["matched_up"] as? Bool == false && pending_left_ctrl["verified"] as? Bool == false,
              "mapping diagnostics distinguish a matched down edge from a complete verification")
        var up = observation(1_025_000,0,0,"modifier","up"); up.modifier_class = 0; up.side_bit = 8
        edges.ingest([input(2,1_020_000,224,0,"modifier","up")],gap:false,now:1_020_000)
        _ = edges.decide(up,now:1_025_000,protected:0)
        check(edges.mappings[1]?.1 == 8,"real down-up verifies physical side")
        check(!edges.unverified_modifier_names.contains("左Ctrl") && edges.modifier_mapping_diagnostic()[0]["verified"] as? Bool == true,
              "completed physical side leaves the pending list")
        let five_sides = fresh()
        five_sides.mappings = [1:(0,8),2:(0,16),4:(2,1),8:(2,8192),16:(1,32)]
        check(five_sides.unverified_modifier_names.isEmpty && five_sides.mapping_status_text.contains("3/3"),
              "an unverified optional right side does not block left-side readiness")
        let left_only = ready()
        left_only.mappings = [1:(0,8),4:(2,1),16:(1,32)]
        check(left_only.unverified_modifier_names.isEmpty && left_only.mapping_status_text.contains("左侧修饰键映射已验证（3/3）"),
              "only the three left modifiers are required")
        left_only.ingest([input(4,1_050_000,25,1|4|16)],gap:false,now:1_051_000)
        let left_flags = cmd|8|CGEventFlags.maskControl.rawValue|1|CGEventFlags.maskAlternate.rawValue|32
        check(left_only.decide(observation(1_055_000,25),now:1_055_000,protected:0)?.flags == left_flags,
              "left Ctrl Win and Alt correct without right-side mappings")
        left_only.ingest([input(5,1_060_000,25,0)],gap:false,now:1_061_000)
        check(left_only.decide(observation(1_065_000,25,left_flags|CGEventFlags.maskShift.rawValue),now:1_065_000,protected:0)?.flags == CGEventFlags.maskShift.rawValue,
              "released left modifiers clear stale flags while preserving Shift")
        left_only.ingest([input(6,1_070_000,25,1|2)],gap:false,now:1_071_000)
        let right_unverified = left_only.decide(observation(1_075_000,25,cmd|16),now:1_075_000,protected:0)
        check(right_unverified?.flags == cmd|16 && right_unverified?.class_mask == 6 && right_unverified?.preserve_mask == 1,
              "an active unverified right Ctrl preserves the entire Command class")
        left_only.ingest([input(7,1_080_000,25,1)],gap:false,now:1_081_000)
        let left_protected = left_only.decide(observation(1_085_000,25),now:1_085_000,protected:1)
        check(left_protected?.flags == 0 && left_protected?.class_mask == 6,
              "left-only mode preserves local Command protection")
        left_only.mappings[2] = (0,16)
        left_only.ingest([input(8,1_090_000,25,2)],gap:false,now:1_091_000)
        check(left_only.decide(observation(1_095_000,25),now:1_095_000,protected:0)?.flags == cmd|16,
              "an optional right-side mapping works when actually verified")
        let pending_left = fresh(); pending_left.mappings = [1:(0,8),4:(2,1)]
        check(pending_left.unverified_modifier_names == ["左Alt"] && pending_left.mapping_status_text.contains("2/3）：左Alt"),
              "pending status lists only required left modifiers")
        let right_only_unknown = ready(); right_only_unknown.mappings = [1:(0,8)]
        right_only_unknown.ingest([input(4,1_050_000,25,2)],gap:false,now:1_051_000)
        let preserved_only = right_only_unknown.decide(observation(1_055_000,25,cmd|16),now:1_055_000,protected:0)
        check(preserved_only?.class_mask == 0 && preserved_only?.preserve_mask == 1 && preserved_only?.flags == cmd|16,
              "preservation still returns when no other class can be corrected")
        let swapped_left = ready(); swapped_left.mappings = [1:(0,16)]
        swapped_left.ingest([input(4,1_050_000,25,1)],gap:false,now:1_051_000)
        check(swapped_left.decide(observation(1_055_000,25),now:1_055_000,protected:0)?.flags == cmd|16,
              "a left Windows key can use its proven right Mac device mapping")
        swapped_left.ingest([input(5,1_060_000,25,0)],gap:false,now:1_061_000)
        check(swapped_left.decide(observation(1_065_000,25,cmd|8|16),now:1_065_000,protected:0)?.flags == 0,
              "a released trusted source clears stale Mac device bits on either side")
        let mapping_json = try JSONSerialization.data(withJSONObject:five_sides.modifier_mapping_diagnostic())
        check(!String(decoding:mapping_json,as:UTF8.self).contains("keycode"),"mapping diagnostics contain only modifier labels and edge states")
        let changed_mapping = ready(); changed_mapping.mappings = m.mappings
        changed_mapping.mapping_edges[1] = (0,8,3)
        var changed_down = observation(1_055_000,0,cmd|16,"modifier","down")
        changed_down.modifier_class = 0; changed_down.side_bit = 16
        changed_mapping.ingest([input(4,1_050_000,224,1,"modifier","down")],gap:false,now:1_050_000)
        _ = changed_mapping.decide(changed_down,now:1_055_000,protected:0)
        check(changed_mapping.mappings[1] == nil,"contradictory physical edge revokes previously verified mapping")
        changed_mapping.ingest([input(5,1_060_000,25,1)],gap:false,now:1_060_000)
        check(changed_mapping.decide(observation(1_065_000,25),now:1_065_000,protected:0) == nil,
              "ordinary key is not corrected using a contradicted mapping")
        var changed_up = observation(1_075_000,0,0,"modifier","up")
        changed_up.modifier_class = 0; changed_up.side_bit = 16
        changed_mapping.ingest([input(6,1_070_000,224,0,"modifier","up")],gap:false,now:1_070_000)
        _ = changed_mapping.decide(changed_up,now:1_075_000,protected:0)
        check(changed_mapping.mappings[1]?.1 == 16,"new mapping requires matching down and up edges")
        let ordering = ready()
        ordering.ingest([input(4,1_040_000,25),input(5,1_050_000)],gap:false,now:1_050_000)
        _ = ordering.pair(observation(1_055_000),now:1_055_000)
        ordering.ingest([input(4,1_040_000,25)],gap:false,now:1_055_000)
        check(ordering.pair(observation(1_045_000,25),now:1_055_000) == nil,"older source event cannot follow consumed newer event")
        let consumed = Set(m.consumed.keys); m.clear()
        check(Set(m.consumed.keys) == consumed,"stream reset retains consumed IDs")
        let resumed = ready(); resumed.mappings[1] = (0,8); resumed.mappings[2] = (0,16)
        resumed.stream_clear(new_generation:true)
        resumed.ingest([input(300,1_050_000,25,1)],gap:false,now:1_050_000)
        check(resumed.ready && resumed.hole_since == nil && resumed.highest_id == 300,
              "new generation starts at retained history without inventing an idle-period gap")
        check(resumed.decide(observation(1_055_000,25),now:1_055_000,protected:0)?.flags == cmd|8,
              "idle resume preserves proven mapping and window")
        resumed.stream_clear(new_generation:true)
        resumed.ingest([input(300,1_050_000,25,1),input(301,1_060_000,25,0)],gap:false,now:1_060_000)
        check(resumed.highest_id == 301 && resumed.hole_since == nil,
              "replayed consumed history does not block new generation watermark")
        let bounded = fresh()
        bounded.ingest((1...600).map { input(UInt64($0),1_000_000+UInt64($0)) },gap:false,now:1_010_000)
        check(bounded.source.count <= 512 && !bounded.continuity,"bounded source cache")
        let reordered = ready()
        reordered.snapshot(time:1_080_000,mods:1,event_seq:6,now:1_081_000)
        check(reordered.ready && reordered.pending_snapshots.count == 1 && reordered.transitions.isEmpty, "snapshot ahead of split event batches waits without proving history")
        reordered.ingest([input(6,1_070_000,25,1)],gap:false,now:1_082_000)
        check(reordered.ready && reordered.hole_since != nil && reordered.pending_snapshots.count == 1,"later event batch preserves learning during reorder grace")
        check(reordered.decide(observation(1_082_000,25),now:1_082_000,protected:0) == nil && reordered.last_decision_reason == "sequence_hole",
              "an unresolved input hole remains a distinct rejection")
        reordered.ingest([input(4,1_050_000,5,1),input(5,1_060_000,6,1)],gap:false,now:1_083_000)
        check(reordered.ready && reordered.highest_id == 6 && reordered.hole_since == nil && reordered.pending_snapshots.isEmpty,"earlier split batch fills watermark and applies pending snapshot")
        check(reordered.transitions.count == 1 && reordered.transitions[0].0 == 1_080_000,"deferred snapshot establishes only its own new interval")
        let missing = ready()
        missing.snapshot(time:1_080_000,mods:1,event_seq:6,now:1_081_000)
        missing.prune(1_181_001)
        check(!missing.ready && missing.highest_id == 6 && missing.transitions.first?.0 == 1_080_000,"snapshot reorder timeout revokes learning and never fills missing past")
        let windows = ready()
        windows.window_clear()
        check(!windows.ready && windows.offset != nil && !windows.consumed.isEmpty, "new window must relearn while clock and consumption survive")
        let gaps = ready()
        gaps.ingest([input(7,1_060_000)], gap:false, now:1_061_000)
        check(gaps.ready && gaps.hole_since != nil, "sequence hole waits for UDP reorder without losing learned window")
        gaps.prune(1_161_001)
        check(!gaps.ready && !gaps.continuity, "persistent sequence hole expires and revokes calibration")
        check(!input(0,1_000_000).valid && !input(1,1_000_000,999,0,"button").valid, "invalid input identity rejected")
        check(!peer_event_time_valid(0,now:1_000_000) && !peer_event_time_valid(1_000_001,now:1_000_000), "zero and future event time rejected")
        check(!peer_event_time_valid(499_999,now:1_000_000) && peer_event_time_valid(500_000,now:1_000_000), "event timestamp age boundary")
        let bridge = RemotePeerBridge(status_notice:{ _ in })
        do { try bridge.configure(peer_ip:"bad",enabled:true); check(false,"invalid IPv4") } catch { check(true,"invalid IPv4 rejected") }
        let event = CGEvent(keyboardEventSource:nil, virtualKey:0, keyDown:true)!
        check(bridge.observe(type:.keyDown,event:event,now_ns:1_000_000_000,protected_mask:0) == nil && bridge.skipped_count == 0, "unconfigured bridge does not inspect or cache keys")
        let summary = bridge.diagnostic_summary()
        check(summary["events"] == nil && summary["key"] == nil,"diagnostics contain no key payload")
        bridge.stop()
        try cold_handshake()
        print("Remote peer offline: \(checks) checks passed")
    }
}
