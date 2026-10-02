import Foundation
import CoreGraphics
import Darwin

@main struct RemotePeerTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(label)") }
    }
    @discardableResult static func wait_until(_ timeout:TimeInterval = 4,_ condition:()->Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            RunLoop.main.run(until:Date().addingTimeInterval(0.005))
        }
    }
    static func bind_loopback(_ fd:Int32,_ port:UInt16) -> Int32 {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
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
        // Keep the clock diagnostic independent of activation publications: with
        // scope still false, this observation cannot enqueue a generation change.
        let activity = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
        activity.timestamp = DispatchTime.now().uptimeNanoseconds
        _ = remote.observe(type:.keyDown,event:activity,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0)
        let decision_summary = remote.diagnostic_summary()
        let decision_counts = decision_summary["keyboard_decisions"] as? [String:UInt64]
        check(decision_counts?["clock_unhealthy"] == 1,"keyboard diagnostics distinguish missing clock evidence")
        let decision_fields = decision_summary["last_keyboard_decision"] as? [String:Any] ?? [:]
        check(Set(decision_fields.keys) == Set(["reason","action","event_ns","callback_ns","protected_mask","corrected_class_mask","before","after"]),
              "keyboard decision diagnostics expose only allowed metadata")
        let window = UUID().uuidString
        var prepare = PeerPacket(kind:"prepare",instance:win,peer:response.instance,epoch:response.epoch,generation:0,seq:4,time_us:peer_now_us())
        prepare.window = window; prepare.scope = true; try send(prepare)
        var stale_hello = PeerPacket(kind:"hello",instance:win,peer:response.instance,epoch:response.epoch,generation:0,seq:2,time_us:peer_now_us())
        stale_hello.window = UUID().uuidString; stale_hello.scope = false; try send(stale_hello)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        activity.timestamp = DispatchTime.now().uptimeNanoseconds
        _ = remote.observe(type:.keyDown,event:activity,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0)
        // Activation and its timer run asynchronously. Wait for the actual first
        // start packet rather than assuming it was emitted within one sleep.
        var start: PeerPacket?
        let start_deadline = peer_now_us()+1_000_000
        while start == nil && peer_now_us() < start_deadline {
            var bytes = [UInt8](repeating:0,count:1201)
            let n = Darwin.recv(fd,&bytes,bytes.count,0)
            if n >= 0 {
                if let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(bytes.prefix(n))), p.kind == "start" { start = p }
            } else {
                RunLoop.main.run(until:Date().addingTimeInterval(0.005))
            }
        }
        check(start?.window == window,"stale same-epoch hello cannot roll foreground scope back (first start window: \(start?.window ?? "missing"))")
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
        let protected_decision = protected.decide(observation(1_055_000,25),now:1_055_000,protected:1)
        check(protected_decision?.flags == 0 && protected_decision?.class_mask == 0 && protected_decision?.preserve_mask == 7 && protected.last_decision_reason == "local_modifier_protected",
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
    static let target_flags = [CGEventFlags.maskCommand.rawValue,CGEventFlags.maskAlternate.rawValue,CGEventFlags.maskControl.rawValue]
    static let target_sides: [[UInt64]] = [[8,16],[32,64],[1,8192]]
    static func mapping_edge(_ matcher:PeerMatcher,_ id:UInt64,_ time:Int64,_ key:Int,_ target:Int,_ side:UInt64,_ down:Bool,
                             mods:UInt16? = nil,flags:UInt64? = nil,observation_time:Int64? = nil) {
        let state = mods ?? (down ? matcher.bit(key) : 0)
        let raw = flags ?? (down ? target_flags[target]|side : 0)
        matcher.ingest([input(id,UInt64(time),key,state,"modifier",down ? "down":"up")],gap:false,now:time)
        var event = observation(observation_time ?? time+5000,0,raw,"modifier",down ? "down":"up")
        event.modifier_class = target; event.side_bit = side
        _ = matcher.decide(event,now:time+5000,protected:0)
    }
    static func timed_mapping_edge(_ matcher:PeerMatcher,_ id:UInt64,_ source_time:Int64,_ observation_time:Int64,_ callback_time:Int64,_ down:Bool) {
        matcher.ingest([input(id,UInt64(source_time),224,down ? 1:0,"modifier",down ? "down":"up")],gap:false,now:callback_time)
        var edge = observation(observation_time,0,down ? target_flags[2]|1:0,"modifier",down ? "down":"up")
        edge.modifier_class = 2; edge.side_bit = 1
        _ = matcher.decide(edge,now:callback_time,protected:0)
    }
    static func mapping_time_evidence() {
        for confirmed in [false,true] {
            let future = ready()
            if confirmed { future.mappings = [1:(0,8),4:(1,32)] }
            timed_mapping_edge(future,4,1_050_000,1_035_000,1_035_000,true)
            check(future.last_pair_reason == "source_from_future" && future.last_consumed_id == 3 && future.consumed[4] == nil && future.delays.count == 3,
                  "far-future modifier down is rejected before consumption or calibration")
            check(future.mapping_edges.isEmpty && future.mappings.count == (confirmed ? 2:0),
                  "far-future down cannot create pending evidence or revoke the confirmed configuration")
            timed_mapping_edge(future,5,1_060_000,1_045_000,1_045_000,false)
            check(future.last_pair_reason == "source_from_future" && future.last_consumed_id == 3 && future.consumed[5] == nil && future.delays.count == 3,
                  "far-future modifier up is rejected before consumption")
            check(future.mapping_edges.isEmpty && future.mappings.count == (confirmed ? 2:0) && (!confirmed || future.mappings[1]?.0 == 0),
                  "a future down-up cycle cannot confirm a mapping or change an existing target")
            let stale = ready()
            if confirmed { stale.mappings = [1:(0,8),4:(1,32)] }
            timed_mapping_edge(stale,4,1_050_000,1_055_000,1_550_001,true)
            check(stale.last_pair_reason == "source_stale" && stale.last_consumed_id == 3 && stale.consumed[4] == nil && stale.delays.count == 3,
                  "modifier down older than 500ms is rejected before consumption")
            check(stale.mapping_edges.isEmpty && stale.mappings.count == (confirmed ? 2:0),
                  "stale down cannot create pending evidence or revoke confirmed mappings")
            timed_mapping_edge(stale,5,1_060_000,1_065_000,1_560_001,false)
            check(stale.last_pair_reason == "source_stale" && stale.last_consumed_id == 3 && stale.consumed[5] == nil && stale.delays.count == 3,
                  "modifier up older than 500ms is rejected before consumption")
            check(stale.mapping_edges.isEmpty && stale.mappings.count == (confirmed ? 2:0) && (!confirmed || stale.mappings[1]?.0 == 0),
                  "a stale down-up cycle cannot confirm or revoke the existing configuration")
        }
        let ahead_boundary = ready()
        timed_mapping_edge(ahead_boundary,4,1_050_000,1_049_500,1_049_500,true)
        check(ahead_boundary.mapping_edges[1]?.2 == 1 && ahead_boundary.consumed[4] != nil,
              "modifier down ahead by exactly half RTT remains reliable evidence")
        timed_mapping_edge(ahead_boundary,5,1_060_000,1_059_500,1_059_500,false)
        check(ahead_boundary.mappings[1]?.0 == 2 && ahead_boundary.mappings[1]?.1 == 1 && ahead_boundary.consumed[5] != nil,
              "modifier down-up at the half RTT boundary can verify an actual target")
        let ahead_beyond = ready()
        timed_mapping_edge(ahead_beyond,4,1_050_000,1_049_499,1_049_499,true)
        check(ahead_beyond.mapping_edges.isEmpty && ahead_beyond.consumed[4] == nil && ahead_beyond.last_consumed_id == 3,
              "modifier down ahead by half RTT plus one microsecond does not consume or learn")
        timed_mapping_edge(ahead_beyond,5,1_060_000,1_059_499,1_059_499,false)
        check(ahead_beyond.mappings.isEmpty && ahead_beyond.mapping_edges.isEmpty && ahead_beyond.consumed[5] == nil,
              "modifier up beyond half RTT cannot finish an untrusted cycle")
        let late_boundary = ready()
        timed_mapping_edge(late_boundary,4,1_050_000,1_055_000,1_550_000,true)
        check(late_boundary.mapping_edges[1]?.2 == 1 && late_boundary.consumed[4] != nil,
              "a reliable modifier observation arriving exactly 500ms late can start a proof")
        timed_mapping_edge(late_boundary,5,1_060_000,1_065_000,1_560_000,false)
        check(late_boundary.mappings[1]?.0 == 2 && late_boundary.consumed[5] != nil,
              "a reliable down-up proof at the 500ms callback boundary remains valid")
        let stale_up = ready()
        timed_mapping_edge(stale_up,4,1_050_000,1_055_000,1_055_000,true)
        timed_mapping_edge(stale_up,5,1_060_000,1_065_000,1_560_001,false)
        check(stale_up.mappings.isEmpty && stale_up.mapping_edges[1]?.2 == 1 && stale_up.consumed[5] == nil,
              "an expired up cannot complete a previously trustworthy down edge")
        let future_up = ready()
        timed_mapping_edge(future_up,4,1_050_000,1_055_000,1_055_000,true)
        timed_mapping_edge(future_up,5,1_060_000,1_059_499,1_059_499,false)
        check(future_up.mappings.isEmpty && future_up.mapping_edges[1]?.2 == 1 && future_up.consumed[5] == nil,
              "a future up cannot complete a previously trustworthy down edge")
    }
    static func dynamic_mappings() {
        let keys = [224,227,226]
        let bits = [1,4,16]
        let shift = CGEventFlags.maskShift.rawValue
        let all_flags = target_flags[0]|target_flags[1]|target_flags[2]|8|16|32|64|1|8192|shift
        // Every three-source assignment is covered, including all six permutations
        // and configurations where several sources converge on one target class.
        for ctrl in 0..<3 { for win in 0..<3 { for alt in 0..<3 {
            let targets = [ctrl,win,alt]
            let matcher = ready()
            for index in 0..<3 {
                let id = UInt64(4+index*2)
                let time = Int64(1_050_000+index*20_000)
                mapping_edge(matcher,id,time,keys[index],targets[index],target_sides[targets[index]][0],true)
                check(matcher.mappings[bits[index]] == nil,"assignment \(targets): down alone remains unverified")
                mapping_edge(matcher,id+1,time+10_000,keys[index],targets[index],target_sides[targets[index]][0],false)
                check(matcher.mappings[bits[index]]?.0 == targets[index] && matcher.mappings[bits[index]]?.1 == target_sides[targets[index]][0],
                      "assignment \(targets): complete physical edge proves actual target")
            }
            var expected = shift
            for target in Set(targets) { expected |= target_flags[target]|target_sides[target][0] }
            matcher.ingest([input(10,1_120_000,25,21)],gap:false,now:1_120_000)
            let corrected = matcher.decide(observation(1_125_000,25,all_flags),now:1_125_000,protected:0)
            check(corrected?.flags == expected && corrected?.class_mask == 7 && corrected?.preserve_mask == 0,
                  "assignment \(targets): active sources OR into targets and unused targets clear")
            matcher.ingest([input(11,1_130_000,25,0)],gap:false,now:1_130_000)
            check(matcher.decide(observation(1_135_000,25,all_flags),now:1_135_000,protected:0)?.flags == shift,
                  "assignment \(targets): release clears every target and preserves Shift")
            for protected in UInt8(1)...UInt8(7) {
                let id = UInt64(11+Int(protected)); let time = Int64(1_140_000+Int(protected)*10_000)
                matcher.ingest([input(id,UInt64(time),25,21)],gap:false,now:time)
                let result = matcher.decide(observation(time+5000,25,all_flags),now:time+5000,protected:protected)
                var protected_expected = expected
                for target in 0..<3 where protected & (1 << target) != 0 {
                    let class_flags = target_flags[target]|target_sides[target][0]|target_sides[target][1]
                    protected_expected = (protected_expected & ~class_flags)|(all_flags & class_flags)
                }
                check(result?.flags == protected_expected && result?.class_mask == (7 & ~protected) && result?.preserve_mask == protected,
                      "assignment \(targets): every local protection combination preserves its exact target bits")
            }
        } } }
        let partial = ready()
        mapping_edge(partial,4,1_050_000,224,2,8192,true)
        mapping_edge(partial,5,1_060_000,224,2,8192,false)
        partial.ingest([input(6,1_070_000,25,1)],gap:false,now:1_070_000)
        let partial_result = partial.decide(observation(1_075_000,25,all_flags),now:1_075_000,protected:0)
        check(partial_result?.flags == ((all_flags & ~(target_flags[2]|1|8192))|target_flags[2]|8192) && partial_result?.class_mask == 4 && partial_result?.preserve_mask == 3,
              "partial source verification rebuilds its actual Control target only")
        for (index,side) in peer_modifier_sides.filter({ $0.bit != 1 }).enumerated() {
            let id = UInt64(7+index); let time = Int64(1_080_000+index*10_000)
            partial.ingest([input(id,UInt64(time),25,UInt16(side.bit))],gap:false,now:time)
            let result = partial.decide(observation(time+5000,25,all_flags),now:time+5000,protected:0)
            check(result?.flags == all_flags && result?.class_mask == 0 && result?.preserve_mask == 7,
                  "unverified active \(side.name) cannot clear any target class")
            check(partial.last_decision_reason == (side.bit & (2|8|32) != 0 ? "unverified_active_right_modifier":"unverified_active_modifier"),
                  "unverified active \(side.name) has the correct source-side diagnostic")
        }
        for (index,side) in peer_modifier_sides.enumerated() {
            let matcher = ready(); let target = index % 3; let target_side = target_sides[target][index % 2]
            let key = [224,228,227,231,226,230][index]
            mapping_edge(matcher,4,1_050_000,key,target,target_side,true)
            mapping_edge(matcher,5,1_060_000,key,target,target_side,false)
            check(matcher.mappings[side.bit]?.0 == target && matcher.mappings[side.bit]?.1 == target_side,
                  "each physical source side can learn a different target class and side")
        }
        let converged = ready()
        mapping_edge(converged,4,1_050_000,224,0,8,true)
        mapping_edge(converged,5,1_060_000,224,0,8,false)
        mapping_edge(converged,6,1_070_000,227,0,16,true)
        mapping_edge(converged,7,1_080_000,227,0,16,false)
        converged.ingest([input(8,1_090_000,25,5)],gap:false,now:1_090_000)
        let both_active = converged.decide(observation(1_095_000,25,shift),now:1_095_000,protected:0)
        check(both_active?.flags == target_flags[0]|8|16|shift && both_active?.class_mask == 1 && both_active?.preserve_mask == 6,
              "two sources converging on one target OR both proven device sides")
        converged.ingest([input(9,1_100_000,25,4)],gap:false,now:1_100_000)
        check(converged.decide(observation(1_105_000,25,target_flags[0]|8|16|shift),now:1_105_000,protected:0)?.flags == target_flags[0]|16|shift,
              "releasing one converged source retains the other source's target side")
        converged.ingest([input(10,1_110_000,25,0)],gap:false,now:1_110_000)
        check(converged.decide(observation(1_115_000,25,target_flags[0]|16|shift),now:1_115_000,protected:0)?.flags == shift,
              "releasing all converged sources clears only their proven target")
        let ambiguous = ready(); ambiguous.mappings[1] = (0,8)
        ambiguous.ingest([input(4,1_050_000,224,1,"modifier","down"),input(5,1_051_000,227,4,"modifier","down")],gap:false,now:1_051_000)
        var ambiguous_event = observation(1_055_000,0,target_flags[0]|8,"modifier","down")
        ambiguous_event.modifier_class = 0; ambiguous_event.side_bit = 8
        _ = ambiguous.decide(ambiguous_event,now:1_055_000,protected:0)
        check(ambiguous.last_pair_reason == "ambiguous_candidates" && ambiguous.mappings.count == 1 && ambiguous.mapping_edges.isEmpty,
              "mixed source modifier candidates stay ambiguous despite an existing mapping")
        let incorrect = ready()
        mapping_edge(incorrect,4,1_050_000,224,0,8,true,mods:0)
        check(incorrect.mappings.isEmpty && incorrect.mapping_edges.isEmpty,"source down without its own pressed bit cannot prove an edge")
        mapping_edge(incorrect,5,1_060_000,224,0,8,false,mods:1)
        check(incorrect.mappings.isEmpty && incorrect.mapping_edges.isEmpty,"source up retaining its own pressed bit cannot prove an edge")
        mapping_edge(incorrect,6,1_070_000,224,0,8,true,flags:target_flags[0]|8|16)
        check(incorrect.mappings.isEmpty && incorrect.mapping_edges.isEmpty,"mixed target device sides cannot prove an isolated raw edge")
        let reversed = ready()
        mapping_edge(reversed,4,1_050_000,224,1,32,false)
        mapping_edge(reversed,5,1_060_000,224,1,32,true)
        check(reversed.mappings.isEmpty,"up followed by down cannot complete a mapping cycle")
        mapping_edge(reversed,6,1_070_000,224,1,32,false)
        check(reversed.mappings[1]?.0 == 1,"a fresh down followed by up proves the mapping after an initial stray up")
        let reversed_time = ready()
        mapping_edge(reversed_time,4,1_050_000,224,0,8,true)
        mapping_edge(reversed_time,5,1_060_000,224,0,8,false,observation_time:1_054_999)
        check(reversed_time.mappings.isEmpty,"increasing source IDs cannot hide decreasing Mac edge times")
        let changed = ready(); changed.mappings = [1:(0,8),4:(2,1),16:(1,32)]
        mapping_edge(changed,4,1_050_000,224,2,1,true)
        check(changed.mappings.isEmpty && Set(changed.mapping_edges.keys) == Set([1]),"a changed target revokes the whole confirmed configuration")
        changed.ingest([input(3,1_040_000,224,0,"modifier","up")],gap:false,now:1_056_000)
        var old_edge = observation(1_045_000,0,0,"modifier","up"); old_edge.modifier_class = 0; old_edge.side_bit = 8
        _ = changed.decide(old_edge,now:1_056_000,protected:0)
        check(changed.mappings.isEmpty,"old source and Mac edges cannot restore a revoked mapping")
        mapping_edge(changed,5,1_060_000,224,2,1,false)
        check(changed.mappings.count == 1 && changed.mappings[1]?.0 == 2,"new configuration requires a complete fresh matching cycle")
        let idle = ready(); idle.mappings[1] = (2,1)
        mapping_edge(idle,4,1_050_000,227,1,32,true)
        idle.stream_clear(new_generation:true)
        check(idle.mappings[1]?.0 == 2 && idle.mapping_edges[4] == nil,"same-window idle retains confirmed mappings but drops partial edges")
        mapping_edge(idle,5,1_060_000,227,1,32,false)
        check(idle.mappings[4] == nil,"generation boundaries cannot combine old down with new up")
        idle.window_clear()
        check(idle.mappings.isEmpty && idle.mapping_edges.isEmpty,"window changes revoke confirmed and partial mapping evidence")
        let gap = ready(); gap.mappings[1] = (2,1)
        gap.ingest([],gap:true,now:1_050_000)
        check(gap.mappings.isEmpty && gap.mapping_edges.isEmpty,"source gaps revoke confirmed and partial mapping evidence")
    }
    static func manual_ready(_ configuration: PeerManualMapping) -> PeerMatcher {
        let m = ready()
        m.configure_mapping(configuration,now:1_040_000)
        for n in 4...6 {
            let time = UInt64(1_010_000+n*10_000)
            m.ingest([input(UInt64(n),time)],gap:false,now:Int64(time))
            _ = m.decide(observation(Int64(time)+5000),now:Int64(time)+5000,protected:0)
        }
        return m
    }
    static func manual_mappings() {
        check(PeerManualMapping(targets:[]) == nil && PeerManualMapping(targets:[0,4]) == nil &&
              PeerManualMapping(targets:[0,4,6]) == nil && PeerManualMapping(targets:[-1,4,2]) == nil,
              "manual configuration rejects malformed target lists")
        let configuration = PeerManualMapping.default_mapping
        let m = manual_ready(configuration)
        check(m.ready && m.unverified_modifier_names.isEmpty && !m.verified_mapping(1),
              "manual configuration enables mapping without claiming observed verification")
        check(m.mapping_status_text.contains("手动") && !m.mapping_status_text.contains("已验证"),
              "manual status distinguishes explicit configuration from learned evidence")
        m.ingest([input(7,1_080_000,25,1)],gap:false,now:1_080_000)
        check(m.decide(observation(1_085_000,25),now:1_085_000,protected:0)?.flags == target_flags[0]|8,
              "manual Ctrl repairs a shortcut without modifier learning")
        m.ingest([input(8,1_090_000,25,1|4)],gap:false,now:1_090_000)
        let held = target_flags[0]|8|target_flags[2]|1
        check(m.decide(observation(1_095_000,25),now:1_095_000,protected:0)?.flags == held,
              "manual simultaneous modifiers remain held")
        m.ingest([input(9,1_100_000,25,0)],gap:false,now:1_100_000)
        check(m.decide(observation(1_105_000,25,held),now:1_105_000,protected:0)?.flags == 0,
              "manual release clears residual modifier flags")
        mapping_edge(m,10,1_110_000,224,0,8,true)
        check(!m.verified_mapping(1),"configured down alone is not verified")
        mapping_edge(m,11,1_120_000,224,0,8,false)
        check(m.verified_mapping(1),"configured reliable down/up records verification")
        mapping_edge(m,12,1_125_000,224,0,8,true)
        check(m.verified_mapping(1),"normal long hold preserves previously observed manual verification")
        m.stream_clear(now:1_127_000)
        check(m.verified_mapping(1),"same-window idle retains observed manual verification")
        m.ingest([],gap:true,now:1_130_000)
        check(m.manual_mapping == configuration && m.mappings.count == 3 && !m.ready && !m.verified_mapping(1),
              "source gap preserves configuration but revokes timing and observed evidence")
        check(m.readiness_status_text.contains("重新同步") && !m.readiness_status_text.contains("0/3"),
              "manual gap status requests input synchronization rather than mapping learning")
        for n in 13...15 {
            let time = UInt64(1_020_000+n*10_000)
            m.ingest([input(UInt64(n),time)],gap:false,now:Int64(time))
            _ = m.decide(observation(Int64(time)+5000),now:Int64(time)+5000,protected:0)
        }
        m.ingest([input(16,1_180_000,25,1)],gap:false,now:1_180_000)
        check(m.decide(observation(1_185_000,25),now:1_185_000,protected:0)?.flags == target_flags[0]|8,
              "ordinary input alone recovers manual repairs after a source gap")
        mapping_edge(m,17,1_190_000,224,2,1,true)
        check(m.manual_mapping_conflict && m.manual_mapping == configuration,
              "reliable contradictory class suspends repairs without overwriting configuration")
        m.ingest([input(18,1_200_000,25,1)],gap:false,now:1_200_000)
        let blocked = m.decide(observation(1_205_000,25,held),now:1_205_000,protected:0)
        check(blocked?.flags == held && blocked?.class_mask == 0 && blocked?.preserve_mask == 7,
              "configuration conflict protects all classes across keyboard and legacy mouse merging")
        m.window_clear(now:1_200_000); m.stream_clear(); m.clear()
        check(m.manual_mapping_conflict && m.manual_mapping == configuration && m.mappings.count == 3,
              "window, idle and service resets never silently dismiss a manual conflict")
        let unpaired = m.decide(observation(1_205_000,25,held,"button"),now:1_205_000,protected:0)
        check(unpaired?.flags == held && unpaired?.preserve_mask == 7,
              "a conflict protects mouse flags even while timing is unavailable")
        m.configure_mapping(configuration,now:1_210_000)
        check(!m.manual_mapping_conflict && !m.ready && m.manual_mapping == configuration,
              "explicit saving clears conflict and requires fresh calibration")
        m.offset = 0; m.rtt = 1000; m.clock_at = 1_200_000
        m.ingest([input(19,1_205_000,25,1)],gap:false,now:1_220_000)
        check(m.decide(observation(1_220_000,25),now:1_220_000,protected:0) == nil && m.delays.isEmpty,
              "delayed pre-configuration source input cannot calibrate new settings")
        check(m.decide(observation(1_209_999,25),now:1_220_000,protected:0) == nil &&
              m.last_decision_reason == "stale_configuration_observation",
              "cached pre-configuration Mac observation is rejected")
        m.configure_mapping(nil,now:1_230_000)
        check(m.manual_mapping == nil && m.mappings.isEmpty && !m.manual_mapping_conflict,
              "switching to automatic revokes manual assumptions")
        let sided = manual_ready(PeerManualMapping(targets:[1,5,3])!)
        sided.ingest([input(7,1_080_000,25,1|4|16)],gap:false,now:1_080_000)
        let right_flags = target_flags[0]|16|target_flags[1]|64|target_flags[2]|8192
        check(sided.decide(observation(1_085_000,25),now:1_085_000,protected:0)?.flags == right_flags,
              "explicit right target sides produce their chosen device flags")
        mapping_edge(sided,8,1_090_000,224,0,8,true)
        check(sided.manual_mapping_conflict,"a reliable wrong target side also blocks manual repairs")
        let optional_right = manual_ready(configuration)
        optional_right.ingest([input(7,1_080_000,25,2)],gap:false,now:1_080_000)
        let unknown = optional_right.decide(observation(1_085_000,25,held),now:1_085_000,protected:0)
        check(unknown?.flags == held && unknown?.preserve_mask == 7,"unlearned right source still protects all target classes")
        mapping_edge(optional_right,8,1_090_000,228,0,16,true)
        mapping_edge(optional_right,9,1_100_000,228,0,16,false)
        check(optional_right.verified_mapping(2) && !optional_right.manual_mapping_conflict,
              "right source mappings can be learned alongside configured left sources")
        // All 27 target-class combinations, including collisions and partial releases.
        for a in 0..<3 { for b in 0..<3 { for c in 0..<3 {
            let targets = [a*2,b*2,c*2]
            let configured = PeerManualMapping(targets:targets)!
            let combined = manual_ready(configured)
            for state in 0..<8 {
                let mods = UInt16((state & 1) | ((state & 2) << 1) | ((state & 4) << 2))
                let time = UInt64(1_080_000+state*10_000)
                let shift = CGEventFlags.maskShift.rawValue
                combined.ingest([input(UInt64(7+state),time,25,mods)],gap:false,now:Int64(time))
                var expected = shift
                for (bit,mapping) in configured.mappings where mods & UInt16(bit) != 0 {
                    expected |= target_flags[mapping.0]|mapping.1
                }
                check(combined.decide(observation(Int64(time)+5000,25,shift),now:Int64(time)+5000,protected:0)?.flags == expected,
                      "manual target combination \(targets) active state \(state) preserves OR and Shift")
            }
        } } }
        for protection: UInt8 in 0...7 {
            let protected = manual_ready(configuration)
            protected.ingest([input(7,1_080_000,25,1|4|16)],gap:false,now:1_080_000)
            let decision = protected.decide(observation(1_085_000,25),now:1_085_000,protected:protection)
            check(decision?.class_mask == 7 & ~protection && decision?.preserve_mask == protection,
                  "manual mappings honor local-source protection mask \(protection)")
        }
    }
    static func transport_diagnostics() throws {
        var metadata = PeerTransportDiagnostics()
        metadata.sent(result:-1,error:EACCES)
        check(metadata.send_error_active && metadata.last_send_errno == EACCES,"send failure preserves immediate errno")
        check(metadata.status_text?.contains("系统拒绝") == true,"permission errno receives actionable status")
        metadata.sent(result:-1,error:EHOSTUNREACH)
        check(metadata.status_text?.contains("网络不可达") == true,"network failure is distinct from permissions")
        metadata.sent(result:199,error:0)
        check(!metadata.error_active && metadata.last_send_errno == EHOSTUNREACH && metadata.send_successes == 1,"successful retry clears active error but retains history")
        for code in [EAGAIN,EWOULDBLOCK,EINTR] { metadata.sent(result:-1,error:code) }
        check(!metadata.send_error_active && metadata.send_successes == 1 && metadata.counters["send_error"] == 2,"temporary send interruption neither fails transport nor counts as success")
        metadata.received(result:-1,error:EAGAIN)
        metadata.received(result:-1,error:EWOULDBLOCK)
        metadata.received(result:-1,error:EINTR)
        check(metadata.counters["receive_error"] == nil,"nonblocking drain and interruption do not count as failures")
        metadata.received(result:-1,error:EACCES)
        check(metadata.receive_error_active && metadata.last_receive_errno == EACCES,"receive failure records errno")
        metadata.received(result:199,error:0)
        check(!metadata.receive_error_active && metadata.received_datagrams == 1,"received datagram restores receive health")
        metadata.opened(error:EADDRINUSE)
        check(metadata.socket_error_active && metadata.last_socket_errno == EADDRINUSE && metadata.status_text?.contains("端口被占用") == true,"socket open failure preserves errno and status")
        metadata.opened(error:0)
        check(!metadata.socket_error_active && metadata.last_socket_errno == EADDRINUSE,"opening socket clears active failure and retains history")
        for reason in PeerTransportReason.allCases { metadata.reject(reason) }
        check(Set(metadata.counters.keys) == Set(PeerTransportReason.allCases.map(\.rawValue)),"transport counter keys have a fixed whitelist")
        check(Set(metadata.summary.keys) == Set(["counters","last_send_errno","last_receive_errno","last_socket_errno","socket_error_active","send_error_active","receive_error_active","send_successes","received_datagrams"]),"transport exports only bounded metadata")
        let encoded = String(data:try JSONSerialization.data(withJSONObject:metadata.summary),encoding:.utf8)!
        check(!encoded.contains("127.0.0.1") && !encoded.contains("events") && !encoded.contains("keycode"),"transport metadata does not export addresses or input identifiers")

        final class SenderState {
            let lock = NSLock()
            var fail = true
            var attempts = 0
            func transmit(_ fd:Int32,_ data:Data,_ address:sockaddr_in)->(result:Int,error:Int32) {
                lock.lock(); attempts += 1; let blocked = fail; lock.unlock()
                return blocked ? (-1,EHOSTUNREACH) : peer_send_datagram(fd,data,address)
            }
            func recover() { lock.lock(); fail = false; lock.unlock() }
            func break_network() { lock.lock(); fail = true; lock.unlock() }
            var count:Int { lock.lock(); defer { lock.unlock() }; return attempts }
        }
        let state = SenderState()
        let fd = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        check(fd >= 0,"transport test loopback socket")
        defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(49004).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(bound == 0,"transport test loopback port bound")
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        let remote = RemotePeerBridge(status_notice:{ _ in },local_port:49003,peer_port:49004,datagram_sender:state.transmit)
        defer { remote.stop(); RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        try remote.configure(peer_ip:"127.0.0.1",enabled:true)
        check(wait_until { remote.status_text.contains("网络不可达") },"injected hello send error reaches main status")
        remote.configure_mapping(.default_mapping)
        check(remote.status_text.contains("网络不可达"),"manual mapping cannot conceal transport error")
        let first_attempts = state.count
        check(wait_until { state.count > first_attempts },"failed hello retries after socket rebuild")
        state.recover()
        check(wait_until { remote.status_text == "等待 Windows 连接" },"successful send alone does not claim acknowledgement")
        remote.configure_mapping(.default_mapping)
        check(remote.status_text == "等待 Windows 连接","manual configuration preserves waiting handshake state")
        var destination = address; destination.sin_port = UInt16(49003).bigEndian
        func send_bytes(_ data:Data) { _ = peer_send_datagram(fd,data,destination) }
        func send_packet(_ packet:PeerPacket) throws { send_bytes(try JSONEncoder().encode(packet)) }
        let win = UUID().uuidString
        try send_packet(PeerPacket(kind:"hello",instance:win,peer:"",epoch:"",generation:0,seq:1,time_us:peer_now_us()))
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        var hello:PeerPacket?
        for _ in 0..<32 {
            var buffer = [UInt8](repeating:0,count:1201)
            let n = Darwin.recv(fd,&buffer,buffer.count,0)
            if n < 0 { break }
            if let p = try? JSONDecoder().decode(PeerPacket.self,from:Data(buffer.prefix(n))), p.kind == "hello", p.peer == win { hello = p }
        }
        check(hello != nil,"recovered sender emits targeted hello")
        guard let hello = hello else { return }
        try send_packet(PeerPacket(kind:"heartbeat",instance:win,peer:hello.instance,epoch:hello.epoch,generation:0,seq:2,time_us:peer_now_us()))
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(remote.diagnostic_summary()["connected"] as? Bool == false,"non-acknowledgement packet cannot complete handshake")
        let ack = PeerPacket(kind:"hello",instance:win,peer:hello.instance,epoch:hello.epoch,generation:0,seq:3,time_us:peer_now_us())
        try send_packet(ack)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        check(remote.status_text == "已连接，等待 UU 输入" && remote.diagnostic_summary()["connected"] as? Bool == true,"real hello acknowledgement restores connection")
        send_bytes(Data("not-json".utf8))
        try send_packet(PeerPacket(kind:"hello",instance:win,peer:UUID().uuidString,epoch:hello.epoch,generation:0,seq:3,time_us:peer_now_us()))
        try send_packet(ack)
        RunLoop.main.run(until:Date().addingTimeInterval(1.1))
        let snapshot = remote.diagnostic_summary()["transport"] as? [String:Any] ?? [:]
        let counters = snapshot["counters"] as? [String:UInt64] ?? [:]
        check(counters["rejected_header"] == 1 && counters["rejected_session"] == 1 && counters["rejected_duplicate"] == 1 && counters["rejected_acknowledgement"] == 1,"receiver reports header session and duplicate rejection without payload")
        check(counters["send_error",default:0] >= 2 && snapshot["send_error_active"] as? Bool == false,"diagnostic retains failed retries after recovery")
        remote.configure_keypad_plus(enabled:true)
        // Populate a real source cache before losing the transport.
        let window = UUID().uuidString
        var prepare = PeerPacket(kind:"prepare",instance:win,peer:hello.instance,epoch:hello.epoch,generation:0,seq:4,time_us:peer_now_us())
        prepare.window = window; prepare.scope = true; try send_packet(prepare)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        let activity = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
        activity.timestamp = DispatchTime.now().uptimeNanoseconds
        _ = remote.observe(type:.keyDown,event:activity,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0)
        func receive_packet(_ accepts:(PeerPacket)->Bool) -> PeerPacket? {
            var buffer = [UInt8](repeating:0,count:1201)
            while true {
                let n = Darwin.recv(fd,&buffer,buffer.count,0)
                if n < 0 { return nil }
                if let packet = try? JSONDecoder().decode(PeerPacket.self,from:Data(buffer.prefix(n))), accepts(packet) { return packet }
            }
        }
        var start:PeerPacket?
        check(wait_until { start = receive_packet { $0.kind == "start" }; return start != nil },"source stream starts before recovery test")
        var old_events = PeerPacket(kind:"events",instance:win,peer:hello.instance,epoch:hello.epoch,generation:start!.generation,seq:5,time_us:peer_now_us())
        old_events.window = window; old_events.events = [input(1,old_events.time_us,4,0,"key","down",window)]
        try send_packet(old_events)
        check(wait_until { remote.diagnostic_summary()["source_cache_count"] as? Int == 1 },"real source evidence cached before transport failure")
        state.break_network()
        check(wait_until {
            let recovery = remote.diagnostic_summary()["recovery"] as? [String:Any] ?? [:]
            return recovery["pending"] as? Bool == true && remote.diagnostic_summary()["connected"] as? Bool == false
        },"connected transport failure revokes acknowledgement")
        check(remote.diagnostic_summary()["source_cache_count"] as? Int == 0 && remote.diagnostic_summary()["observation_cache_count"] as? Int == 0,"recovery clears both source and observation evidence")
        activity.timestamp = DispatchTime.now().uptimeNanoseconds
        check(remote.observe(type:.keyDown,event:activity,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0) == nil,"disconnected recovery cannot correct an input event")
        let probe = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        check(probe >= 0,"recovery socket release probe")
        check(wait_until(0.5) { bind_loopback(probe,49003) == 0 },"failed socket is released before backoff expires")
        Darwin.close(probe)
        state.recover()
        var recovered_hello:PeerPacket?
        check(wait_until {
            recovered_hello = receive_packet { $0.kind == "hello" && $0.peer == win && $0.epoch != hello.epoch }
            return recovered_hello != nil
        },"rebuild offers a new epoch to the same Windows instance")
        let new_hello = recovered_hello!
        check(remote.diagnostic_summary()["connected"] as? Bool == false,"new epoch still requires actual ACK")
        try send_packet(old_events)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(remote.diagnostic_summary()["source_cache_count"] as? Int == 0,"old epoch cannot refill evidence during recovery")
        try send_packet(PeerPacket(kind:"hello",instance:win,peer:new_hello.instance,epoch:new_hello.epoch,generation:0,seq:6,time_us:peer_now_us()))
        check(wait_until { remote.diagnostic_summary()["connected"] as? Bool == true },"same Windows instance ACK reconnects new epoch")
        check((remote.diagnostic_summary()["recovery"] as? [String:Any])?["delay_us"] as? UInt64 == 0,"ACK resets retry backoff")
        check(remote.manual_mapping == .default_mapping && remote.diagnostic_summary()["mapping_mode"] as? String == "manual" && remote.keypad_plus_enabled,"recovery retains manual mapping and keypad preference")
        try send_packet(old_events)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        check(remote.diagnostic_summary()["source_cache_count"] as? Int == 0,"old epoch remains rejected after ACK")
        check(wait_until(4) {
            (remote.diagnostic_summary()["recovery"] as? [String:Any])?["pending"] as? Bool == true
        },"peer silence triggers socket recovery after timeout")
        try remote.configure(peer_ip:"127.0.0.1",enabled:false)
        RunLoop.main.run(until:Date().addingTimeInterval(1.2))
        check(remote.status_text == "辅助同步已暂停","pause cancels pending timeout recovery")
        let paused_probe = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        check(bind_loopback(paused_probe,49003) == 0,"paused recovery does not reclaim listener port")
        Darwin.close(paused_probe)
        let reset = remote.diagnostic_summary()["transport"] as? [String:Any] ?? [:]
        check((reset["counters"] as? [String:UInt64])?.isEmpty == true && remote.diagnostic_summary()["connected"] as? Bool == false,"new configuration resets transport and connected cache")
        let stale = RemotePeerBridge(status_notice:{ _ in },local_port:49005,peer_port:49006,datagram_sender:{ _,_,_ in (-1,EHOSTUNREACH) })
        defer { stale.stop(); RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        try stale.configure(peer_ip:"127.0.0.1",enabled:true)
        // Let the network queue publish an error without draining its main batch.
        Thread.sleep(forTimeInterval:0.1)
        try stale.configure(peer_ip:"127.0.0.1",enabled:false)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        let stale_summary = stale.diagnostic_summary()["transport"] as? [String:Any] ?? [:]
        check(stale.status_text == "辅助同步已暂停" && stale_summary["send_error_active"] as? Bool == false,"obsolete configuration error publication cannot revive paused connection")
    }
    static func startup_recovery() throws {
        final class TransientSender {
            var attempts = 0
            func send(_ fd:Int32,_ data:Data,_ address:sockaddr_in)->(result:Int,error:Int32) {
                attempts += 1
                return attempts == 1 ? (-1,EAGAIN) : peer_send_datagram(fd,data,address)
            }
        }
        let transient_state = TransientSender()
        let transient = RemotePeerBridge(status_notice:{ _ in },local_port:49013,peer_port:49014,datagram_sender:transient_state.send)
        try transient.configure(peer_ip:"127.0.0.1",enabled:true)
        check(wait_until {
            (transient.diagnostic_summary()["transport"] as? [String:Any])?["send_successes"] as? UInt64 ?? 0 > 0
        },"temporary send failure retries normally")
        let transient_summary = transient.diagnostic_summary()
        check((transient_summary["recovery"] as? [String:Any])?["attempts"] as? UInt64 == 0
              && (transient_summary["transport"] as? [String:Any])?["send_error_active"] as? Bool == false,
              "temporary send failure preserves socket without transport backoff")
        transient.stop()
        let occupied = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        check(occupied >= 0 && bind_loopback(occupied,49007) == 0,"startup test occupies listener port")
        let remote = RemotePeerBridge(status_notice:{ _ in },local_port:49007,peer_port:49008)
        defer { remote.stop() }
        try remote.configure(peer_ip:"127.0.0.1",enabled:true)
        check(wait_until {
            (remote.diagnostic_summary()["transport"] as? [String:Any])?["socket_error_active"] as? Bool == true
        },"bind conflict is reported without aborting configuration")
        Darwin.close(occupied)
        check(wait_until { remote.status_text == "等待 Windows 连接" },"released bind conflict automatically reopens socket")
        check(remote.diagnostic_summary()["connected"] as? Bool == false,"reopened socket alone cannot acknowledge peer")
        remote.stop()
        let stopped = RemotePeerBridge(status_notice:{ _ in },local_port:49009,peer_port:49010,datagram_sender:{ _,_,_ in (-1,EHOSTUNREACH) })
        try stopped.configure(peer_ip:"127.0.0.1",enabled:true)
        check(wait_until { (stopped.diagnostic_summary()["recovery"] as? [String:Any])?["pending"] as? Bool == true },"stop test has pending backoff")
        stopped.stop()
        let status = stopped.status_text
        RunLoop.main.run(until:Date().addingTimeInterval(1.2))
        let probe = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        defer { Darwin.close(probe) }
        check(bind_loopback(probe,49009) == 0 && stopped.status_text == status,"stop cancels delayed recovery and leaves listener free")
        final class StopFaultSender {
            let lock = NSLock()
            var failed_stops = 0
            func send(_ fd:Int32,_ data:Data,_ address:sockaddr_in)->(result:Int,error:Int32) {
                if (try? JSONDecoder().decode(PeerPacket.self,from:data))?.kind == "stop" {
                    lock.lock(); failed_stops += 1; lock.unlock(); return (-1,EHOSTUNREACH)
                }
                return peer_send_datagram(fd,data,address)
            }
            var failures:Int { lock.lock(); defer { lock.unlock() }; return failed_stops }
        }
        let stop_peer = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        check(stop_peer >= 0 && bind_loopback(stop_peer,49012) == 0,"final stop test peer bound")
        defer { Darwin.close(stop_peer) }
        _ = fcntl(stop_peer,F_SETFL,O_NONBLOCK)
        var stop_destination = sockaddr_in(); stop_destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        stop_destination.sin_family = sa_family_t(AF_INET); stop_destination.sin_port = UInt16(49011).bigEndian
        stop_destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        let stop_state = StopFaultSender()
        let stopping = RemotePeerBridge(status_notice:{ _ in },local_port:49011,peer_port:49012,datagram_sender:stop_state.send)
        try stopping.configure(peer_ip:"127.0.0.1",enabled:true)
        check(wait_until { (stopping.diagnostic_summary()["transport"] as? [String:Any])?["send_successes"] as? UInt64 ?? 0 > 0 },"shutdown fault test begins with healthy transport")
        let stop_win = UUID().uuidString; let stop_window = UUID().uuidString
        func send_stop_peer(_ packet:PeerPacket) throws {
            _ = peer_send_datagram(stop_peer,try JSONEncoder().encode(packet),stop_destination)
        }
        func receive_stop_peer(_ accepts:(PeerPacket)->Bool) -> PeerPacket? {
            var buffer = [UInt8](repeating:0,count:1201)
            while true {
                let n = Darwin.recv(stop_peer,&buffer,buffer.count,0)
                if n < 0 { return nil }
                if let packet = try? JSONDecoder().decode(PeerPacket.self,from:Data(buffer.prefix(n))), accepts(packet) { return packet }
            }
        }
        try send_stop_peer(PeerPacket(kind:"hello",instance:stop_win,peer:"",epoch:"",generation:0,seq:1,time_us:peer_now_us()))
        var stop_hello:PeerPacket?
        check(wait_until { stop_hello = receive_stop_peer { $0.kind == "hello" && $0.peer == stop_win }; return stop_hello != nil },"final stop test receives targeted handshake")
        var stop_ack = PeerPacket(kind:"hello",instance:stop_win,peer:stop_hello!.instance,epoch:stop_hello!.epoch,generation:0,seq:2,time_us:peer_now_us())
        stop_ack.scope = true; stop_ack.window = stop_window
        try send_stop_peer(stop_ack)
        check(wait_until { stopping.diagnostic_summary()["connected"] as? Bool == true },"final stop test acknowledges peer")
        let event = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        _ = stopping.observe(type:.keyDown,event:event,now_ns:DispatchTime.now().uptimeNanoseconds,protected_mask:0)
        var stop_start:PeerPacket?
        check(wait_until { stop_start = receive_stop_peer { $0.kind == "start" }; return stop_start != nil },"final stop test activates stream")
        stopping.stop()
        check(stop_state.failures == 1,"final stop send actually encounters injected failure")
        RunLoop.main.run(until:Date().addingTimeInterval(1.2))
        let stop_probe = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        defer { Darwin.close(stop_probe) }
        check(bind_loopback(stop_probe,49011) == 0,"failure sending final stop cannot revive closed transport")
    }
    static func keypad_plus() {
        func calibrated(enabled: Bool = true) -> PeerMatcher {
            let m = fresh()
            m.configure_keypad_plus(enabled:enabled,now:1)
            for n in 1...3 {
                let time = UInt64(1_000_000+n*10_000)
                m.ingest([input(UInt64(n),time)],gap:false,now:Int64(time))
                _ = m.decide(observation(Int64(time)+5000),now:Int64(time)+5000,protected:0)
            }
            return m
        }
        func plus_observation(_ key: Int = 46, flags: UInt64 = 0, action: String = "down") -> PeerObservation {
            var o = observation(1_055_000,key,flags,"key",action)
            o.keypad_plus_alias = true
            return o
        }
        check(!fresh().keypad_plus_enabled,"keypad plus opt-in defaults disabled")
        for key in [46,87,103] {
            let m = calibrated()
            m.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
            let d = m.decide(plus_observation(key),now:1_055_000,protected:0)
            check(d?.keypad_plus_text == true && d?.flags == 0 && d?.class_mask == 0,
                  "verified current keypad plus corrects each allowed observed physical position without requiring modifier mappings")
            check(m.last_decision_reason == "keypad_plus_text_corrected","keypad repair has fixed diagnostic reason")
        }
        for mapping_enabled in [false,true] {
            let m = calibrated()
            if mapping_enabled { m.mappings = PeerManualMapping.default_mapping.mappings }
            let prior_corrected = m.corrected; let prior_skipped = m.skipped
            m.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
            let d = m.decide(plus_observation(),now:1_055_000,protected:0)
            check(d?.keypad_plus_text == true && d?.flags == 0 && m.corrected == prior_corrected+1 && m.skipped == prior_skipped,
                  "text-only repair counts as corrected without skipping, with or without modifier mappings")
            check(m.decide(plus_observation(),now:1_056_000,protected:0) == nil && m.corrected == prior_corrected+1,
                  "consumed keypad input cannot count as a second correction")
        }
        let combined = calibrated(); combined.mappings = PeerManualMapping.default_mapping.mappings
        let combined_corrected = combined.corrected; let combined_skipped = combined.skipped
        combined.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
        let combined_decision = combined.decide(plus_observation(flags:8),now:1_055_000,protected:0)
        check(combined_decision?.keypad_plus_text == true && combined_decision?.flags == 0 &&
              combined.corrected == combined_corrected+1 && combined.skipped == combined_skipped,
              "device flag plus text correction counts the same event exactly once")
        for key in [46,87,103] {
            let m = calibrated(enabled:false)
            m.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
            check(m.decide(plus_observation(key),now:1_055_000,protected:0)?.keypad_plus_text != true,
                  "disabled feature does not rewrite plus or equals")
        }
        for key in [46,103] {
            let m = calibrated()
            m.ingest([input(4,1_050_000,key)],gap:false,now:1_050_000)
            check(m.decide(plus_observation(key),now:1_055_000,protected:0)?.keypad_plus_text == false,
                  "ordinary equals and true keypad equals retain their exact source identity")
            let ambiguous = calibrated()
            ambiguous.ingest([input(4,1_050_000,key),input(5,1_050_100,87)],gap:false,now:1_050_100)
            check(ambiguous.decide(plus_observation(key),now:1_055_000,protected:0) == nil && ambiguous.last_decision_reason == "ambiguous_candidates",
                  "exact equals and keypad alias candidates remain ambiguous together")
        }
        let disallowed = calibrated()
        disallowed.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
        check(disallowed.decide(plus_observation(4),now:1_055_000,protected:0) == nil,"alias cannot match other physical input")
        let not_alias = calibrated()
        not_alias.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
        check(not_alias.decide(observation(1_055_000,46),now:1_055_000,protected:0) == nil,"alias requires explicit observation eligibility")
        for mods: UInt16 in [1,2,4,8,16,32] {
            let m = calibrated()
            m.mappings = PeerManualMapping.default_mapping.mappings
            m.ingest([input(4,1_050_000,87,mods)],gap:false,now:1_050_000)
            check(m.decide(plus_observation(),now:1_055_000,protected:0)?.keypad_plus_text != true,
                  "all left and right remote shortcut modifiers prevent text rewrite")
        }
        for flag in [CGEventFlags.maskCommand,CGEventFlags.maskAlternate,CGEventFlags.maskControl] {
            let m = calibrated()
            m.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
            check(m.decide(plus_observation(flags:flag.rawValue),now:1_055_000,protected:0)?.keypad_plus_text != true,
                  "local aggregate modifier prevents text rewrite even if flags correction is available")
        }
        for protection: UInt8 in [1,2,4,7] {
            let m = calibrated()
            m.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
            check(m.decide(plus_observation(),now:1_055_000,protected:protection)?.keypad_plus_text != true,
                  "local modifier protection prevents plus rewrite")
        }
        let shifted = calibrated()
        shifted.ingest([input(4,1_050_000,87,64),input(5,1_060_000,87,64)],gap:false,now:1_060_000)
        check(shifted.decide(plus_observation(flags:CGEventFlags.maskShift.rawValue),now:1_055_000,protected:0) == nil,
              "repeat candidates still require unique matching")
        let repeats = calibrated()
        for n in 4...5 {
            let t = UInt64(1_050_000+(n-4)*40_000)
            repeats.ingest([input(UInt64(n),t,87,64)],gap:false,now:Int64(t))
            var o = plus_observation(flags:CGEventFlags.maskShift.rawValue); o.time = Int64(t)+5000
            let d = repeats.decide(o,now:o.time,protected:0)
            check(d?.keypad_plus_text == true && d?.flags == CGEventFlags.maskShift.rawValue,"Shift and repeated down are supported without changing flags")
        }
        let up = calibrated()
        up.ingest([input(4,1_050_000,87,0,"key","up")],gap:false,now:1_050_000)
        check(up.decide(plus_observation(action:"up"),now:1_055_000,protected:0)?.keypad_plus_text == false,"key up remains unchanged")
        let learning = fresh(); learning.configure_keypad_plus(enabled:true,now:1)
        learning.ingest([input(1,1_050_000,87)],gap:false,now:1_050_000)
        check(learning.decide(plus_observation(),now:1_055_000,protected:0) == nil,"uncalibrated window does not repair plus")
        let stale = calibrated(); stale.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
        check(stale.decide(plus_observation(),now:1_550_001,protected:0) == nil && stale.last_decision_reason == "source_stale","stale source does not rewrite plus")
        let future = calibrated(); future.ingest([input(4,1_055_501,87)],gap:false,now:1_055_000)
        check(future.decide(plus_observation(),now:1_055_000,protected:0) == nil && future.last_decision_reason == "source_from_future","future source beyond clock uncertainty does not rewrite plus")
        let unhealthy = calibrated(); unhealthy.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000); unhealthy.offset = nil
        check(unhealthy.decide(plus_observation(),now:1_055_000,protected:0) == nil,"unhealthy clock cannot repair plus")
        let hole = calibrated(); hole.ingest([input(5,1_050_000,87)],gap:false,now:1_050_000)
        check(hole.decide(plus_observation(),now:1_055_000,protected:0) == nil && hole.last_decision_reason == "sequence_hole","sequence hole prevents plus repair")
        let gap = calibrated(); gap.ingest([input(4,1_050_000,87)],gap:true,now:1_050_000)
        check(gap.decide(plus_observation(),now:1_055_000,protected:0)?.keypad_plus_text != true,"source gap revokes plus calibration")
        let late = calibrated()
        check(late.decide(plus_observation(),now:1_055_000,protected:0) == nil,"missing plus source is not synthesized")
        late.ingest([input(4,1_050_000,87)],gap:false,now:1_060_000)
        check(late.late_keyboard_calibrations == 1 && late.observations.isEmpty,"late plus source is only calibration and cannot rewrite an already delivered event")
        let conflict = calibrated()
        conflict.configure_mapping(.default_mapping,now:1_040_000)
        mapping_edge(conflict,4,1_050_000,224,2,1,true)
        check(conflict.manual_mapping_conflict,"configured contradiction locks keypad repair too")
        conflict.configure_keypad_plus(enabled:false,now:1_060_000)
        conflict.configure_keypad_plus(enabled:true,now:1_070_000)
        check(conflict.manual_mapping_conflict && conflict.manual_mapping == .default_mapping,"keypad option cannot clear a manual conflict or mapping setting")
        // Establish calibration without changing the conflict latch.
        conflict.learned_window = "window"; conflict.delays = [5000,5000,5000]
        conflict.ingest([input(5,1_080_000,87)],gap:false,now:1_080_000)
        var conflict_o = plus_observation(); conflict_o.time = 1_085_000
        check(conflict.decide(conflict_o,now:1_085_000,protected:0)?.keypad_plus_text == false,"manual conflict blocks otherwise matched keypad repair")
        let switched = calibrated()
        switched.ingest([input(4,1_050_000,87)],gap:false,now:1_050_000)
        switched.observations = [plus_observation()]
        switched.configure_keypad_plus(enabled:false,now:1_060_000)
        check(!switched.ready && switched.source.isEmpty && switched.observations.isEmpty && switched.offset == 0 && switched.last_consumed_id == 4,
              "option change clears calibration and pending input while retaining network clock and consumption watermark")
        switched.configure_keypad_plus(enabled:true,now:1_070_000)
        switched.learned_window = "window"; switched.delays = [5000,5000,5000]
        switched.ingest([input(5,1_050_000,87)],gap:false,now:1_075_000)
        check(switched.decide(plus_observation(),now:1_075_000,protected:0) == nil && switched.last_decision_reason == "stale_configuration_observation",
              "pre-option observation cannot cross the configuration boundary")
        var fresh_o = plus_observation(); fresh_o.time = 1_075_000
        check(switched.decide(fresh_o,now:1_075_000,protected:0) == nil,"old source cannot match a new observation after toggling")
        let unchanged = calibrated(); unchanged.configure_keypad_plus(enabled:true,now:1_060_000)
        check(unchanged.ready,"unchanged option does not unnecessarily relearn")
        let bridge = RemotePeerBridge(status_notice:{ _ in })
        bridge.configure_keypad_plus(enabled:true)
        check(bridge.keypad_plus_enabled && bridge.diagnostic_summary()["keypad_plus_enabled"] as? Bool == true && bridge.status_text == "辅助同步未配置",
              "bridge exposes option metadata without pretending a connection or exporting input content")
        bridge.stop()
    }
    static func main() throws {
        try transport_diagnostics()
        try startup_recovery()
        keypad_plus()
        manual_mappings()
        mapping_time_evidence()
        dynamic_mappings()
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
        let foreign_protected = m.decide(observation(1_075_000,25,cmd),now:1_075_000,protected:1)
        check(foreign_protected?.flags == cmd && foreign_protected?.class_mask == 0 && foreign_protected?.preserve_mask == 7,"foreign class protection")
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
            let forwarded = late.decide(observation(time+5000),now:time+5000,protected:0)
            check(forwarded == nil || (forwarded?.flags == 0 && forwarded?.class_mask == 0 && forwarded?.preserve_mask == 7),"forwarded observation unchanged")
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
        check(motion.mappings.isEmpty && !motion.ready && motion.readiness_status_text.contains("重新学习"),
              "gap revokes modifier mapping and reports relearning")
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
        check(right_unverified?.flags == cmd|16 && right_unverified?.class_mask == 0 && right_unverified?.preserve_mask == 7,
              "an active unverified right Ctrl preserves all target classes")
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
        check(preserved_only?.class_mask == 0 && preserved_only?.preserve_mask == 7 && preserved_only?.flags == cmd|16,
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
        let contradicted = changed_mapping.decide(observation(1_065_000,25),now:1_065_000,protected:0)
        check(contradicted?.flags == 0 && contradicted?.class_mask == 0 && contradicted?.preserve_mask == 7,
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
