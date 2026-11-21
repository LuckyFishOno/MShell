import XCTest
import CarveShared
@testable import FileTransfer

final class FileTransferFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() { XCTAssertEqual(FileTransferFeature.id, "file-transfer"); XCTAssertEqual(FileTransferFeature.contractSha256, "8ca3aa058410706421eab53c4e6b6271c3c454be01256bb1976cab0bb2ce0243") }

    func testDirectoryBitFromPermissions() {
        XCTAssertTrue(RemoteEntry.isDirectory(permissions: 0o040755))
        XCTAssertFalse(RemoteEntry.isDirectory(permissions: 0o100644))  // regular file
        XCTAssertFalse(RemoteEntry.isDirectory(permissions: 0o120777))  // symlink
        XCTAssertFalse(RemoteEntry.isDirectory(permissions: nil))
    }

    func testProgressFraction() {
        XCTAssertEqual(TransferProgress(bytesTransferred: 50, totalBytes: 200).fraction, 0.25)
        XCTAssertNil(TransferProgress(bytesTransferred: 50, totalBytes: nil).fraction)
        XCTAssertNil(TransferProgress(bytesTransferred: 0, totalBytes: 0).fraction)
        XCTAssertEqual(TransferProgress(bytesTransferred: 300, totalBytes: 200).fraction, 1.0, "clamped at 1.0")
    }

    func testFeatureReadinessAndAppLayerRefusal() throws {
        let ready = try FileTransferFeature.run(FeatureRequest(payload: ""), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(ready.payload.contains("\"ready\":true"))
        XCTAssertTrue(ready.payload.contains("SFTP"))
        XCTAssertThrowsError(try FileTransferFeature.run(FeatureRequest(payload: #"{"op":"upload"}"#), dependencies: FeatureOutputs([:])))
    }
}
