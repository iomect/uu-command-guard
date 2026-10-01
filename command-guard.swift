import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Carbon
import Darwin

let guard_version = "2026-10-01.13"
let detailed_keyboard_diagnostics = CommandLine.arguments.contains("--diagnostic-session")
let recovery_interval: UInt64 = 300_000_000
let log_retention_seconds: TimeInterval = 3600

struct ModifierSpec {
    let name: String
    let left_key: Int64
    let right_key: Int64
    let aggregate: UInt64
    let device_bits: UInt64
    var all_bits: UInt64 { aggregate | device_bits }
}
// Device masks from IOKit/hidsystem/IOLLEvent.h.
let modifier_specs: [ModifierSpec] = [
    ModifierSpec(name: "Command", left_key: 55, right_key: 54, aggregate: CGEventFlags.maskCommand.rawValue, device_bits: 0x08 | 0x10),
    ModifierSpec(name: "Option", left_key: 58, right_key: 61, aggregate: CGEventFlags.maskAlternate.rawValue, device_bits: 0x20 | 0x40),
    ModifierSpec(name: "Ctrl", left_key: 59, right_key: 62, aggregate: CGEventFlags.maskControl.rawValue, device_bits: 0x01 | 0x2000)
]
let watched_bits = modifier_specs.reduce(UInt64(0)) { $0 | $1.all_bits }
let mouse_types: Set<CGEventType> = [.leftMouseDown, .leftMouseUp,
    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
let keyboard_types: Set<CGEventType> = [.keyDown, .keyUp]
let monitored_event_types = mouse_types.union(keyboard_types).union([.flagsChanged])

struct SourceState {
    var down: Bool? = nil
    var timestamp: UInt64 = 0

    mutating func observe(down: Bool, timestamp: UInt64) -> Bool {
        // Zero has no ordering information; equal timestamps use delivery order.
        if timestamp != 0 && self.timestamp != 0 && timestamp < self.timestamp { return false }
        self.down = down
        self.timestamp = timestamp
        return true
    }
}

struct ModifierState {
    var uu = SourceState()
    var foreign: [Int64: SourceState] = [:]
    var needs_sync = true
    var clear_since: UInt64? = nil
    var foreign_held: Bool { foreign.values.contains { $0.down == true } }
}

struct SystemSnapshot {
    var hid_flags: UInt64 = 0
    var session_flags: UInt64 = 0
    // Bit i represents either side of modifier_specs[i] being held.
    var hid_keys: UInt64 = 0
    var session_keys: UInt64 = 0

    func released(_ index: Int) -> Bool {
        return ((hid_flags | session_flags) & modifier_specs[index].all_bits) == 0
            && ((hid_keys | session_keys) & (UInt64(1) << index)) == 0
    }
}

struct GuardState {
    var modifiers = Array(repeating: ModifierState(), count: modifier_specs.count)

    mutating func reset() {
        // Discard stale foreign latches too, but do not assume keys are released.
        modifiers = Array(repeating: ModifierState(), count: modifier_specs.count)
    }

    mutating func observe(is_uu: Bool, pid: Int64, key: Int64, flags: UInt64, timestamp: UInt64) -> String {
        guard let index = modifier_specs.firstIndex(where: { $0.left_key == key || $0.right_key == key }) else { return "unwatched" }
        let down = (flags & modifier_specs[index].aggregate) != 0
        modifiers[index].clear_since = nil
        if is_uu {
            guard modifiers[index].uu.observe(down: down, timestamp: timestamp) else { return "ignored_old_uu_modifier" }
            return down ? "uu_down" : "uu_up"
        }
        // A release from one source must not erase another source's hold.
        if modifiers[index].foreign[pid] == nil && modifiers[index].foreign.count >= 64 {
            modifiers[index] = ModifierState()
            return "foreign_capacity_resync"
        }
        var source = modifiers[index].foreign[pid] ?? SourceState()
        guard source.observe(down: down, timestamp: timestamp) else { return "ignored_old_foreign_modifier" }
        modifiers[index].foreign[pid] = source
        return down ? "foreign_down" : "foreign_up"
    }

    mutating func reconcile(snapshot: SystemSnapshot, now: UInt64) -> [String] {
        var recovered: [String] = []
        for index in modifiers.indices {
            // Never time out a known UU hold, even if system queries disagree.
            if modifiers[index].uu.down == true || !snapshot.released(index) {
                modifiers[index].clear_since = nil
                continue
            }
            if !modifiers[index].needs_sync && !modifiers[index].foreign_held && modifiers[index].uu.down == false { continue }
            guard let since = modifiers[index].clear_since, now >= since else {
                modifiers[index].clear_since = now
                continue
            }
            guard now - since >= recovery_interval else { continue }
            modifiers[index].needs_sync = false
            modifiers[index].uu.down = false
            // Retain per-source ordering watermarks, retire only the held state.
            for pid in Array(modifiers[index].foreign.keys) { modifiers[index].foreign[pid]?.down = false }
            modifiers[index].clear_since = nil
            recovered.append(modifier_specs[index].name)
        }
        return recovered
    }

    func decision(_ index: Int) -> String {
        let modifier = modifiers[index]
        if modifier.needs_sync { return "resync_required" }
        if modifier.foreign_held { return "foreign_held" }
        guard let down = modifier.uu.down else { return "unknown" }
        return down ? "uu_held" : "released"
    }

    func corrected_flags(is_uu: Bool, flags: UInt64) -> UInt64 {
        guard is_uu else { return flags }
        var result = flags
        // Mouse timestamps cannot override the latest accepted modifier state.
        for index in modifiers.indices where decision(index) == "released" {
            result &= ~modifier_specs[index].all_bits
        }
        return result
    }

    func diagnostic() -> [[String: Any]] {
        return modifiers.indices.map { index in
            let modifier = modifiers[index]
            return ["key": modifier_specs[index].name, "decision": decision(index),
                    "uu_down": modifier.uu.down.map { $0 ? "down" : "up" } ?? "unknown",
                    "event_ns": String(modifier.uu.timestamp),
                    "foreign_held_pids": modifier.foreign.filter { $0.value.down == true }.keys.sorted()]
        }
    }
}

func merge_remote_mouse_flags(offline_flags: UInt64, correction: RemoteFlagDecision?) -> UInt64 {
    guard let correction = correction else { return offline_flags }
    var result = offline_flags
    for index in modifier_specs.indices where (correction.class_mask | correction.preserve_mask) & UInt8(1 << index) != 0 {
        result = (result & ~modifier_specs[index].all_bits) | (correction.flags & modifier_specs[index].all_bits)
    }
    return result
}

// No ordinary keycode, Unicode, event description or serialized event is read.
func keyboard_diagnostic(event: CGEvent, stage: String, state: GuardState, now: UInt64) -> [String: Any] {
    let flags = event.flags.rawValue
    let command_present = (flags & CGEventFlags.maskCommand.rawValue) != 0
    let command_down = state.modifiers[0].uu.down
    let reason = command_down == true && !command_present ? "command_missing_while_held"
        : command_down == false && command_present ? "command_present_after_release" : "observed"
    return ["stage": stage, "action": event.type == .keyDown ? "down" : "up",
            "pid": event.getIntegerValueField(.eventSourceUnixProcessID),
            "source_state": event.getIntegerValueField(.eventSourceStateID),
            "event_ns": String(event.timestamp), "callback_ns": String(now),
            "flags": String(flags, radix: 16), "command_present": command_present,
            "reason": reason, "state": state.diagnostic()]
}

// Tap callbacks only enqueue bounded records. JSON, disk I/O and console output
// run on the writer queue, so a slow terminal/disk cannot block the event tap.
final class LegacyDiskLog {
    let directory: URL
    let file_limit: Int
    let queue_limit: Int
    let console_enabled: Bool
    let run_id = UUID().uuidString
    private let lock = NSLock()
    private let writer_queue = DispatchQueue(label: "uu-command-guard.log")
    private let console_queue = DispatchQueue(label: "uu-command-guard.console")
    private var console_pending: [String] = []
    private var console_busy = false
    private var pending: [[String: Any]] = []
    private var dropped = 0
    private var sequence: UInt64 = 0
    private var handle: FileHandle?
    private var file_size = 0
    private var warned = false
    private var timer: DispatchSourceTimer?
    private let date_format = ISO8601DateFormatter()
    private let legacy_date_format = ISO8601DateFormatter()
    private var last_cleanup: UInt64? = nil

    init(directory: URL, file_limit: Int = 1_048_576, queue_limit: Int = 512, automatic: Bool = true,
         console_enabled: Bool = true) {
        self.directory = directory
        self.file_limit = file_limit
        self.queue_limit = queue_limit
        self.console_enabled = console_enabled
        date_format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if automatic {
            let timer = DispatchSource.makeTimerSource(queue: writer_queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.drain() }
            timer.resume()
            self.timer = timer
        }
    }

    func record(_ kind: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        guard pending.count < queue_limit else { dropped += 1; return }
        var record = fields
        record["kind"] = kind
        record["seq"] = sequence
        record["run"] = run_id
        record["wall_time"] = Date().timeIntervalSince1970
        record["arrival_ns"] = String(DispatchTime.now().uptimeNanoseconds)
        pending.append(record)
    }

    func notice(_ message: String) { record("notice", ["message": message]) }

    // A blocked terminal must not stop the disk writer or retention maintenance.
    private func console_notice(_ message: String) {
        guard console_enabled else { return }
        lock.lock()
        guard console_pending.count < 16 else { lock.unlock(); return }
        console_pending.append(message)
        guard !console_busy else { lock.unlock(); return }
        console_busy = true
        lock.unlock()
        console_queue.async {
            while true {
                self.lock.lock()
                guard !self.console_pending.isEmpty else {
                    self.console_busy = false
                    self.lock.unlock()
                    return
                }
                let line = self.console_pending.removeFirst()
                self.lock.unlock()
                print(line)
                fflush(stdout)
            }
        }
    }

    // Runs only on writer_queue, while no other process owns the log lock.
    private func prune_logs(now: Date) throws -> Int {
        try handle?.close()
        handle = nil
        file_size = 0
        let manager = FileManager.default
        let cutoff = now.timeIntervalSince1970 - log_retention_seconds
        var removed = 0
        // A previous crash may have occurred before the atomic rename/defer.
        // Under the process lock no other live writer can own these temp files.
        if manager.fileExists(atPath: directory.path) {
            let prefix = ".guard-retention-"
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
                let attributes = try manager.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeRegular { try manager.removeItem(at: url) }
            }
        }
        for generation in 0...3 {
            let url = file_url(generation)
            guard manager.fileExists(atPath: url.path) else { continue }
            let original = try Data(contentsOf: url)
            var kept = Data()
            for line in original.split(separator: 0x0a) {
                guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                    removed += 1
                    continue
                }
                var timestamp = row["time_unix"] as? Double
                if timestamp == nil, let time = row["time"] as? String {
                    timestamp = (date_format.date(from: time) ?? legacy_date_format.date(from: time))?.timeIntervalSince1970
                }
                guard let timestamp = timestamp, timestamp.isFinite, timestamp >= cutoff else {
                    removed += 1
                    continue
                }
                kept.append(contentsOf: line)
                kept.append(0x0a)
            }
            if kept.isEmpty {
                try manager.removeItem(at: url)
            } else if kept != original {
                // Keep the replacement private even before the atomic rename.
                let temporary = directory.appendingPathComponent(".guard-retention-\(UUID().uuidString)")
                defer { try? manager.removeItem(at: temporary) }
                guard manager.createFile(atPath: temporary.path, contents: kept, attributes: [.posixPermissions: 0o600]) else {
                    throw NSError(domain: "GuardLog", code: 2)
                }
                guard rename(temporary.path, url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
        return removed
    }

    // Also used by --clean-logs; does not create an event tap.
    func clean_now(now: Date = Date()) throws -> Int {
        return try writer_queue.sync {
            let removed = try self.prune_logs(now: now)
            self.last_cleanup = DispatchTime.now().uptimeNanoseconds
            return removed
        }
    }

    private func file_url(_ generation: Int = 0) -> URL {
        return directory.appendingPathComponent(generation == 0 ? "guard.log" : "guard.log.\(generation)")
    }

    private func open_file() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: file_url().path) {
            guard manager.createFile(atPath: file_url().path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "GuardLog", code: 1)
            }
        }
        handle = try FileHandle(forWritingTo: file_url())
        file_size = Int(try handle!.seekToEnd())
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        if manager.fileExists(atPath: file_url(3).path) { try manager.removeItem(at: file_url(3)) }
        for index in stride(from: 2, through: 0, by: -1) {
            if manager.fileExists(atPath: file_url(index).path) {
                try manager.moveItem(at: file_url(index), to: file_url(index + 1))
            }
        }
        try open_file()
    }

    private func drain() {
        let now = Date()
        let monotonic_now = DispatchTime.now().uptimeNanoseconds
        if last_cleanup == nil || monotonic_now - last_cleanup! >= 60_000_000_000 {
            last_cleanup = monotonic_now
            do {
                let removed = try prune_logs(now: now)
                if removed > 0 { record("retention", ["removed_records": removed, "retention_seconds": log_retention_seconds]) }
            } catch {
                console_notice("日志过期清理失败，将在下一轮重试：\(error)")
            }
        }
        lock.lock()
        var records = pending
        pending.removeAll(keepingCapacity: true)
        let dropped_count = dropped
        dropped = 0
        lock.unlock()
        if dropped_count > 0 {
            records.append(["kind": "log_overflow", "dropped": dropped_count, "run": run_id,
                            "wall_time": now.timeIntervalSince1970])
        }
        for var record in records {
            if let seconds = record.removeValue(forKey: "wall_time") as? Double {
                guard seconds >= now.timeIntervalSince1970 - log_retention_seconds else { continue }
                record["time"] = date_format.string(from: Date(timeIntervalSince1970: seconds))
                record["time_unix"] = seconds
            }
            if let message = record["message"] as? String { console_notice("[\(record["time"] ?? "")] \(message)") }
            do {
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                data.append(0x0a)
                guard data.count <= file_limit else { continue }
                if handle == nil { try open_file() }
                if file_size + data.count > file_limit { try rotate() }
                try handle!.write(contentsOf: data)
                file_size += data.count
            } catch {
                try? handle?.close()
                handle = nil
                if !warned {
                    console_notice("诊断日志写入失败，过滤继续运行：\(error)")
                    warned = true
                }
            }
        }
    }

    func flush() { writer_queue.sync { self.drain() } }
    @discardableResult
    func close(timeout: DispatchTimeInterval = .seconds(1)) -> Bool {
        timer?.cancel()
        timer = nil
        let finished = DispatchSemaphore(value: 0)
        writer_queue.async {
            self.drain()
            try? self.handle?.close()
            self.handle = nil
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success
    }
}

