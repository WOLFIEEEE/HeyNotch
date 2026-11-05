import Foundation
import Security

enum XPCPeerTrust {
    static let appIdentifier = "com.wolfieeee.heynotch"
    static let helperIdentifier = "com.wolfieeee.heynotch.HeyNotchXPCHelper"

    /// Use the installed peer's designated requirement, including its signing team
    /// (or exact code hash for a local ad-hoc build). Never trust a bundle ID alone.
    static func requirement(for bundleURL: URL, identifier: String) -> String? {
        guard Bundle(url: bundleURL)?.bundleIdentifier == identifier else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { return nil }
        return text as String
    }
}
