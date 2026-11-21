import Foundation
import LocalPTY
import Darwin

/// A real controlling PTY gives local shells job control, signals and terminal sizing.
final class LocalShell {
    private let handle: FileHandle
    private let pid: Int32
    private let writes = DispatchQueue(label: "MShell.local-input")
    private var stopped = false
    private let reader: DispatchSourceRead
    init(rows: Int, columns: Int, output: @escaping @Sendable (Data) -> Void) throws {
        var descriptor: Int32 = -1
        let candidate = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shell = FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
        pid = mshell_spawn(shell, FileManager.default.homeDirectoryForCurrentUser.path, Int32(rows), Int32(columns), &descriptor)
        guard pid > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "MShell.local-output"))
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { output(Data(buffer.prefix(count))) }
            else if count == 0 || errno != EINTR { self.reader.cancel(); output(Data()) }
        }
        let file = handle, queue = writes
        reader.setCancelHandler { queue.async { try? file.close() } }
        reader.resume()
    }
    func send(_ bytes: [UInt8]) {
        let handle = handle
        writes.async { try? handle.write(contentsOf: Data(bytes)) }
    }
    func resize(rows: Int, columns: Int) { mshell_resize(handle.fileDescriptor, Int32(rows), Int32(columns)) }
    func close() {
        guard !stopped else { return }; stopped = true
        reader.cancel(); mshell_stop(pid)

    }
    deinit { close() }
}