struct ProcessIdentity: Equatable {
    let pid: pid_t
    let start_seconds: UInt64
    let start_microseconds: UInt64
}

struct SessionTracker {
    var current: ProcessIdentity? = nil
    mutating func update(_ next: ProcessIdentity?) -> Bool {
        guard current != next else { return false }
        current = next
        return true
    }
    func matches(_ pid: Int64) -> Bool { current.map { Int64($0.pid) == pid } ?? false }
}

func process_path(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    return count > 0 ? String(cString: buffer) : ""
}

func process_identity(_ pid: pid_t) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return ProcessIdentity(pid: pid, start_seconds: info.pbi_start_tvsec, start_microseconds: info.pbi_start_tvusec)
}

let expected_path = "/Applications/UURemote.app/Contents/Helpers/UURemoteServer"
func discover_uu() -> ProcessIdentity? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) + 256)
    let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard found > 0 else { return nil }
    for pid in pids.prefix(min(Int(found), pids.count)) where pid > 0 {
        if process_path(pid) == expected_path, let identity = process_identity(pid) { return identity }
    }
    return nil
}

func system_snapshot() -> SystemSnapshot {
    var snapshot = SystemSnapshot(
        hid_flags: CGEventSource.flagsState(.hidSystemState).rawValue,
        session_flags: CGEventSource.flagsState(.combinedSessionState).rawValue)
    for (index, spec) in modifier_specs.enumerated() {
        for key in [spec.left_key, spec.right_key] {
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key)) { snapshot.hid_keys |= UInt64(1) << index }
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) { snapshot.session_keys |= UInt64(1) << index }
        }
    }
    return snapshot
}

func input_source_preferences() -> UserDefaults {
    let domain = "local.uu-command-guard"
    // Foundation rejects a suite with the application's own bundle identifier.
    // Standard defaults already use that domain; the CLI joins it as a suite.
    if Bundle.main.bundleIdentifier == domain { return UserDefaults.standard }
    return UserDefaults(suiteName: domain) ?? UserDefaults.standard
}

let keypad_plus_preference_key = "fix_windows_keypad_plus"
func keypad_plus_preference(_ preferences: UserDefaults) -> Bool {
    (preferences.object(forKey: keypad_plus_preference_key) as? Bool) ?? true
}
// A narrow opt-in text exception: never change the physical down/up key identity.
func apply_remote_keypad_plus(event: CGEvent, type: CGEventType, is_uu: Bool,
                              enabled: Bool, decision: RemoteFlagDecision?) -> Bool {
    guard is_uu, enabled, type == .keyDown, decision?.keypad_plus_text == true,
          [24,69,81].contains(event.getIntegerValueField(.keyboardEventKeycode)) else { return false }
    let plus: [UniChar] = [0x2b]
    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: plus)
    return true
}

// Parse only an integer property-list array; malformed stored values select automatic mode.
func stored_manual_mapping(_ value: Any?) -> PeerManualMapping? {
    guard let values = value as? [Any], values.count == 3 else { return nil }
    var targets: [Int] = []
    for value in values {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              (0...5).contains(number.intValue) else { return nil }
        targets.append(number.intValue)
    }
    return PeerManualMapping(targets: targets)
}

final class MappingSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class MappingSettingsController: NSWindowController {
    private let mode = NSPopUpButton()
    private var targets: [NSPopUpButton] = []
    var mapping_provider: () -> PeerManualMapping? = { nil }
    var mapping_handler: (PeerManualMapping?) -> Void = { _ in }

