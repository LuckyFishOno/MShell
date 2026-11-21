import AppKit
import Darwin
import Foundation
import Profiles

// Model support for the Xshell-style and MobaXterm-style layouts: the address bar, the compose bar,
// following the shell's folder in the SFTP browser, and the host monitoring bar.

extension WorkspaceModel {
    /// Opens what was typed in the address bar: `ssh://user@host:port`, `user@host[:port]`, or a bare host.
    /// A full target connects at once; a bare host opens a tab with the connection form filled in.
    @discardableResult func openAddress(_ input: String) -> SessionTab? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("ssh://") { text = String(text.dropFirst(6)) }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if let target = SavedConnection.quickTarget(text) {
            return openSaved(SessionTreeNode(name: "\(target.username)@\(target.host)", connection: target))
        }
        guard !text.contains("@"), !text.contains(where: \.isWhitespace) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return nil }
        if parts.count == 2 { guard let port = Int(parts[1]), (1...65535).contains(port) else { return nil } }
        let tab = addTab()
        tab.host = String(host)
        if parts.count == 2 { tab.port = String(parts[1]) }
        tab.title = String(host)
        return tab
    }

    /// Tabs that can take typed input right now.
    var composeTargets: [SessionTab] { tabs.filter(\.terminalReady) }

    /// Sends one line from the compose bar, followed by Return, to the selected terminal or to every open terminal.
    @discardableResult func sendCompose(_ line: String, toAll: Bool) -> Int {
        guard !line.isEmpty, let bytes = TerminalKeyboard.pasteBytes(line, bracketed: false) else { return 0 }
        let targets = toAll ? composeTargets : (selected.map { $0.terminalReady ? [$0] : [] } ?? [])
        var sent = 0
        for tab in targets where enqueueTerminalInput(tab, bytes: bytes + [0x0D]) { sent += 1 }
        return sent
    }

    /// Installs a prompt hook in the remote shell so it reports its folder after every command,
    /// the way MobaXterm's "Follow terminal folder" works. The leading space keeps it out of most shell histories.
    func reportTerminalFolder(_ tab: SessionTab) {
        guard !tab.isLocal, tab.terminalReady else { return }
        let hook = #" _mshell_cwd(){ printf '\033]7;file://%s%s\007' "${HOSTNAME:-$HOST}" "$PWD"; }; if [ -n "$ZSH_VERSION" ]; then precmd_functions+=(_mshell_cwd); else PROMPT_COMMAND="_mshell_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"; fi"#
        enqueueTerminalInput(tab, bytes: Array(hook.utf8) + [0x0D])
    }
}

/// Where the shell in a tab is, from an OSC 7 report or, failing that, a `user@host: path` window title.
enum TerminalFolder {
    static func current(screenDirectory: String?, title: String) -> String? {
        screenDirectory ?? fromTitle(title)
    }

    /// Reads the folder from titles such as `me@web: ~/site` (the default on Debian and Ubuntu).
    /// Paths under the home folder become relative, which SFTP resolves from the login folder.
    static func fromTitle(_ title: String) -> String? {
        guard let at = title.firstIndex(of: "@"), let colon = title[at...].firstIndex(of: ":") else { return nil }
        let path = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if path == "~" { return "." }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return path.hasPrefix("/") ? path : nil
    }
}

// MARK: - Host monitoring

/// Raw counters from one reading. Rates and percentages come from two readings.
struct HostSample: Equatable {
    var cpuTotal: UInt64?, cpuIdle: UInt64?
    var memoryTotal: UInt64?, memoryAvailable: UInt64?
    var diskSize: UInt64?, diskUsed: UInt64?
    var uptime: TimeInterval?
    var users: Int?
    var received: UInt64?, sent: UInt64?
    var time: TimeInterval = 0

    /// The command run on a Linux server. Each section is marked so a missing tool leaves the others intact.
    static let remoteCommand = "echo @stat; head -n1 /proc/stat 2>/dev/null; echo @mem; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null; echo @disk; df -Pk / 2>/dev/null | tail -n1; echo @up; cat /proc/uptime 2>/dev/null; echo @users; who 2>/dev/null | wc -l; echo @net; cat /proc/net/dev 2>/dev/null"

