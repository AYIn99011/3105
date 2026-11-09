import Foundation

/// Adaptation: worse_query requires an App Group owned by the caller.
/// After self-signing, the groups available to the app are whatever the
/// signing profile granted, so discover them from the embedded
/// provisioning profile instead of hardcoding an identifier, and pick
/// the first one whose container is actually reachable.
enum AppGroupDiscovery {
    private static var cachedGroup: String?
    private static var didLogCandidates = false

    static func workingGroupIdentifier() -> String? {
        if let cached = cachedGroup { return cached }
        let candidates = candidateGroupIdentifiers()
        if !didLogCandidates {
            didLogCandidates = true
            log("groups: candidates from provisioning profile: \(candidates)")
        }
        for group in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                log("groups: selected accessible app group \(group)")
                cachedGroup = group
                return group
            }
        }
        log("groups: no accessible app group found")
        return nil
    }

    static func candidateGroupIdentifiers() -> [String] {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL),
              let plist = provisioningPlist(from: data),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }

    private static func provisioningPlist(from data: Data) -> [String: Any]? {
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let plistEnd = data.range(of: Data("</plist>".utf8)) else {
            return nil
        }
        let xml = data[xmlStart.lowerBound..<plistEnd.upperBound]
        let parsed = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
        return parsed as? [String: Any]
    }
}