    init(preview: Bool) {
        let window = MappingSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 370),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = preview ? "修饰键映射设置（预览）" : "修饰键映射设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        guard let content = window.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        let heading = NSTextField(labelWithString: "Windows 控制 Mac 的修饰键映射")
        heading.font = .boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(heading)
        let hint = NSTextField(wrappingLabelWithString: "请按 UU 远程实际设置填写三个映射。通常选择 Mac 左侧按键；Windows 右侧修饰键继续自动验证。")
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        mode.addItems(withTitles: ["自动学习", "手动配置"])
        mode.target = self
        mode.action = #selector(mode_changed)
        mode.setAccessibilityLabel("映射模式")
        stack.addArrangedSubview(row(label: "映射模式", control: mode))
        let labels = ["Windows 左 Ctrl", "Windows 左 Win", "Windows 左 Alt"]
        let names = PeerManualMapping.target_names
        for label in labels {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: names)
            popup.setAccessibilityLabel(label + " 映射到 Mac 按键")
            targets.append(popup)
            stack.addArrangedSubview(row(label: label, control: popup))
        }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let restore = NSButton(title: "恢复默认", target: self, action: #selector(restore_defaults))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        buttons.addArrangedSubview(restore)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func row(label: String, control: NSPopUpButton) -> NSStackView {
        let field = NSTextField(labelWithString: label)
        field.widthAnchor.constraint(equalToConstant: 170).isActive = true
        control.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let row = NSStackView(views: [field, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    func open_settings() {
        let configuration = mapping_provider()
        mode.selectItem(at: configuration == nil ? 0 : 1)
        let values = (configuration ?? PeerManualMapping.default_mapping).targets
        for (index, target) in targets.enumerated() { target.selectItem(at: values[index]) }
        mode_changed()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func mode_changed() {
        for target in targets { target.isEnabled = mode.indexOfSelectedItem == 1 }
    }
    @objc private func restore_defaults() {
        mode.selectItem(at: 1)
        for (index, target) in targets.enumerated() {
            target.selectItem(at: PeerManualMapping.default_mapping.targets[index])
        }
        mode_changed()
    }
    @objc private func cancel() { window?.performClose(nil) }
    @objc private func save() {
        let configuration = mode.indexOfSelectedItem == 1
            ? PeerManualMapping(targets: targets.map { $0.indexOfSelectedItem }) : nil
        mapping_handler(configuration)
        window?.performClose(nil)
    }
}

struct InputSourceInfo {
    let identifier: String
    let bundle_identifier: String
    let keyboard: Bool
    let enabled: Bool
    let selectable: Bool

    var is_wechat: Bool { keyboard && bundle_identifier == "com.tencent.inputmethod.wetype" }
    var is_target: Bool {
        is_wechat && identifier == "com.tencent.inputmethod.wetype.pinyin" && enabled && selectable
    }
}

// TIS is not thread safe. All queries and selections run on the main thread,
// independently of HID callbacks and the background process-discovery queue.
final class InputSourceGuard: NSObject {
    private let read_current: () -> InputSourceInfo?
    private let select_target: () -> OSStatus?
    private let record: (String, [String: Any]) -> Void
    private let notification_lock = NSLock()
    private var check_pending = false
    private var timer: Timer?
    private var selecting = false
    private var last_attempt: UInt64?
    private var last_recorded_status = ""
    private(set) var enabled = true
    private(set) var status_text = "等待检查"

    init(read_current: @escaping () -> InputSourceInfo? = InputSourceGuard.current_source,
         select_target: @escaping () -> OSStatus? = InputSourceGuard.select_wechat,
         record: @escaping (String, [String: Any]) -> Void = { _, _ in }) {
        self.read_current = read_current
        self.select_target = select_target
        self.record = record
        super.init()
    }

    private static func string_property(_ source: TISInputSource, _ key: CFString) -> String {
        guard let raw = TISGetInputSourceProperty(source, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    private static func bool_property(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
    private static func source_info(_ source: TISInputSource) -> InputSourceInfo {
        InputSourceInfo(identifier: string_property(source, kTISPropertyInputSourceID),
                        bundle_identifier: string_property(source, kTISPropertyBundleID),
                        keyboard: string_property(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                        enabled: bool_property(source, kTISPropertyInputSourceIsEnabled),
                        selectable: bool_property(source, kTISPropertyInputSourceIsSelectCapable))
    }
    static func current_source() -> InputSourceInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return source_info(source)
    }
    static func select_wechat() -> OSStatus? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
        for source in list as! [TISInputSource] where source_info(source).is_target {
            return TISSelectInputSource(source)
        }
        // Do not enable/install sources or select the non-selectable parent.
        return nil
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for name in [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged] {
            center.addObserver(self, selector: #selector(source_changed),
                               name: NSNotification.Name(name! as String), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        check()
    }

    @objc private func source_changed(_ notification: Notification) {
        // Distributed callbacks may arrive off-main. Coalesce into one check.
        notification_lock.lock()
        guard !check_pending else { notification_lock.unlock(); return }
        check_pending = true
        notification_lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.notification_lock.lock()
            self.check_pending = false
            self.notification_lock.unlock()
            self.check()
        }
    }

    private func set_status(_ text: String) {
        status_text = text
        if text != last_recorded_status {
            record("input_source_status", ["enabled": enabled, "status": text])
            last_recorded_status = text
        }
    }

    func set_enabled(_ value: Bool) {
        enabled = value
        last_attempt = nil
        check()
    }

    func check(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard enabled else { set_status("已关闭"); return }
        guard !selecting else { return }
        guard let current = read_current() else { set_status("无法读取当前输入法"); return }
        if current.is_wechat { set_status("微信输入法已选中"); return }
        if let last = last_attempt, now >= last, now - last < 1_000_000_000 { return }
        last_attempt = now
        selecting = true
        let result = select_target()
        selecting = false
        guard let result = result else { set_status("微信输入法未安装或未启用"); return }
        record("input_source_switch", ["from_source": current.identifier, "result": result])
        if result != noErr {
            set_status("切回失败（错误码 \(result)）")
        } else if read_current()?.is_wechat == true {
            set_status("微信输入法已选中")
        } else {
            set_status("已请求切回，等待系统确认")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        enabled = false
    }
}

// UI observes state on the main run loop; input callbacks never update menus.
struct MenuSnapshot {
    var monitoring = false
    var failure: String? = nil
    var sleeping = false
    var uu_pid: pid_t? = nil
    var tap_enabled = false
    var session_tap_enabled = false
    var decisions = Array(repeating: "unknown", count: modifier_specs.count)
    var corrected: UInt64 = 0

    var summary: String {
        if let failure = failure { return failure }
        if !monitoring { return "输入监听未启动" }
        if sleeping { return "系统休眠中" }
        if !tap_enabled { return "输入监听恢复中" }
        if uu_pid == nil { return "等待 UU 服务" }
        if decisions.contains("resync_required") || decisions.contains("unknown") { return "正在同步修饰键" }
        if decisions.contains("foreign_held") { return "运行中：部分修饰键暂不修正" }
        return "监听运行中"
    }
}

final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status_item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let summary_item = NSMenuItem()
    private let service_item = NSMenuItem()
    private let tap_item = NSMenuItem()
    private let diagnostic_item = NSMenuItem()
    private let count_item = NSMenuItem()
    private let input_source_item = NSMenuItem()
    private let input_source_toggle = NSMenuItem(title: "保持微信输入法", action: #selector(toggle_input_source), keyEquivalent: "")
    private let keypad_plus_toggle = NSMenuItem(title: "修复 Windows 小键盘 +", action: #selector(toggle_keypad_plus), keyEquivalent: "")
    private let peer_item = NSMenuItem()
    private let peer_counts_item = NSMenuItem()
    private let peer_toggle = NSMenuItem(title: "局域网辅助同步", action: #selector(toggle_peer), keyEquivalent: "")
    private var modifier_items: [NSMenuItem] = []
    private let retry_item = NSMenuItem(title: "重试启动监听", action: #selector(retry_start), keyEquivalent: "")
    private let log_directory: URL
    private let preview: Bool
    private var refresh_timer: Timer?
    private var mapping_settings: MappingSettingsController?
    var snapshot_provider: () -> MenuSnapshot = { MenuSnapshot() }
    var retry_handler: () -> Void = {}
    var quit_handler: () -> Void = {}
    var input_source_provider: () -> (Bool, String) = { (false, "未启用") }
    var input_source_handler: () -> Void = {}
    var keypad_plus_provider: () -> Bool = { true }
    var keypad_plus_handler: () -> Void = {}
    var peer_provider: () -> (Bool, String, UInt64, UInt64) = { (false, "未配置对端 IP", 0, 0) }
    var peer_handler: () -> Void = {}
    var peer_ip_provider: () -> String = { "" }
    var peer_ip_handler: (String) -> String? = { _ in nil }
    var mapping_provider: () -> PeerManualMapping? = { nil }
    var mapping_handler: (PeerManualMapping?) -> Void = { _ in }
    var export_provider: () -> [String: Any] = { [:] }
    private let export_queue = DispatchQueue(label: "uu-command-guard.export")

    init(log_directory: URL, preview: Bool = false) {
        self.log_directory = log_directory
        self.preview = preview
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        let heading = NSMenuItem(title: "UU 修补工具 \(guard_version)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for item in [summary_item, service_item, tap_item, diagnostic_item, count_item] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for _ in modifier_specs {
            let item = NSMenuItem()
            item.isEnabled = false
            modifier_items.append(item)
            menu.addItem(item)
        }
        let hint = NSMenuItem(title: "同步久未完成：停住鼠标，再按松对应键", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        input_source_toggle.target = self
        input_source_toggle.isEnabled = !preview
        menu.addItem(input_source_toggle)
        input_source_item.isEnabled = false
        menu.addItem(input_source_item)
        keypad_plus_toggle.target = self
        keypad_plus_toggle.isEnabled = !preview
        menu.addItem(keypad_plus_toggle)
        menu.addItem(.separator())
        peer_toggle.target = self
        peer_toggle.isEnabled = !preview
        menu.addItem(peer_toggle)
        peer_item.isEnabled = false
        peer_counts_item.isEnabled = false
        menu.addItem(peer_item)
        menu.addItem(peer_counts_item)
        add_action("设置 Windows IP…", #selector(configure_peer))
        add_action("修饰键映射设置…", #selector(open_mapping_settings))
        add_action("导出最近两分钟诊断…", #selector(export_diagnostics))
        menu.addItem(.separator())
        retry_item.target = self
        menu.addItem(retry_item)
        add_action("打开辅助功能设置…", #selector(open_permissions))
        menu.addItem(.separator())
        add_action("退出 UU 修补工具", #selector(quit))
        if let icon_url = Bundle.main.url(forResource: "MenuBar", withExtension: "png"),
           let image = NSImage(contentsOf: icon_url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            status_item.button?.image = image
            status_item.button?.imagePosition = .imageLeading
        }
        status_item.button?.title = status_item.button?.image == nil ? "UU" : ""
        status_item.menu = menu
        NSApplication.shared.delegate = self
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh_timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func add_action(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func refresh() {
        let snapshot = snapshot_provider()
        summary_item.title = "状态：\(snapshot.summary)"
        service_item.title = snapshot.uu_pid.map { "UU 服务：已连接（PID \($0)）" } ?? "UU 服务：未连接"
        tap_item.title = "输入监听：\(snapshot.tap_enabled ? "已启用" : "未启用")"
        diagnostic_item.title = "会话层诊断：\(snapshot.session_tap_enabled ? "已启用" : "未启用")"
        count_item.title = "本次累计修正：\(snapshot.corrected) 次"
        let labels = ["released": "已松开，可清理残留", "uu_held": "UU 按住中",
                      "foreign_held": "其他来源可能按住", "resync_required": "等待同步", "unknown": "尚未确定"]
        for index in modifier_specs.indices {
            modifier_items[index].title = "\(modifier_specs[index].name)：\(labels[snapshot.decisions[index]] ?? "尚未确定")"
        }
        retry_item.isEnabled = !snapshot.monitoring && !preview
        let input_status = input_source_provider()
        input_source_toggle.state = input_status.0 ? .on : .off
        input_source_item.title = "输入法：\(input_status.1)"
        keypad_plus_toggle.state = keypad_plus_provider() ? .on : .off
        let peer_status = peer_provider()
        peer_toggle.state = peer_status.0 ? .on : .off
        peer_item.title = "辅助：\(peer_status.1)"
        peer_counts_item.title = "远端修正：\(peer_status.2)　跳过：\(peer_status.3)"
        let healthy = snapshot.monitoring && snapshot.tap_enabled
        status_item.button?.title = status_item.button?.image == nil ? (healthy ? "UU" : "UU!") : (healthy ? "" : "!")
        status_item.button?.toolTip = "UU 修补工具：\(snapshot.summary)"
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc private func retry_start() { retry_handler(); refresh() }
    @objc private func toggle_input_source() { input_source_handler(); refresh() }
    @objc private func toggle_keypad_plus() { keypad_plus_handler(); refresh() }
    @objc private func toggle_peer() { peer_handler(); refresh() }
    @objc func open_mapping_settings() {
        if mapping_settings == nil {
            let settings = MappingSettingsController(preview: preview)
            settings.mapping_provider = { [weak self] in self?.mapping_provider() }
            settings.mapping_handler = { [weak self] configuration in
                self?.mapping_handler(configuration)
                self?.refresh()
            }
            mapping_settings = settings
        }
        mapping_settings?.open_settings()
    }
    @objc private func configure_peer() {
        let alert = NSAlert()
        alert.messageText = "设置 Windows 对端 IP"
        alert.informativeText = "只需填写 Windows 的 IPv4 地址，UDP 端口固定为 47731。留空关闭网络辅助，保留离线修补。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.stringValue = peer_ip_provider()
        field.placeholderString = "对端 IPv4 地址"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let error = peer_ip_handler(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let failure = NSAlert()
                failure.messageText = "无法启用网络辅助"
                failure.informativeText = error
                failure.runModal()
            }
        }
        refresh()
    }
    @objc private func export_diagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "uu-diagnostics.json"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let report = export_provider()
        export_queue.async {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "诊断导出失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
    @objc private func open_permissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { quit_handler() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if preview { open_mapping_settings() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quit_handler()
        return .terminateCancel
    }
    func close() {
        mapping_settings?.close()
        refresh_timer?.invalidate()
        NSStatusBar.system.removeStatusItem(status_item)
    }
}

func self_test() throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    check(monitored_event_types.isDisjoint(with: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]), "motion and drag excluded from event tap")
    check(keyboard_types.union([.flagsChanged, .leftMouseDown, .scrollWheel]).isSubset(of: monitored_event_types), "shortcut and modifier repairs remain monitored")
    func ready_state() -> GuardState {
        var state = GuardState()
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 0)
        _ = state.reconcile(snapshot: SystemSnapshot(), now: recovery_interval)
        return state
    }
    let shift = CGEventFlags.maskShift.rawValue
    for (index, spec) in modifier_specs.enumerated() {
        let bits = spec.all_bits
        var state = GuardState()
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "startup unknown")
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 0)
        check(state.reconcile(snapshot: SystemSnapshot(), now: recovery_interval - 1).isEmpty, "no early recovery")
        check(state.reconcile(snapshot: SystemSnapshot(), now: recovery_interval).contains(spec.name), "idle auto recovery")
        check(state.corrected_flags(is_uu: true, flags: bits | shift) == shift, "released and preserve Shift")
        check(state.corrected_flags(is_uu: false, flags: bits) == bits, "foreign mouse unchanged")
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: bits, timestamp: 10)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "hold preserved")
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 1_000_000_000)
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 9_000_000_000)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "never timeout known UU hold")
        _ = state.observe(is_uu: true, pid: 1, key: spec.right_key, flags: bits, timestamp: 11)
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: bits, timestamp: 12)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "other side still held")
        _ = state.observe(is_uu: true, pid: 1, key: spec.right_key, flags: 0, timestamp: 20)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "release clears even delayed mouse")
        check(state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: bits, timestamp: 19) == "ignored_old_uu_modifier", "late down ignored")
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "late down retains release")
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: bits, timestamp: 30)
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: 0, timestamp: 29)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "late release retains hold")
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: 0, timestamp: 30)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "equal timestamps delivery order")
        _ = state.observe(is_uu: false, pid: 2, key: spec.left_key, flags: bits, timestamp: 40)
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: 0, timestamp: 41)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "foreign hold protected")
        _ = state.observe(is_uu: false, pid: 3, key: spec.left_key, flags: 0, timestamp: 42)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "another foreign source cannot release hold")
        _ = state.observe(is_uu: false, pid: 2, key: spec.left_key, flags: 0, timestamp: 43)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "foreign release preserves UU release")
        _ = state.observe(is_uu: false, pid: 2, key: spec.left_key, flags: bits, timestamp: 42)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "late foreign down ignored")
        _ = state.observe(is_uu: false, pid: 2, key: spec.left_key, flags: bits, timestamp: 44)
        _ = state.reconcile(snapshot: SystemSnapshot(hid_flags: bits), now: 0)
        check(state.reconcile(snapshot: SystemSnapshot(hid_flags: bits), now: 1_000_000_000).isEmpty, "held HID prevents recovery")
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 2_000_000_000)
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 2_000_000_000 + recovery_interval)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "lost foreign release recovers when system clear")
        _ = state.observe(is_uu: false, pid: 2, key: spec.left_key, flags: bits, timestamp: 45)
        state.reset()
        check(state.modifiers[index].foreign.isEmpty, "reset clears stale foreign records")
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: 0, timestamp: 46)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "gap needs synchronization")
        _ = state.reconcile(snapshot: SystemSnapshot(session_keys: UInt64(1) << index), now: 0)
        _ = state.reconcile(snapshot: SystemSnapshot(session_keys: UInt64(1) << index), now: recovery_interval)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "held per-key state prevents recovery")
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 2_000_000_000)
        _ = state.reconcile(snapshot: SystemSnapshot(), now: 2_000_000_000 + recovery_interval)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "gap auto recovery")
        state = ready_state()
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: bits, timestamp: 0)
        check(state.corrected_flags(is_uu: true, flags: bits) == bits, "zero timestamp press")
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: 0, timestamp: 0)
        check(state.corrected_flags(is_uu: true, flags: bits) == 0, "zero timestamp release")
    }
    var state = ready_state()
    for spec in modifier_specs { _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: watched_bits, timestamp: 10) }
    for spec in modifier_specs {
        var copy = state
        _ = copy.observe(is_uu: true, pid: 1, key: spec.left_key, flags: watched_bits & ~spec.all_bits, timestamp: 11)
        check(copy.corrected_flags(is_uu: true, flags: watched_bits | shift) == (watched_bits & ~spec.all_bits) | shift, "independent modifiers")
    }
    for spec in modifier_specs {
        _ = state.observe(is_uu: true, pid: 1, key: spec.left_key, flags: watched_bits & ~spec.all_bits, timestamp: 11)
    }
    check(state.corrected_flags(is_uu: true, flags: watched_bits | shift) == shift, "unrelated stale flags cannot undo releases")
    // Every system-state input must independently veto idle recovery.
    for snapshot in [SystemSnapshot(hid_flags: watched_bits), SystemSnapshot(session_flags: watched_bits),
                     SystemSnapshot(hid_keys: 7), SystemSnapshot(session_keys: 7)] {
        var blocked = GuardState()
        _ = blocked.reconcile(snapshot: snapshot, now: 0)
        check(blocked.reconcile(snapshot: snapshot, now: recovery_interval).isEmpty, "all snapshot components veto recovery")
    }
    var interrupted = GuardState()
    _ = interrupted.reconcile(snapshot: SystemSnapshot(), now: 0)
    _ = interrupted.observe(is_uu: true, pid: 1, key: 55, flags: 0, timestamp: 1)
    _ = interrupted.reconcile(snapshot: SystemSnapshot(), now: recovery_interval)
    check(interrupted.decision(0) == "resync_required", "modifier event restarts stable interval")
    _ = interrupted.reconcile(snapshot: SystemSnapshot(), now: recovery_interval * 2)
    check(interrupted.decision(0) == "released", "stable interval restarts successfully")
    var many_sources = ready_state()
    for pid in 1...65 { _ = many_sources.observe(is_uu: false, pid: Int64(pid), key: 55, flags: watched_bits, timestamp: 1) }
    check(many_sources.decision(0) == "resync_required" && many_sources.modifiers[0].foreign.count <= 64, "foreign capacity fails closed")
    var long_hold = ready_state()
    _ = long_hold.observe(is_uu: true, pid: 1, key: 55, flags: watched_bits, timestamp: 1)
    for tick in 0...100 { _ = long_hold.reconcile(snapshot: SystemSnapshot(), now: UInt64(tick) * recovery_interval) }
    check(long_hold.decision(0) == "uu_held", "many clear polls never erase known hold")
    var tracker = SessionTracker()
    let first = ProcessIdentity(pid: 10, start_seconds: 1, start_microseconds: 0)
    check(!tracker.matches(0), "disconnected PID zero is not UU")
    check(tracker.update(first), "connect")
    check(!tracker.update(first), "same process does not reset")
    check(tracker.update(nil), "disconnect")
    check(!tracker.update(nil), "waiting does not keep resetting")
    check(tracker.update(ProcessIdentity(pid: 11, start_seconds: 2, start_microseconds: 0)), "new PID reconnect")
    check(tracker.update(ProcessIdentity(pid: 11, start_seconds: 3, start_microseconds: 0)), "PID reuse detected")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("guard-log-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let log = LegacyDiskLog(directory: temp, file_limit: 1024, queue_limit: 2, automatic: false)
    for number in 0..<6 { log.record("sample", ["number": number]) }
    log.flush()
    let initial = try String(contentsOf: temp.appendingPathComponent("guard.log"), encoding: .utf8)
    check(initial.contains("log_overflow") && initial.contains("\"dropped\":4"), "bounded queue reports drops")
    for number in 0..<40 { log.record("rotation", ["number": number]); log.flush() }
    check(log.close(), "normal logger drains on close")
    let files = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
    check(files.count == 4, "four rotating files")
    for file in files {
        let data = try Data(contentsOf: file)
        check(data.count <= 1024, "file size bound")
        for line in data.split(separator: 0x0a) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "private log permissions")
    }
    let retention_dir = temp.appendingPathComponent("retention")
    try FileManager.default.createDirectory(at: retention_dir, withIntermediateDirectories: true)
    let test_now = Date()
    let seconds = test_now.timeIntervalSince1970
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func fixture(_ id: String, _ timestamp: Double, legacy: Bool = false) throws -> Data {
        var row: [String: Any] = ["id": id]
        if legacy { row["time"] = iso.string(from: Date(timeIntervalSince1970: timestamp)) }
        else { row["time_unix"] = timestamp }
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(0x0a)
        return data
    }
    var mixed = try fixture("old", seconds - 3601)
    mixed.append(try fixture("boundary", seconds - 3600))
    mixed.append(try fixture("recent", seconds - 30))
    mixed.append(Data("broken\n{\"kind\":\"old_untimed_overflow\"}\n".utf8))
    try mixed.write(to: retention_dir.appendingPathComponent("guard.log"))
    var legacy = try fixture("legacy_old", seconds - 7200, legacy: true)
    legacy.append(try fixture("legacy_recent", seconds - 30, legacy: true))
    try legacy.write(to: retention_dir.appendingPathComponent("guard.log.1"))
    try fixture("all_old", seconds - 7200).write(to: retention_dir.appendingPathComponent("guard.log.2"))
    let all_recent = try fixture("all_recent", seconds - 10)
    try all_recent.write(to: retention_dir.appendingPathComponent("guard.log.3"))
    try Data("unrelated".utf8).write(to: retention_dir.appendingPathComponent("unrelated.txt"))
    let orphan = retention_dir.appendingPathComponent(".guard-retention-\(UUID().uuidString)")
    try mixed.write(to: orphan)
    try Data("not-owned".utf8).write(to: retention_dir.appendingPathComponent(".guard-retention-not-a-uuid"))
    let retention_log = LegacyDiskLog(directory: retention_dir, automatic: false)
    check(try retention_log.clean_now(now: test_now) == 5, "remove old, invalid and untimed rows")
    check(!FileManager.default.fileExists(atPath: orphan.path), "remove orphaned retention copies after crash")
    check(FileManager.default.fileExists(atPath: retention_dir.appendingPathComponent(".guard-retention-not-a-uuid").path), "do not remove similar unrelated filenames")
    let retained = try String(contentsOf: retention_dir.appendingPathComponent("guard.log"), encoding: .utf8)
    check(retained.contains("boundary") && retained.contains("recent") && !retained.contains("\"old\""), "mixed file retains last hour including boundary")
    let retained_legacy = try String(contentsOf: retention_dir.appendingPathComponent("guard.log.1"), encoding: .utf8)
    check(retained_legacy.contains("legacy_recent") && !retained_legacy.contains("legacy_old"), "legacy ISO timestamps supported")
    check(!FileManager.default.fileExists(atPath: retention_dir.appendingPathComponent("guard.log.2").path), "delete fully expired file")
    check(try Data(contentsOf: retention_dir.appendingPathComponent("guard.log.3")) == all_recent, "recent backup unchanged")
    check(try String(contentsOf: retention_dir.appendingPathComponent("unrelated.txt"), encoding: .utf8) == "unrelated", "only four owned log names cleaned")
    let retained_permissions = try FileManager.default.attributesOfItem(atPath: retention_dir.appendingPathComponent("guard.log").path)[.posixPermissions] as? NSNumber
    check(retained_permissions?.intValue == 0o600, "rewritten log remains private")
    retention_log.record("after_cleanup")
    retention_log.flush()
    check(try retention_log.clean_now(now: test_now.addingTimeInterval(1)) == 1, "cleanup closes active file and expires former boundary")
    retention_log.record("after_second_cleanup")
    check(retention_log.close(), "close after retention")
    let appended = try String(contentsOf: retention_dir.appendingPathComponent("guard.log"), encoding: .utf8)
    check(appended.contains("after_cleanup") && appended.contains("after_second_cleanup"), "append reopens correct file after atomic replacement")
    check(try FileManager.default.contentsOfDirectory(atPath: retention_dir.path).allSatisfy {
        !$0.hasPrefix(".guard-retention-") || UUID(uuidString: String($0.dropFirst(".guard-retention-".count))) == nil
    }, "no owned retention temporary files remain")

    guard let key_event = CGEvent(source: nil) else { preconditionFailure("cannot create in-memory test event") }
    key_event.setIntegerValueField(.keyboardEventKeycode, value: 9)
    key_event.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
    key_event.timestamp = 100
    var key_state = ready_state()
    _ = key_state.observe(is_uu: true, pid: 42, key: 55, flags: modifier_specs[0].aggregate, timestamp: 90)
    let allowed_fields: Set<String> = ["stage", "action", "pid", "source_state", "event_ns", "callback_ns", "flags", "command_present", "reason", "state"]
    for stage in ["hid", "session"] {
        for type: CGEventType in [.keyDown, .keyUp] {
            key_event.type = type
            key_event.setIntegerValueField(.keyboardEventKeycode, value: 9)
            key_event.flags = CGEventFlags(rawValue: shift)
            let diagnostic = keyboard_diagnostic(event: key_event, stage: stage, state: key_state, now: 110)
            check(Set(diagnostic.keys) == allowed_fields, "keyboard diagnostic contains no keycode or text")
            check(diagnostic["reason"] as? String == "command_missing_while_held", "diagnose missing Command")
            check(diagnostic["action"] as? String == (type == .keyDown ? "down" : "up"), "keyboard action logged")
            check(key_event.flags.rawValue == shift && key_event.timestamp == 100 && key_event.getIntegerValueField(.keyboardEventKeycode) == 9, "diagnostic leaves input unchanged")
        }
    }
    key_event.flags = CGEventFlags.maskCommand
    check(keyboard_diagnostic(event: key_event, stage: "hid", state: key_state, now: 110)["reason"] as? String == "observed", "held Command present")
    _ = key_state.observe(is_uu: true, pid: 42, key: 55, flags: 0, timestamp: 101)
    check(keyboard_diagnostic(event: key_event, stage: "session", state: key_state, now: 110)["reason"] as? String == "command_present_after_release", "diagnose unexpected Command")
    check(process_identity(getpid())?.pid == getpid(), "read actual process identity")
    let wechat_source = InputSourceInfo(identifier: "com.tencent.inputmethod.wetype.pinyin",
                                        bundle_identifier: "com.tencent.inputmethod.wetype", keyboard: true,
                                        enabled: true, selectable: true)
    let abc_source = InputSourceInfo(identifier: "com.apple.keylayout.ABC", bundle_identifier: "",
                                    keyboard: true, enabled: true, selectable: true)
    check(wechat_source.is_target, "verified selectable WeChat mode")
    check(!InputSourceInfo(identifier: "com.tencent.inputmethod.wetype",
                          bundle_identifier: "com.tencent.inputmethod.wetype", keyboard: true,
                          enabled: true, selectable: false).is_target, "do not select parent input method")
    check(!InputSourceInfo(identifier: wechat_source.identifier, bundle_identifier: "other", keyboard: true,
                          enabled: true, selectable: true).is_target, "input method bundle must match")
    check(!InputSourceInfo(identifier: wechat_source.identifier, bundle_identifier: wechat_source.bundle_identifier,
                          keyboard: true, enabled: false, selectable: true).is_target, "do not select disabled mode")
    var current_source = wechat_source
    var selection_calls = 0
    let input_guard = InputSourceGuard(read_current: { current_source }, select_target: {
        selection_calls += 1
        current_source = wechat_source
        return noErr
    })
    input_guard.check(now: 0)
    check(selection_calls == 0, "already WeChat makes no selection")
    current_source = abc_source
    input_guard.check(now: 1)
    check(selection_calls == 1 && current_source.is_wechat, "restore foreign input source")
    input_guard.check(now: 2)
    check(selection_calls == 1, "own selection notification makes no extra selection")
    input_guard.set_enabled(false)
    current_source = abc_source
    input_guard.check(now: 3)
    check(selection_calls == 1 && input_guard.status_text == "已关闭", "disabled guard leaves input source alone")
    input_guard.set_enabled(true)
    check(selection_calls == 2 && current_source.is_wechat, "reenabling checks immediately")
    var failing_calls = 0
    let failing_guard = InputSourceGuard(read_current: { abc_source }, select_target: {
        failing_calls += 1
        return -50
    })
    failing_guard.check(now: 0)
    for instant: UInt64 in [1, 100, 999_999_999] { failing_guard.check(now: instant) }
    check(failing_calls == 1, "failure notification storm is throttled")
    failing_guard.check(now: 1_000_000_000)
    check(failing_calls == 2 && failing_guard.status_text.contains("-50"), "failed selection retries after cooldown")
    let missing_guard = InputSourceGuard(read_current: { abc_source }, select_target: { nil })
    missing_guard.check(now: 0)
    check(missing_guard.status_text == "微信输入法未安装或未启用", "missing input source stays unavailable")
    var delayed_source = abc_source
    let delayed_guard = InputSourceGuard(read_current: { delayed_source }, select_target: { noErr })
    delayed_guard.check(now: 0)
    check(delayed_guard.status_text == "已请求切回，等待系统确认", "request alone does not claim restoration")
    delayed_source = wechat_source
    delayed_guard.check(now: 1)
    check(delayed_guard.status_text == "微信输入法已选中", "later observation confirms selection")
    let preferences = input_source_preferences()
    check(Bundle.main.bundleIdentifier != "local.uu-command-guard" || preferences === UserDefaults.standard,
          "bundled startup uses standard preferences without an invalid self suite")
    check(stored_manual_mapping(nil) == nil, "absent manual mapping selects automatic mode")
    check(stored_manual_mapping([0, 4, 2]) == PeerManualMapping.default_mapping, "default manual mapping preference parses")
    check(stored_manual_mapping([1, 5, 3])?.targets == [1, 5, 3], "right target choices parse")
    check(stored_manual_mapping([0, 0, 0])?.targets == [0, 0, 0], "many-to-one preference parses")
    for value: Any in [[0, 4], [0, 4, 2, 1], [0, 6, 2], [-1, 4, 2], [true, 4, 2], [0.5, 4.0, 2.0], ["0", "4", "2"]] {
        check(stored_manual_mapping(value) == nil, "malformed manual mapping selects automatic mode")
    }
    let memory_log = DiagnosticLog(row_limit: 2, byte_limit: 4096)
    memory_log.record("old", now: 0)
    memory_log.record("recent", now: 100)
    memory_log.record("newest", now: 110)
    let memory_snapshot = memory_log.snapshot(now: 120)
    check(memory_snapshot["retained_rows"] as? Int == 2, "memory diagnostics row bound")
    check(memory_log.snapshot(now: 231)["retained_rows"] as? Int == 0, "memory diagnostics monotonic two-minute expiry")
    memory_log.record("oversize", ["message": String(repeating: "x", count: 5000)], now: 232)
    check(memory_log.snapshot(now: 232)["retained_rows"] as? Int == 0, "oversize diagnostics rejected")
    check((memory_log.snapshot(now: 232)["dropped"] as? Int ?? 0) >= 2, "evicted and oversized memory records counted")
    let peer_learning = PeerMatcher()
    peer_learning.offset = 0; peer_learning.rtt = 1000; peer_learning.clock_at = 100
    peer_learning.learned_window = "self-test-window"; peer_learning.delays = [0,0,0]; peer_learning.ordinary_pair = true
    peer_learning.mappings = [1:(0,8),2:(0,16),4:(2,1),8:(2,8192),16:(1,32),32:(1,64)]
    check(peer_learning.ready && peer_learning.readiness_status_text.contains("映射已验证"), "learned peer with complete mapping is ready")
    peer_learning.ingest([], gap: true, now: 100)
    check(!peer_learning.ready && peer_learning.mappings.isEmpty && peer_learning.readiness_status_text.contains("重新学习"),
          "peer source gap revokes mapping evidence and readiness")
    let missing_peer_input = PeerObservation(time:100,kind:"key",key:25,action:"down",flags:0,modifier_class:nil)
    check(peer_learning.decide(missing_peer_input,now:100,protected:0) == nil && peer_learning.last_decision_reason == "no_candidate",
          "missing source evidence never guesses a keyboard modifier")
    let left_peer = PeerMatcher()
    left_peer.offset = 0; left_peer.rtt = 1000; left_peer.clock_at = 1_000_000
    left_peer.learned_window = "self-test-window"; left_peer.delays = [5000,5000,5000]; left_peer.ordinary_pair = true
    left_peer.mappings = [1:(0,8),4:(2,1),16:(1,32)]
    check(left_peer.unverified_modifier_names.isEmpty && left_peer.mapping_status_text.contains("3/3"), "left-only setup needs no right keys")
    left_peer.ingest([PeerInput(id:1,time_us:1_010_000,window:"self-test-window",kind:"key",key:25,action:"down",mods:1)],gap:false,now:1_011_000)
    let left_input = PeerObservation(time:1_015_000,kind:"key",key:25,action:"down",flags:0,modifier_class:nil)
    check(left_peer.decide(left_input,now:1_015_000,protected:0)?.flags == modifier_specs[0].aggregate|8,
          "left Ctrl repairs Command with no right mapping")
    left_peer.ingest([PeerInput(id:2,time_us:1_020_000,window:"self-test-window",kind:"button",key:1,action:"down",mods:2)],gap:false,now:1_021_000)
    let unknown_right_flags = modifier_specs[0].aggregate|16
    let right_mouse = PeerObservation(time:1_025_000,kind:"button",key:1,action:"down",flags:unknown_right_flags,modifier_class:nil)
    let protected_mouse = left_peer.decide(right_mouse,now:1_025_000,protected:0)
    var released_guard = GuardState()
    released_guard.modifiers[0].needs_sync = false; released_guard.modifiers[0].uu.down = false
    let offline_mouse = released_guard.corrected_flags(is_uu:true,flags:unknown_right_flags)
    check(offline_mouse == 0 && protected_mouse?.preserve_mask == 7 && merge_remote_mouse_flags(offline_flags:offline_mouse,correction:protected_mouse) == unknown_right_flags,
          "an unknown right mapping protects every possible target across legacy mouse clearing")
    let dynamic_peer = PeerMatcher()
    dynamic_peer.offset = 0; dynamic_peer.rtt = 1000; dynamic_peer.clock_at = 1_000_000
    dynamic_peer.learned_window = "self-test-window"; dynamic_peer.delays = [5000,5000,5000]; dynamic_peer.ordinary_pair = true
    let control_flags = modifier_specs[2].aggregate|1
    let dynamic_down = PeerObservation(time:1_015_000,kind:"modifier",key:0,action:"down",flags:control_flags,modifier_class:2,side_bit:1)
    dynamic_peer.ingest([PeerInput(id:1,time_us:1_010_000,window:"self-test-window",kind:"modifier",key:224,action:"down",mods:1)],gap:false,now:1_011_000)
    _ = dynamic_peer.decide(dynamic_down,now:1_015_000,protected:0)
    check(dynamic_peer.mappings.isEmpty, "a remapped Ctrl down alone never proves its target")
    let dynamic_up = PeerObservation(time:1_025_000,kind:"modifier",key:0,action:"up",flags:0,modifier_class:2,side_bit:1)
    dynamic_peer.ingest([PeerInput(id:2,time_us:1_020_000,window:"self-test-window",kind:"modifier",key:224,action:"up",mods:0)],gap:false,now:1_021_000)
    _ = dynamic_peer.decide(dynamic_up,now:1_025_000,protected:0)
    check(dynamic_peer.mappings[1]?.0 == 2 && dynamic_peer.mappings[1]?.1 == 1, "complete physical edges learn Ctrl to Control")
    dynamic_peer.ingest([PeerInput(id:3,time_us:1_030_000,window:"self-test-window",kind:"key",key:25,action:"down",mods:1)],gap:false,now:1_031_000)
    let dynamic_key = PeerObservation(time:1_035_000,kind:"key",key:25,action:"down",flags:0,modifier_class:nil)
    let dynamic_correction = dynamic_peer.decide(dynamic_key,now:1_035_000,protected:0)
    check(dynamic_correction?.flags == control_flags && dynamic_correction?.class_mask == 4 && dynamic_correction?.preserve_mask == 3,
          "partial dynamic learning repairs its proven target and preserves unknown targets")
    dynamic_peer.ingest([PeerInput(id:4,time_us:1_040_000,window:"self-test-window",kind:"button",key:1,action:"down",mods:4)],gap:false,now:1_041_000)
    let dynamic_mouse = PeerObservation(time:1_045_000,kind:"button",key:1,action:"down",flags:unknown_right_flags,modifier_class:nil)
    let unknown_left = dynamic_peer.decide(dynamic_mouse,now:1_045_000,protected:0)
    check(unknown_left?.class_mask == 0 && unknown_left?.preserve_mask == 7 && merge_remote_mouse_flags(offline_flags:0,correction:unknown_left) == unknown_right_flags,
          "an active unknown left mapping cannot lose flags through the legacy mouse path")
    dynamic_peer.mappings = [1:(1,32),4:(1,64),16:(2,1)]
    dynamic_peer.ingest([PeerInput(id:5,time_us:1_050_000,window:"self-test-window",kind:"key",key:25,action:"down",mods:1|4)],gap:false,now:1_051_000)
    let merged_targets = PeerObservation(time:1_055_000,kind:"key",key:25,action:"down",flags:modifier_specs[0].aggregate|8|CGEventFlags.maskShift.rawValue,modifier_class:nil)
    let merged_result = dynamic_peer.decide(merged_targets,now:1_055_000,protected:0)
    check(merged_result?.flags == modifier_specs[1].aggregate|32|64|CGEventFlags.maskShift.rawValue && merged_result?.class_mask == 7,
          "multiple source modifiers combine target sides, clear unused targets and preserve Shift")
    dynamic_peer.ingest([PeerInput(id:6,time_us:1_060_000,window:"self-test-window",kind:"key",key:25,action:"down",mods:4)],gap:false,now:1_061_000)
    var one_target_held = merged_targets; one_target_held.time = 1_065_000
    check(dynamic_peer.decide(one_target_held,now:1_065_000,protected:0)?.flags == modifier_specs[1].aggregate|64|CGEventFlags.maskShift.rawValue,
          "releasing one source keeps the other source on the shared target")
    dynamic_peer.ingest([PeerInput(id:7,time_us:1_070_000,window:"self-test-window",kind:"modifier",key:224,action:"down",mods:1)],gap:false,now:1_071_000)
    let changed_target = PeerObservation(time:1_075_000,kind:"modifier",key:0,action:"down",flags:modifier_specs[0].aggregate|8,modifier_class:0,side_bit:8)
    _ = dynamic_peer.decide(changed_target,now:1_075_000,protected:0)
    check(dynamic_peer.mappings.isEmpty && dynamic_peer.unverified_modifier_names.count == 3,
          "a reliable changed target revokes the entire previous configuration")
    let future_peer = PeerMatcher()
    future_peer.offset = 0; future_peer.rtt = 1000; future_peer.clock_at = 1_000_000
    future_peer.learned_window = "self-test-window"; future_peer.delays = [0,0,0]; future_peer.mappings = [1:(0,8)]
    future_peer.ingest([PeerInput(id:1,time_us:1_010_500,window:"self-test-window",kind:"key",key:25,action:"down",mods:1)],gap:false,now:1_010_000)
    let future_input = PeerObservation(time:1_010_000,kind:"key",key:25,action:"down",flags:0,modifier_class:nil)
    check(future_peer.decide(future_input,now:1_010_000,protected:0)?.flags == modifier_specs[0].aggregate|8,
          "remote clock midpoint uncertainty is accepted only within half RTT")
    future_peer.ingest([PeerInput(id:2,time_us:1_020_501,window:"self-test-window",kind:"key",key:25,action:"down",mods:1)],gap:false,now:1_020_000)
    var outside_future = future_input; outside_future.time = 1_020_000
    check(future_peer.decide(outside_future,now:1_020_000,protected:0) == nil && future_peer.last_decision_reason == "source_from_future",
          "remote evidence beyond clock uncertainty remains rejected")
    let pending_peer = PeerPublicationQueue()
    _ = pending_peer.append { future_peer.window_clear() }
    if case let .ready(batch,overflow) = pending_peer.take(input_callback:true) {
        for entry in batch { entry.body() }
        check(!overflow && !future_peer.ready,"queued revocation is applied before input correction")
    } else { check(false,"bounded queued revocation must be available without waiting") }
    let manual_peer = PeerMatcher()
    manual_peer.offset = 0; manual_peer.rtt = 1000; manual_peer.clock_at = 1_000_000
    manual_peer.configure_mapping(.default_mapping)
    check(!manual_peer.ready && manual_peer.manual_mapping == .default_mapping,
          "manual configuration does not prove input readiness")
    manual_peer.learned_window = "manual-window"; manual_peer.delays = [5000,5000,5000]
    manual_peer.ingest([PeerInput(id:1,time_us:1_010_000,window:"manual-window",kind:"key",key:25,action:"down",mods:1)],gap:false,now:1_010_000)
    let manual_flags = modifier_specs[0].aggregate|8
    let manual_decision = manual_peer.decide(PeerObservation(time:1_015_000,kind:"key",key:25,action:"down",flags:0),now:1_015_000,protected:0)
    check(manual_decision?.flags == manual_flags && manual_decision?.class_mask == 7,
          "explicit left mapping repairs ordinary shortcuts without mapping learning")
    check(!manual_peer.verified_mapping(1),"configured mapping is not diagnostic verification")
    manual_peer.ingest([],gap:true,now:1_020_000)
    check(!manual_peer.ready && manual_peer.manual_mapping == .default_mapping && manual_peer.mappings.count == 3,
          "source interruption retains settings while invalidating input evidence")
    check(!manual_peer.readiness_status_text.contains("0/3"),"manual status never requests mapping relearning")
    manual_peer.ingest([PeerInput(id:2,time_us:1_030_000,window:"manual-window",kind:"modifier",key:224,action:"down",mods:1)],gap:false,now:1_030_000)
    _ = manual_peer.decide(PeerObservation(time:1_035_000,kind:"modifier",key:0,action:"down",flags:modifier_specs[2].aggregate|1,modifier_class:2,side_bit:1),now:1_035_000,protected:0)
    check(manual_peer.manual_mapping_conflict,"reliable contradictory configured edge latches conflict")
    let conflict_mouse = manual_peer.decide(PeerObservation(time:1_040_000,kind:"button",key:1,action:"down",flags:manual_flags),now:1_040_000,protected:0)
    check(merge_remote_mouse_flags(offline_flags:0,correction:conflict_mouse) == manual_flags,
          "unmatched mouse retains original flags across offline merging during conflict")
    manual_peer.configure_mapping(nil,now:1_045_000)
    check(manual_peer.mappings.isEmpty && !manual_peer.manual_mapping_conflict,"automatic mode revokes manual assumptions")
    let keypad_test_domain = "local.uu-command-guard.self-test." + UUID().uuidString
    guard let keypad_test_preferences = UserDefaults(suiteName:keypad_test_domain) else {
        preconditionFailure("cannot create isolated keypad test preferences")
    }
    defer { keypad_test_preferences.removePersistentDomain(forName:keypad_test_domain) }
    check(keypad_plus_preference(keypad_test_preferences),"keypad repair defaults on")
    keypad_test_preferences.set(false,forKey:keypad_plus_preference_key)
    check(!keypad_plus_preference(UserDefaults(suiteName:keypad_test_domain)!),
          "saved keypad repair off is read by a new preferences instance")
    keypad_test_preferences.set(true,forKey:keypad_plus_preference_key)
    check(keypad_plus_preference(UserDefaults(suiteName:keypad_test_domain)!),
          "saved keypad repair on is read by a new preferences instance")
    func test_event_text(_ event: CGEvent) -> [UniChar] {
        var characters = [UniChar](repeating:0,count:4)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength:4,actualStringLength:&length,unicodeString:&characters)
        return Array(characters.prefix(length))
    }
    let keypad_decision = RemoteFlagDecision(flags:0,class_mask:0,keypad_plus_text:true)
    for key: Int64 in [24,69,81] {
        let event = CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(key),keyDown:true)!
        event.timestamp = 123_000; event.flags = .maskShift
        event.setIntegerValueField(.keyboardEventAutorepeat,value:1)
        let equals: [UniChar] = [0x3d]
        event.keyboardSetUnicodeString(stringLength:1,unicodeString:equals)
        check(apply_remote_keypad_plus(event:event,type:.keyDown,is_uu:true,enabled:true,decision:keypad_decision),
              "verified keypad text correction applies to supported Mac representations")
        check(test_event_text(event) == [0x2b],"keypad text becomes a single plus")
        check(event.type == .keyDown && event.timestamp == 123_000 && event.flags == .maskShift
              && event.getIntegerValueField(.keyboardEventKeycode) == key
              && event.getIntegerValueField(.keyboardEventAutorepeat) == 1,
              "keypad correction preserves key identity type timestamp flags and repeat")
    }
    let untouched_keypad = CGEvent(keyboardEventSource:nil,virtualKey:24,keyDown:true)!
    let equals: [UniChar] = [0x3d]
    untouched_keypad.keyboardSetUnicodeString(stringLength:1,unicodeString:equals)
    for request in [(false,true,CGEventType.keyDown,keypad_decision as RemoteFlagDecision?),
                    (true,false,.keyDown,keypad_decision), (true,true,.keyUp,keypad_decision),
                    (true,true,.keyDown,nil), (true,true,.keyDown,RemoteFlagDecision(flags:0,class_mask:0))] {
        check(!apply_remote_keypad_plus(event:untouched_keypad,type:request.2,is_uu:request.0,
                                       enabled:request.1,decision:request.3)
              && test_event_text(untouched_keypad) == [0x3d],
              "local disabled released and unproved input content remains untouched")
    }
    untouched_keypad.setIntegerValueField(.keyboardEventKeycode,value:9)
    check(!apply_remote_keypad_plus(event:untouched_keypad,type:.keyDown,is_uu:true,enabled:true,decision:keypad_decision),
          "other ordinary keys cannot use the keypad text exception")
    var transport_diagnostic = PeerTransportDiagnostics()
    transport_diagnostic.sent(result:-1,error:EHOSTUNREACH)
    check(transport_diagnostic.error_active && transport_diagnostic.last_send_errno == EHOSTUNREACH,
          "failed UDP send records its immediate errno")
    check(transport_diagnostic.status_text?.contains("65") == true,
          "unreachable UDP destination has a visible diagnostic status")
    transport_diagnostic.received(result:-1,error:EAGAIN)
    check(!transport_diagnostic.receive_error_active,
          "normal nonblocking receive does not invent a network error")
    transport_diagnostic.sent(result:1,error:0)
    check(!transport_diagnostic.error_active && transport_diagnostic.last_send_errno == EHOSTUNREACH,
          "successful retry clears active error while retaining diagnostic history")
    check(Set(transport_diagnostic.summary.keys) == Set(["counters","last_send_errno","last_receive_errno",
          "send_error_active","receive_error_active","send_successes","received_datagrams"]),
          "transport diagnostics contain only fixed metadata fields")
    print("PASS: \(checks) state/reconnect/log/input-source checks; no input taps created, input sources selected or events posted")
}