    static func parse(remote output: String, time: TimeInterval) -> HostSample {
        var sample = HostSample(time: time)
        var section = ""
        var received: UInt64 = 0, sent: UInt64 = 0, sawInterface = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@") { section = line; continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch section {
            case "@stat":
                guard fields.first == "cpu" else { continue }
                let values = fields.dropFirst().compactMap { UInt64($0) }
                guard values.count >= 4 else { continue }
                // user nice system idle iowait irq softirq steal; idle time includes iowait.
                sample.cpuTotal = values.prefix(8).reduce(0, +)
                sample.cpuIdle = values[3] + (values.count > 4 ? values[4] : 0)
            case "@mem":
                guard fields.count >= 2, let kib = UInt64(fields[1]) else { continue }
                if fields[0] == "MemTotal:" { sample.memoryTotal = kib * 1024 }
                if fields[0] == "MemAvailable:" { sample.memoryAvailable = kib * 1024 }
            case "@disk":
                guard fields.count >= 4, let size = UInt64(fields[1]), let used = UInt64(fields[2]) else { continue }
                sample.diskSize = size * 1024; sample.diskUsed = used * 1024
            case "@up":
                sample.uptime = fields.first.flatMap { TimeInterval($0) }
            case "@users":
                sample.users = fields.first.flatMap { Int($0) }
            case "@net":
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let counters = line[line.index(after: colon)...].split(separator: " ").compactMap { UInt64($0) }
                guard name != "lo", counters.count >= 9 else { continue }
                received += counters[0]; sent += counters[8]; sawInterface = true
            default: continue
            }
        }
        if sawInterface { sample.received = received; sample.sent = sent }
        return sample
    }

    /// Reads this Mac's counters for a local terminal.
    static func local(time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> HostSample {
        var sample = HostSample(time: time)
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let cpuResult = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3].map(UInt64.init)
            sample.cpuTotal = ticks.reduce(0, +)
            sample.cpuIdle = ticks[Int(CPU_STATE_IDLE)]
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        sample.memoryTotal = total
        if vmResult == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let used = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
            sample.memoryAvailable = total > used ? total - used : 0
        }
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let size = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
            sample.diskSize = UInt64(size); sample.diskUsed = UInt64(max(0, Int64(size) - free))
        }
        sample.uptime = ProcessInfo.processInfo.systemUptime
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0, let first = interfaces {
            var received: UInt64 = 0, sent: UInt64 = 0
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data,
                      String(cString: entry.ifa_name) != "lo0" else { continue }
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(counters.ifi_ibytes); sent += UInt64(counters.ifi_obytes)
            }
            freeifaddrs(interfaces)
            sample.received = received; sample.sent = sent
        }
        return sample
    }
}

/// What the monitoring bar shows.
struct HostStats: Equatable {
    var cpu: Double?
    var memoryUsed: UInt64?, memoryTotal: UInt64?
    var diskUsed: UInt64?, diskSize: UInt64?
    var uptime: TimeInterval?
    var users: Int?
    var receiveRate: Double?, sendRate: Double?

    init(_ current: HostSample, previous: HostSample?) {
        if let total = current.cpuTotal, let idle = current.cpuIdle, let oldTotal = previous?.cpuTotal, let oldIdle = previous?.cpuIdle,
           total > oldTotal, idle >= oldIdle {
            let busy = Double(total - oldTotal) - Double(idle - oldIdle)
            cpu = min(100, max(0, busy / Double(total - oldTotal) * 100))
        }
        if let total = current.memoryTotal, let available = current.memoryAvailable {
            memoryTotal = total; memoryUsed = total > available ? total - available : 0
        }
        diskSize = current.diskSize; diskUsed = current.diskUsed
        uptime = current.uptime; users = current.users
        if let previous, current.time > previous.time {
            let seconds = current.time - previous.time
            // Counters can wrap or reset; skip a reading that went backwards.
            if let now = current.received, let then = previous.received, now >= then { receiveRate = Double(now - then) / seconds }
            if let now = current.sent, let then = previous.sent, now >= then { sendRate = Double(now - then) / seconds }
        }
    }

    var isEmpty: Bool { cpu == nil && memoryTotal == nil && diskSize == nil && uptime == nil }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = value, unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(Int(value)) B" : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// Polls the selected tab's host every few seconds while the monitoring bar is visible.
@MainActor final class HostMonitor: ObservableObject {
    @Published private(set) var stats: HostStats?
    @Published private(set) var unavailable = false
    private var task: Task<Void, Never>?
    private var watched: (id: UUID, connected: Bool, local: Bool)?

    func watch(_ tab: SessionTab?) {
        let key = tab.map { (id: $0.id, connected: $0.connected || $0.isLocal, local: $0.isLocal) }
        guard key?.id != watched?.id || key?.connected != watched?.connected else { return }
        watched = key
        task?.cancel(); stats = nil; unavailable = false
        guard let tab, let key, key.connected else { return }
        task = Task { @MainActor [weak self, weak tab] in
            var previous: HostSample?
            while !Task.isCancelled {
                guard let tab else { return }
                let sample: HostSample?
                if tab.isLocal {
                    sample = await Task.detached(priority: .utility) { HostSample.local() }.value
                } else if let session = tab.session {
                    let output = try? await session.runCommand(HostSample.remoteCommand, maxResponseBytes: 65536, timeoutSeconds: 10)
                    sample = output.map { HostSample.parse(remote: $0, time: ProcessInfo.processInfo.systemUptime) }
                } else { sample = nil }
                guard !Task.isCancelled, let self else { return }
                if let sample {
                    let stats = HostStats(sample, previous: previous)
                    self.stats = stats; self.unavailable = stats.isEmpty
                    previous = sample
                } else { self.unavailable = true }
                try? await Task.sleep(nanoseconds: previous == nil || self.stats?.cpu == nil ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }

    func stop() { task?.cancel(); task = nil; watched = nil }
}

/// Caps Lock state for the status bar.
@MainActor final class KeyLockState: ObservableObject {
    @Published private(set) var capsLock = NSEvent.modifierFlags.contains(.capsLock)
    nonisolated(unsafe) private var monitor: Any?
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { if self?.capsLock != on { self?.capsLock = on } }
            return event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
