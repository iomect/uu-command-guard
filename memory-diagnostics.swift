import Foundation
import Darwin

// Normal operation never creates a writer, retention timer or log directory.
final class DiagnosticLog {
    private struct Entry {
        let time: Double
        let bytes: Int
        let row: [String: Any]
    }
    private let lock = NSLock()
    private let console_queue = DispatchQueue(label: "uu-command-guard.console")
    private var console_pending: [String] = []
    private var console_busy = false
    private var entries: [Entry] = []
    private var byte_count = 0
    private var dropped = 0
    private var sequence: UInt64 = 0
    private let console_enabled: Bool
    private let row_limit: Int
    private let byte_limit: Int
    private let retention: Double
    private let run = UUID().uuidString

    init(console_enabled: Bool = false, row_limit: Int = 512, byte_limit: Int = 1_048_576,
         retention: Double = 120) {
        self.console_enabled = console_enabled
        self.row_limit = max(1, min(row_limit, 512))
        self.byte_limit = max(256, min(byte_limit, 1_048_576))
        self.retention = min(120, max(0, retention))
    }

    // Conservative retained-memory accounting; no JSON serialization in taps.
    private func retained_size(_ value: Any, depth: Int = 0) -> Int {
        if depth > 8 { return byte_limit + 1 }
        if let text = value as? String { return 64 + text.utf8.count * 4 }
        if let rows = value as? [String: Any] {
            return rows.reduce(96) { $0 + retained_size($1.key, depth: depth + 1) + retained_size($1.value, depth: depth + 1) }
        }
        if let rows = value as? [Any] {
            return rows.reduce(64) { $0 + retained_size($1, depth: depth + 1) }
        }
        return 64
    }
    private func prune(_ now: Double) {
        while let first = entries.first, first.time < now - retention {
            byte_count -= first.bytes
            entries.removeFirst()
        }
    }
    func record(_ kind: String, _ fields: [String: Any] = [:], now: Double = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000) {
        var row = fields
        row["kind"] = kind
        row["time_unix"] = Date().timeIntervalSince1970
        row["run"] = run
        let bytes = retained_size(row) + 128
        lock.lock()
        defer { lock.unlock() }
        prune(now)
        sequence += 1
        guard bytes <= byte_limit else { dropped += 1; return }
        row["seq"] = sequence
        while !entries.isEmpty && (entries.count >= row_limit || byte_count + bytes > byte_limit) {
            byte_count -= entries.removeFirst().bytes
            dropped += 1
        }
        entries.append(Entry(time: now, bytes: bytes, row: row))
        byte_count += bytes
    }
    func notice(_ message: String) {
        record("notice", ["message": message])
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
                let message = self.console_pending.removeFirst()
                self.lock.unlock()
                print(message)
                fflush(stdout)
            }
        }
    }
    func snapshot(now: Double = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        prune(now)
        return ["retention_seconds": retention, "rows": entries.map { $0.row },
                "retained_rows": entries.count, "estimated_bytes": byte_count, "dropped": dropped]
    }
    func flush() {} // Compatibility: memory records are already available.
    @discardableResult func close(timeout: DispatchTimeInterval = .seconds(1)) -> Bool { true }
}