if CommandLine.arguments.contains("--self-test") {
    do { try self_test(); exit(0) } catch { fputs("Self-test failed: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--version") { print(guard_version); exit(0) }

let executable_url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
let is_app_bundle = Bundle.main.bundleIdentifier == "local.uu-command-guard"
let menu_bar_mode = !CommandLine.arguments.contains("--clean-logs") && (is_app_bundle
    || CommandLine.arguments.contains("--menu-bar") || CommandLine.arguments.contains("--menu-bar-preview")
    || CommandLine.arguments.contains("--mapping-settings-preview"))
let preview_mode = CommandLine.arguments.contains("--menu-bar-preview")
    || CommandLine.arguments.contains("--mapping-settings-preview")
let support_directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/UUCommandGuard")
let legacy_directory = is_app_bundle
    ? Bundle.main.bundleURL.deletingLastPathComponent() : executable_url.deletingLastPathComponent()
let log_directory = (is_app_bundle || menu_bar_mode ? support_directory : legacy_directory).appendingPathComponent("logs")
if menu_bar_mode {
    NSApplication.shared.setActivationPolicy(.accessory)
}
if preview_mode {
    let controller = MenuBarController(log_directory: log_directory, preview: true)
    controller.snapshot_provider = { MenuSnapshot(failure: "预览模式：未创建输入监听") }
    controller.quit_handler = { controller.close(); _exit(0) }
    var preview_mapping: PeerManualMapping? = PeerManualMapping.default_mapping
    controller.mapping_provider = { preview_mapping }
    controller.mapping_handler = { preview_mapping = $0 }
    controller.refresh()
    if CommandLine.arguments.contains("--mapping-settings-preview") { controller.open_mapping_settings() }
    NSApplication.shared.run()
    _exit(0)
}

func startup_failure(_ message: String) -> Never {
    if menu_bar_mode {
        let alert = NSAlert()
        alert.messageText = "UU 修补工具未启动"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    } else {
        fputs("\(message)\n", stderr)
    }
    exit(1)
}

// A shared lock excludes all new app/CLI instances. The adjacent legacy lock
// also excludes the old CLI when launching the app from the project directory.
do {
    try FileManager.default.createDirectory(at: support_directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
} catch {
    startup_failure("无法创建运行目录：\(error.localizedDescription)")
}
var lock_fds: [Int32] = []
let shared_lock = support_directory.appendingPathComponent(".guard.lock").path
let legacy_lock = legacy_directory.appendingPathComponent(".guard.lock").path
let legacy_executable = legacy_directory.appendingPathComponent("command-guard").path
var lock_paths = [shared_lock]
if (!is_app_bundle && !menu_bar_mode) || FileManager.default.fileExists(atPath: legacy_lock)
    || FileManager.default.isExecutableFile(atPath: legacy_executable) { lock_paths.append(legacy_lock) }
for path in lock_paths {
    let fd = open(path, O_CREAT | O_RDWR, mode_t(0o600))
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        if fd >= 0 { close(fd) }
        startup_failure("工具可能已经运行，或运行目录不可写。若旧版终端工具仍在运行，请先在原终端按 Ctrl+C 停止，再打开应用。")
    }
    lock_fds.append(fd)
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--clean-logs") {
    let cleaner = LegacyDiskLog(directory: log_directory, automatic: false, console_enabled: false)
    do {
        let removed = try cleaner.clean_now()
        print("已清理 \(removed) 条旧日志；未创建输入监听、网络连接或常驻日志任务。")
        fflush(stdout)
        _exit(0)
    } catch {
        fputs("日志清理失败：\(error)\n", stderr)
        _exit(1)
    }
}
let logger = DiagnosticLog(console_enabled: !menu_bar_mode)
var state = GuardState()
var session = SessionTracker()
var event_tap: CFMachPort?
var session_tap: CFMachPort?
var session_run_source: CFRunLoopSource?
var hid_keyboard_count: UInt64 = 0
var session_keyboard_count: UInt64 = 0
var corrected_count: UInt64 = 0
var last_snapshot = SystemSnapshot()
var sleeping = false
let process_queue = DispatchQueue(label: "uu-command-guard.process")
var process_check_pending = false
let remote_peer = RemotePeerBridge(status_notice: { message in
    logger.record("remote_status", ["message": message])
})

func reset_state(_ reason: String) {
    state.reset()
    remote_peer.reset(reason: reason)
    logger.record("reset", ["reason": reason])
    logger.notice("\(reason)：已进入状态同步；松开修饰键后将自动恢复。若持续等待，请停住鼠标，再按下并松开对应键。")
}

@Sendable func next_session(_ current: ProcessIdentity?) -> ProcessIdentity? {
    if let current = current, process_path(current.pid) == expected_path, process_identity(current.pid) == current {
        return current
    }
    return discover_uu()
}

@Sendable func update_session(_ next: ProcessIdentity?) {
    let previous_pid = session.current?.pid ?? 0
    if session.update(next) {
        reset_state("UU 服务连接变化")
        logger.record("session", ["previous_pid": previous_pid, "pid": next?.pid ?? 0,
                                  "start_seconds": String(next?.start_seconds ?? 0)])
        logger.notice(next.map { "已连接 UU PID=\($0.pid)，将自动同步按键状态。" } ?? "UU 服务暂不可用，工具继续等待并自动重连。")
    }
}

func refresh_session(background: Bool = false) {
    if !background { update_session(next_session(session.current)); return }
    guard !process_check_pending else { return }
    process_check_pending = true
    let current = session.current
    process_queue.async {
        let next = next_session(current)
        DispatchQueue.main.async {
            process_check_pending = false
            update_session(next)
        }
    }
}

func callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        reset_state(type == .tapDisabledByTimeout ? "监听超时" : "监听被禁用")
        if let tap = event_tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard monitored_event_types.contains(type) else { return Unmanaged.passUnretained(event) }
    let modifier_key = type == .flagsChanged ? event.getIntegerValueField(.keyboardEventKeycode) : nil
    if let key = modifier_key, !modifier_specs.contains(where: { key == $0.left_key || key == $0.right_key }) {
        return Unmanaged.passUnretained(event)
    }
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    let is_uu = session.matches(pid)
    // Only foreign modifier transitions are needed to protect local held keys.
    guard is_uu || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }
    let before = event.flags.rawValue
    let now = DispatchTime.now().uptimeNanoseconds
    let protected_mask = modifier_specs.indices.reduce(UInt8(0)) { mask, index in
        mask | ((state.modifiers[index].foreign_held || state.modifiers[index].needs_sync) ? UInt8(1 << index) : 0)
    }
    let remote_decision = is_uu ? remote_peer.observe(type: type, event: event, now_ns: now,
                                                    protected_mask: protected_mask) : nil
    if keyboard_types.contains(type) {
        if is_uu {
            hid_keyboard_count += 1
            if detailed_keyboard_diagnostics {
                var diagnostic = keyboard_diagnostic(event: event, stage: "hid", state: state, now: now)
                diagnostic["remote_reason"] = remote_peer.keyboard_decision_reason
                diagnostic["remote_protected_mask"] = protected_mask
                if diagnostic["reason"] as? String != "observed" { logger.record("keyboard", diagnostic) }
            }
            var changed = false
            if let correction = remote_decision, correction.flags != before {
                event.flags = CGEventFlags(rawValue: correction.flags)
                changed = true
                logger.record("remote_correction", ["event_type": type.rawValue,
                    "before": String(before, radix: 16), "after": String(correction.flags, radix: 16)])
            }
            if apply_remote_keypad_plus(event:event,type:type,is_uu:is_uu,
                                        enabled:remote_peer.keypad_plus_enabled,decision:remote_decision) {
                changed = true
                logger.record("keypad_plus_correction", ["event_type": type.rawValue])
            }
            if changed { corrected_count += 1 }
        }
        // Keypad + is the only optional text exception; keycode/type/time remain untouched.
    } else if type == .flagsChanged, let key = modifier_key {
        let reason = state.observe(is_uu: is_uu, pid: pid, key: key, flags: before, timestamp: event.timestamp)
        if reason != "unwatched" {
            logger.record("modifier", ["pid": pid, "uu": is_uu, "keycode": key,
                                       "callback_ns": String(now),
                                       "event_ns": String(event.timestamp), "flags": String(before, radix: 16),
                                       "reason": reason, "state": state.diagnostic()])
        }
    } else if mouse_types.contains(type) {
        let after = merge_remote_mouse_flags(offline_flags:state.corrected_flags(is_uu:is_uu,flags:before),correction:remote_decision)
        if before != after {
            event.flags = CGEventFlags(rawValue: after)
            corrected_count += 1
            logger.record("mouse", ["type": type.rawValue, "before": String(before, radix: 16),
                                    "after": String(after, radix: 16)])
        }
    }
    return Unmanaged.passUnretained(event)
}

