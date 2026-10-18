import Foundation
#if DEBUG
import Darwin
#endif

/// Debug-only, bounded diagnostics. Never records note contents, endpoints,
/// identifiers, or credentials. The previous launch survives a memory kill.
final class MemoryDiagnostics {
    static let shared = MemoryDiagnostics()

    final class Activity {
        private let name: String
        private let lock = NSLock()
        private var ended = false

        fileprivate init(_ name: String, details: String) {
            self.name = name
            MemoryDiagnostics.shared.change(name, delta: 1, details: details)
        }

        func end() {
            lock.lock()
            guard !ended else { lock.unlock(); return }
            ended = true
            lock.unlock()
            MemoryDiagnostics.shared.change(name, delta: -1, details: "")
        }

        deinit { end() }
    }

    static func begin(_ name: String, details: String = "") -> Activity {
        Activity(name, details: details)
    }

    static func record(_ event: String) {
        shared.write(event)
    }

    #if DEBUG
    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var timer: DispatchSourceTimer?
    private var file: FileHandle?
    private var writtenBytes = 0

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        if let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let url = root.appendingPathComponent("BetterNotes-memory.log")
            let previous = root.appendingPathComponent("BetterNotes-memory-previous.log")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try? FileHandle(forWritingTo: url)
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "BetterNotes.memory", qos: .utility))
        source.schedule(deadline: .now(), repeating: 1)
        source.setEventHandler { [weak self] in self?.write("sample") }
        timer = source
        source.resume()
    }

    private func change(_ name: String, delta: Int, details: String) {
        lock.lock()
        let count = max(0, (active[name] ?? 0) + delta)
        if count == 0 { active.removeValue(forKey: name) }
        else { active[name] = count }
        writeLocked("\(delta > 0 ? "begin" : "end") \(name) \(details)")
        lock.unlock()
    }

    private func write(_ event: String) {
        lock.lock()
        writeLocked(event)
        lock.unlock()
    }

    private func writeLocked(_ event: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let memory = result == KERN_SUCCESS ? info.phys_footprint / 1_048_576 : 0
        let activities = active.keys.sorted().map { "\($0)=\(active[$0]!)" }.joined(separator: ",")
        let line = "[Memory] uptime=\(Int(ProcessInfo.processInfo.systemUptime)) MiB=\(memory) \(event) active=[\(activities)]\n"
        print(line, terminator: "")
        guard let file, let data = line.data(using: .utf8) else { return }
        if writtenBytes + data.count > 1_048_576 {
            try? file.truncate(atOffset: 0)
            try? file.seek(toOffset: 0)
            writtenBytes = 0
        }
        try? file.write(contentsOf: data)
        writtenBytes += data.count
    }
    #else
    func start() { }
    private func change(_ name: String, delta: Int, details: String) { }
    private func write(_ event: String) { }
    #endif
}
