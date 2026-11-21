// SFTP file transfer for the macOS port, built on the native SFTP client (SFTP.swift) over a SwiftNIO
// SSH session, per decisions/2026-10-20-mshell-ssh-library.md. No Citadel in the product. Independent
// reconstruction, not a port of Xtransport.exe. Chunking and progress are this implementation's choices.
import CarveShared
import Foundation
import NIOCore
import Ssh

public enum TransferError: Error, Equatable {
    case notConnected
    case localFileError(String)
    case remoteError(String)
}

public struct RemoteEntry: Equatable, Sendable {
    public var name: String
    public var size: UInt64?
    public var isDirectory: Bool
    public var permissions: UInt32?
    public var modified: Date?

    public init(name: String, size: UInt64? = nil, isDirectory: Bool, permissions: UInt32? = nil, modified: Date? = nil) {
        self.name = name; self.size = size; self.isDirectory = isDirectory; self.permissions = permissions; self.modified = modified
    }

    /// POSIX mode type bits: directory is S_IFDIR (0o040000) within the format mask 0o170000.
    public static func isDirectory(permissions: UInt32?) -> Bool {
        guard let p = permissions else { return false }
        return (p & 0o170000) == 0o040000
    }
}

public struct TransferProgress: Equatable, Sendable {
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64?
    /// 0...1 when the total is known, otherwise nil.
    public var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1.0, Double(bytesTransferred) / Double(total))
    }
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