func session_callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        logger.record("keyboard_observer_reset", ["stage": "session", "type": type.rawValue])
        if let tap = session_tap { CGEvent.tapEnable(tap: tap, enable: true) }
    } else if keyboard_types.contains(type) && session.matches(event.getIntegerValueField(.eventSourceUnixProcessID)) {
        session_keyboard_count += 1
        let diagnostic = keyboard_diagnostic(event: event, stage: "session", state: state,
                                            now: DispatchTime.now().uptimeNanoseconds)
        if diagnostic["reason"] as? String != "observed" { logger.record("keyboard", diagnostic) }
    }
    return Unmanaged.passUnretained(event)
}

var event_run_source: CFRunLoopSource?
var monitor_timer: Timer?
var wake_observer: NSObjectProtocol?
var sleep_observer: NSObjectProtocol?
var monitoring = false
var monitor_failure: String? = nil

@discardableResult
func start_monitoring() -> Bool {
    guard !monitoring else { return true }
    monitor_failure = nil
    if menu_bar_mode && !AXIsProcessTrusted() {
        monitor_failure = "未启动：需要辅助功能权限"
        logger.notice("请在辅助功能中添加并授权 UU 修补工具.app，再点击菜单中的重试启动监听。")
        return false
    }
    refresh_session()
    let mask = monitored_event_types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    event_tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: nil)
    guard let tap = event_tap else {
        monitor_failure = "输入监听创建失败"
        logger.notice(menu_bar_mode
            ? "无法创建输入监听。请检查应用的辅助功能权限，再点击重试启动监听。"
            : "无法创建输入监听。请在辅助功能中授权运行工具的终端，再重新启动。")
        return false
    }
    guard let run_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        monitor_failure = "监听运行源创建失败"
        logger.notice("无法创建监听运行源。")
        CFMachPortInvalidate(tap)
        event_tap = nil
        return false
    }
    event_run_source = run_source
    CFRunLoopAddSource(CFRunLoopGetMain(), run_source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    // Optional troubleshooting only: default operation uses a single input tap.
    if detailed_keyboard_diagnostics {
        let keyboard_mask = keyboard_types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        session_tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: keyboard_mask, callback: session_callback, userInfo: nil)
        if let observer = session_tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0) {
            session_run_source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: observer, enable: true)
            logger.notice("键盘诊断已配置：输入层 HID + 会话层 session，仅记录按下/松开、时间和修饰标记。")
        } else {
            if let observer = session_tap { CFMachPortInvalidate(observer) }
            session_tap = nil
            logger.notice("会话层键盘监听创建失败；保留 HID 层诊断。日志不能完整比较两层。")
        }
    }
    var last_service_check: UInt64 = 0
    var last_status: UInt64 = 0
    var last_console_status = ""
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
        guard !sleeping else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - last_service_check >= 1_000_000_000 {
            last_service_check = now
            refresh_session(background: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                reset_state("检测到监听未启用")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if let observer = session_tap, !CGEvent.tapIsEnabled(tap: observer) {
                logger.record("keyboard_observer_reset", ["stage": "session", "reason": "disabled"])
                CGEvent.tapEnable(tap: observer, enable: true)
            }
        }
        last_snapshot = system_snapshot()
        if session.current != nil && CGEvent.tapIsEnabled(tap: tap) {
            let recovered = state.reconcile(snapshot: last_snapshot, now: now)
            if !recovered.isEmpty { logger.notice("已自动同步并启用修正：\(recovered.joined(separator: "、"))") }
        }
        if now - last_status >= 5_000_000_000 {
            last_status = now
            let status = modifier_specs.indices.map { "\(modifier_specs[$0].name)=\(state.decision($0))" }.joined(separator: " ")
            let console = "PID=\(session.current?.pid ?? 0) \(status) 修正=\(corrected_count)"
            if console != last_console_status { logger.notice(console); last_console_status = console }
        }
    }
    monitor_timer = timer
    RunLoop.main.add(timer, forMode: .common)
    wake_observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            sleeping = false
            reset_state("系统唤醒")
            CGEvent.tapEnable(tap: tap, enable: true)
            if let observer = session_tap { CGEvent.tapEnable(tap: observer, enable: true) }
        }
    sleep_observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            sleeping = true
            reset_state("系统即将休眠")
        }
    monitoring = true
    logger.notice("修补已启动。先松开 Command、Option、Ctrl 并停住鼠标片刻，等待自动同步。")
    return true
}

