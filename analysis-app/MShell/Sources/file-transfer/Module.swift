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
                            isDirectory: RemoteEntry.isDirectory(permissions: name.permissions), permissions: name.permissions))
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

    public func download(remotePath: String, to localURL: URL, progress: ProgressHandler? = nil) async throws {
        let total = try? await sftp.stat(remotePath)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: localURL) else { throw TransferError.localFileError("cannot write \(localURL.path)") }
        defer { try? out.close() }
        do {
            let handle = try await sftp.open(remotePath, flags: .read)
            var offset: UInt64 = 0
            while let chunk = try await sftp.read(handle, offset: offset, length: UInt32(Self.chunkSize)) {
                let n = chunk.readableBytes
                if n == 0 { break }
                var c = chunk
                if let bytes = c.readBytes(length: n) { try out.write(contentsOf: Data(bytes)) }
                offset += UInt64(n)
                progress?(TransferProgress(bytesTransferred: offset, totalBytes: total ?? nil))
                if n < Self.chunkSize { break }
            }
            try await sftp.close(handle)
        } catch let e as TransferError { throw e } catch { throw TransferError.remoteError(String(describing: error)) }
    }

    public func upload(localURL: URL, to remotePath: String, progress: ProgressHandler? = nil) async throws {
        guard let data = try? Data(contentsOf: localURL) else { throw TransferError.localFileError("cannot read \(localURL.path)") }
        let total = UInt64(data.count)
        do {
            let handle = try await sftp.open(remotePath, flags: [.write, .create, .truncate])
            var offset = 0
            if data.isEmpty { progress?(TransferProgress(bytesTransferred: 0, totalBytes: 0)) }
            while offset < data.count {
                let end = min(offset + Self.chunkSize, data.count)
                try await sftp.write(handle, offset: UInt64(offset), data: ByteBuffer(bytes: data[offset..<end]))
                offset = end
                progress?(TransferProgress(bytesTransferred: UInt64(offset), totalBytes: total))
            }
            try await sftp.close(handle)
        } catch let e as TransferError { throw e } catch { throw TransferError.remoteError(String(describing: error)) }
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