/// One SFTP session over an SSH connection. `implemented-ok` only means the wrapper built; it is not
/// evidence of matching Xshell's transfer behavior.
public actor SFTPTransfer {
    public static let chunkSize = 32 * 1024
    private let sftp: SFTPSession

    init(sftp: SFTPSession) { self.sftp = sftp }

    public static func open(_ session: SSHSession) async throws -> SFTPTransfer {
        do { return SFTPTransfer(sftp: try await SFTPSession.start(session)) }
        catch { throw TransferError.remoteError(String(describing: error)) }
    }

    public func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        try await readDirectory(path).entries
    }

    public func readDirectory(_ path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        do {
            let resolved = try await sftp.realPath(path)
            let handle = try await sftp.openDir(resolved)
            var entries: [RemoteEntry] = []
            do {
                while let names = try await sftp.readDir(handle) {
                    for name in names where name.filename != "." && name.filename != ".." {
                        entries.append(RemoteEntry(name: name.filename, size: name.size,
                            isDirectory: RemoteEntry.isDirectory(permissions: name.permissions), permissions: name.permissions,
                            modified: name.modified))
                    }
                }
            } catch {
                try? await sftp.close(handle)
                throw error
            }
            try await sftp.close(handle)
            return (resolved, entries.sorted { $0.name < $1.name })
        } catch {
            throw TransferError.remoteError(String(describing: error))
        }
    }

    /// Requests kept in flight at once. One request per round trip made large files crawl over distant links.
    public static let pipelineDepth = 16

    /// Streams `remotePath` into `localURL` with several reads in flight. Stops with `CancellationError` when the
    /// task is cancelled.
    public func download(remotePath: String, to localURL: URL, progress: ProgressHandler? = nil) async throws {
        let total = try? await sftp.stat(remotePath)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: localURL) else { throw TransferError.localFileError("cannot write \(localURL.path)") }
        defer { try? out.close() }
        do {
            let handle = try await sftp.open(remotePath, flags: .read)
            do {
                var offset: UInt64 = 0
                var finished = false
                while !finished {
                    try Task.checkCancellation()
                    // Read a window of chunks at once, then write them in order. A short chunk is completed with
                    // follow-up reads, since a server may return less than asked before the end of the file.
                    let starts = (0..<Self.pipelineDepth).map { offset + UInt64($0 * Self.chunkSize) }
                    let chunks = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                        for (index, start) in starts.enumerated() {
                            group.addTask { (index, try await self.readFully(handle, at: start, length: Self.chunkSize)) }
                        }
                        var results = [Data](repeating: Data(), count: starts.count)
                        for try await (index, data) in group { results[index] = data }
                        return results
                    }
                    for chunk in chunks {
                        if !chunk.isEmpty { try out.write(contentsOf: chunk); offset += UInt64(chunk.count) }
                        if chunk.count < Self.chunkSize { finished = true; break }
                    }
                    progress?(TransferProgress(bytesTransferred: offset, totalBytes: total ?? nil))
                }
                try await sftp.close(handle)
            } catch { try? await sftp.close(handle); throw error }
        } catch let e as TransferError { throw e } catch let e as CancellationError { throw e }
        catch { throw TransferError.remoteError(String(describing: error)) }
    }

    /// Reads up to `length` bytes at `offset`, asking again after a short reply. Empty at the end of the file.
    private func readFully(_ handle: ByteBuffer, at offset: UInt64, length: Int) async throws -> Data {
        var data = Data()
        while data.count < length {
            guard let chunk = try await sftp.read(handle, offset: offset + UInt64(data.count), length: UInt32(length - data.count)) else { break }
            var buffer = chunk
            guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { break }
            data.append(contentsOf: bytes)
        }
        return data
    }

    /// Streams `localURL` to `remotePath` with several writes in flight, reading the file a window at a time.
    public func upload(localURL: URL, to remotePath: String, progress: ProgressHandler? = nil) async throws {
        guard let input = try? FileHandle(forReadingFrom: localURL) else { throw TransferError.localFileError("cannot read \(localURL.path)") }
        defer { try? input.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value
        do {
            let handle = try await sftp.open(remotePath, flags: [.write, .create, .truncate])
            do {
                var offset: UInt64 = 0
                if total == 0 { progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0)) }
                while true {
                    try Task.checkCancellation()
                    var window: [(UInt64, Data)] = []
                    for _ in 0..<Self.pipelineDepth {
                        guard let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                        window.append((offset, data)); offset += UInt64(data.count)
                    }
                    if window.isEmpty { break }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (start, data) in window {
                            group.addTask { try await self.sftp.write(handle, offset: start, data: ByteBuffer(bytes: data)) }
                        }
                        try await group.waitForAll()
                    }
                    progress?(TransferProgress(bytesTransferred: offset, totalBytes: total ?? offset))
                }
                try await sftp.close(handle)
            } catch { try? await sftp.close(handle); throw error }
        } catch let e as TransferError { throw e } catch let e as CancellationError { throw e }
        catch { throw TransferError.remoteError(String(describing: error)) }
    }

    /// Attributes of a remote path, following links; nil when it does not exist.
    public func entry(at path: String) async throws -> RemoteEntry? {
        do {
            let attributes = try await sftp.attributes(path)
            return RemoteEntry(name: (path as NSString).lastPathComponent, size: attributes.size,
                               isDirectory: RemoteEntry.isDirectory(permissions: attributes.permissions),
                               permissions: attributes.permissions, modified: attributes.modified)
        } catch SFTPWireError.status(let code, _) where code == 2 { return nil } // SSH_FX_NO_SUCH_FILE
        catch { throw TransferError.remoteError(String(describing: error)) }
    }

    public func resolve(_ path: String) async throws -> String {
        do { return try await sftp.realPath(path) } catch { throw TransferError.remoteError(String(describing: error)) }
    }

    public func makeDirectory(_ path: String) async throws {
        do { try await sftp.mkdir(path) } catch { throw TransferError.remoteError(String(describing: error)) }
    }
    public func removeFile(_ path: String) async throws {
        do { try await sftp.remove(path) } catch { throw TransferError.remoteError(String(describing: error)) }
    }
    public func removeDirectory(_ path: String) async throws {
        do { try await sftp.rmdir(path) } catch { throw TransferError.remoteError(String(describing: error)) }
    }
    public func rename(from: String, to: String) async throws {
        do { try await sftp.rename(from, to) } catch { throw TransferError.remoteError(String(describing: error)) }
    }
    public func close() async throws { try await sftp.close() }
}

// Feature entry: live SFTP needs a reachable server, so the self-test reports readiness only.
public enum FileTransferFeature: CarveFeature {
    public static let id = "file-transfer"
    public static let contractSha256 = "8ca3aa058410706421eab53c4e6b6271c3c454be01256bb1976cab0bb2ce0243"
    public static let dependsOn: [String] = ["ssh"]

    public static func run(_ request: FeatureRequest, dependencies: FeatureOutputs) throws -> FeatureResponse {
        if request.payload.isEmpty {
            return FeatureResponse(payload: #"{"ready":true,"protocol":"SFTP v3 (native NIOSSH)","operations":["list","download","upload","mkdir","remove","rmdir","rename"],"chunkSize":32768,"note":"live transfer not exercised in self-test"}"#)
        }
        throw FeatureError.failed(id, "SFTP transfers run through SFTPTransfer at the app layer, not the synchronous feature entry")
    }
}