var shutting_down = false
var menu_controller: MenuBarController?
var input_source_guard: InputSourceGuard?
func shutdown(_ code: Int32 = 0) -> Never {
    shutting_down = true
    remote_peer.stop()
    input_source_guard?.stop()
    monitor_timer?.invalidate()
    if let observer = wake_observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    if let observer = sleep_observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    if let tap = event_tap {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }
    if let tap = session_tap {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }
    if let source = event_run_source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let source = session_run_source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    menu_controller?.close()
    logger.notice("已停止；累计修正 \(corrected_count) 次。")
    logger.close()
    for fd in lock_fds { _ = flock(fd, LOCK_UN); close(fd) }
    // Bypass an implicit stdout flush if the old terminal output is blocked.
    _exit(code)
}

logger.notice("UU 修补工具 \(guard_version)；诊断仅保存在内存，按需导出。")
let input_preferences = input_source_preferences()
remote_peer.configure_keypad_plus(enabled:keypad_plus_preference(input_preferences))
let input_guard = InputSourceGuard(record: { kind, fields in logger.record(kind, fields) })
input_source_guard = input_guard
input_guard.set_enabled((input_preferences.object(forKey: "keep_wechat_input_source") as? Bool) ?? true)
input_guard.start()
func configure_remote_peer() -> String? {
    do {
        try remote_peer.configure(peer_ip: input_preferences.string(forKey: "remote_peer_ip") ?? "",
                                  enabled: (input_preferences.object(forKey: "remote_peer_enabled") as? Bool) ?? true)
        return nil
    } catch { return error.localizedDescription }
}
remote_peer.configure_mapping(stored_manual_mapping(input_preferences.array(forKey: "remote_manual_mapping")))
if let error = configure_remote_peer() { logger.notice(error) }
if menu_bar_mode {
    let controller = MenuBarController(log_directory: log_directory)
    menu_controller = controller
    controller.snapshot_provider = {
        MenuSnapshot(monitoring: monitoring, failure: monitor_failure, sleeping: sleeping,
                     uu_pid: session.current?.pid,
                     tap_enabled: event_tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                     session_tap_enabled: session_tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                     decisions: modifier_specs.indices.map { state.decision($0) }, corrected: corrected_count)
    }
    controller.retry_handler = { start_monitoring() }
    controller.quit_handler = { if !shutting_down { shutdown() } }
    controller.input_source_provider = { (input_guard.enabled, input_guard.status_text) }
    controller.input_source_handler = {
        let enabled = !input_guard.enabled
        input_preferences.set(enabled, forKey: "keep_wechat_input_source")
        input_guard.set_enabled(enabled)
    }
    controller.keypad_plus_provider = { remote_peer.keypad_plus_enabled }
    controller.keypad_plus_handler = {
        let enabled = !remote_peer.keypad_plus_enabled
        input_preferences.set(enabled, forKey:keypad_plus_preference_key)
        remote_peer.configure_keypad_plus(enabled:enabled)
    }
    controller.peer_provider = {
        ((input_preferences.object(forKey: "remote_peer_enabled") as? Bool) ?? true,
         remote_peer.status_text, remote_peer.corrected_count, remote_peer.skipped_count)
    }
    controller.peer_handler = {
        let enabled = (input_preferences.object(forKey: "remote_peer_enabled") as? Bool) ?? true
        input_preferences.set(!enabled, forKey: "remote_peer_enabled")
        if let error = configure_remote_peer() { logger.notice(error) }
    }
    controller.mapping_provider = { remote_peer.manual_mapping }
    controller.mapping_handler = { configuration in
        if let configuration = configuration {
            input_preferences.set(configuration.targets, forKey: "remote_manual_mapping")
        } else {
            input_preferences.removeObject(forKey: "remote_manual_mapping")
        }
        remote_peer.configure_mapping(configuration)
    }
    controller.peer_ip_provider = { input_preferences.string(forKey: "remote_peer_ip") ?? "" }
    controller.peer_ip_handler = { address in
        do {
            if input_preferences.string(forKey: "remote_peer_ip") == address,
               ((input_preferences.object(forKey: "remote_peer_enabled") as? Bool) ?? true) { return nil }
            try remote_peer.configure(peer_ip: address, enabled: true)
            input_preferences.set(address, forKey: "remote_peer_ip")
            input_preferences.set(true, forKey: "remote_peer_enabled")
            return nil
        } catch { return error.localizedDescription }
    }
    controller.export_provider = {
        ["version": guard_version, "diagnostics": logger.snapshot(), "remote": remote_peer.diagnostic_summary(),
         "corrected_events": corrected_count, "hid_keyboard": hid_keyboard_count, "session_keyboard": session_keyboard_count,
         "detailed_keyboard_diagnostics": detailed_keyboard_diagnostics,
         "input_source": input_guard.status_text, "state": state.diagnostic(),
         "tap_enabled": event_tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false]
    }
}
if !start_monitoring() && !menu_bar_mode { shutdown(1) }
menu_controller?.refresh()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stop_sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { if !shutting_down { shutdown() } }
    source.resume()
    return source
}
if !menu_bar_mode { logger.notice("终端模式：Ctrl+C 退出。") }
if session.current == nil { logger.notice("尚未发现 UU 服务，将自动等待；无需重启本工具。") }
logger.notice("离线修补 UU 鼠标；网络证据可靠时辅助修正 UU 键盘/鼠标修饰标记，不补发或重放输入。")
logger.notice("诊断仅在内存保留最近两分钟，最多512条/1 MiB；没有自动磁盘日志任务。")
if menu_bar_mode { NSApplication.shared.run() } else { CFRunLoopRun() }
shutdown()
