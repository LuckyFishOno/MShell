import CarveShared
import Foundation

// The desktop shell is independently implemented; readiness is not proof of an original App clone.
public enum AppFeature: CarveFeature {
    public static let id = "app"
    public static let contractSha256 = "0a9316053d6af033417a11379cc7ba4b2046601c90fce3d9f4cea5dec9c8300a"
    public static let dependsOn: [String] = ["file-transfer", "highlight", "master-password", "ssh", "terminal"]
    public static func run(_ request: FeatureRequest, dependencies: FeatureOutputs) throws -> FeatureResponse {
        if !request.payload.isEmpty {
            let object = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: String]
            guard object?["op"] == "describe" else { throw FeatureError.failed(id, "Use the desktop App for user actions, or {op:describe} for readiness.") }
        }
        return FeatureResponse(payload: #"{"ready":true,"interface":"native-macos","tabs":true,"sessionTree":"persistent-native-catalog","hostTrust":"explicit-pinned-key","credentials":"optional-encrypted-vault","console":"interactive-ssh-pty","fileTransfer":"sftp-v3","scope":"desktop-integration-readiness-not-original-equivalence"}"#)
    }
}
