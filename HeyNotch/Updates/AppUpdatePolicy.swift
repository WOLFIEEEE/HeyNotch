import Foundation

/// Release configuration, deliberately independent of Sparkle's saved user preferences.
struct AppUpdatePolicy: Sendable {
    static let current = AppUpdatePolicy(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let allowsUpdates: Bool

    init(infoDictionary: [String: Any]) {
        guard infoDictionary["HeyNotchUpdatesEnabled"] as? Bool == true,
              let feed = infoDictionary["SUFeedURL"] as? String,
              let url = URLComponents(string: feed),
              url.scheme == "https",
              url.host?.lowercased() == "wolfieeee.github.io",
              url.path == "/HeyNotch/appcast.xml",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let publicKey = infoDictionary["SUPublicEDKey"] as? String,
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32 else {
            allowsUpdates = false
            return
        }

        // Enabling a release still requires verifying ownership of the signing key
        // and testing the signed appcast. Syntax checks cannot establish ownership.
        allowsUpdates = true
    }
}
