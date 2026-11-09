import Foundation
import Darwin
import UIKit

// MARK: - Models

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
    let icon: UIImage?

    var id: String { bundleID }
    var displayName: String {
        AppDisplayNamePolicy.resolve(bundleID: bundleID, candidates: [name])
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct FileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let childCount: Int?

    var id: String { path }
    var sizeText: String {
        guard size >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date? = nil,
        childCount: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.childCount = childCount
    }

    func withDirectorySummary(_ summary: FileBrowserDirectorySummary?) -> FileEntry {
        FileEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: summary?.byteCount ?? -2,
            modifiedAt: modifiedAt,
            childCount: summary?.childCount
        )
    }
}

// MARK: - Store

enum ContainerStore {
    static let appDataRoot = "/var/mobile/Containers/Data/Application"
    static let systemDataRoot = "/var/mobile/Containers/Data/System"
    private static var shouldUseBadQuery: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }
    private static let applicationBundleRoots: [(path: String, nested: Bool)] = [
        ("/var/containers/Bundle/Application", true),
        ("/Applications", false),
        ("/System/Applications", false)
    ]
    static let researchAppIdentifiers = [
        "com.apple.mobilesafari", "com.apple.mobilenotes", "com.apple.Maps",
        "com.apple.facetime", "com.apple.iBooks", "com.apple.podcasts",
        "com.apple.PosterBoard", "com.apple.mobilemail", "com.apple.weather",
        "com.apple.camera", "com.apple.Health", "com.apple.Fitness",
        "com.apple.tips", "com.apple.Passbook", "com.apple.reminders",
        "com.apple.stocks", "com.apple.news", "com.apple.Home", "com.apple.tv",
        "com.apple.shortcuts", "com.apple.freeform", "com.apple.calculator",
        "com.apple.MobileSMS", "com.apple.InCallService", "com.apple.Preferences",
        "com.apple.springboard", "com.apple.Photos", "com.apple.AppStore",
        "com.apple.Music", "com.apple.Bridge", "com.apple.Clock",
        "com.apple.VoiceMemos", "com.apple.Translate", "com.apple.measure",
        "com.apple.compass", "com.apple.Magnifier", "com.apple.DocumentsApp"
    ]

    static func resolveAppContainerPath(bundleID: String) -> String? {
        guard Self.isCanonicalBundleIdentifier(bundleID) else {
            return nil
        }
        var lookupError: NSString?
        if let path = MCMActivateContainerPath(2, bundleID, false, &lookupError),
           isApplicationContainerPath(path) {
            log("patch: MHA-C2 resolved \(bundleID)")
            return path
        }
        let detail = lookupError.map(String.init) ?? "unavailable"
        log("patch: MHA-C2 could not resolve \(bundleID), detail=\(detail)")

        // Adaptation: on builds where MCM hands out no sandbox tokens,
        // resolve the path with the ungated MCM lookup and open it with a
        // retained worse_query grant instead.
        var pathError: NSString?
        if let path = MCMContainerPathForIdentifier(2, bundleID, false, &pathError),
           isApplicationContainerPath(path),
           retainContainerAccess(path) {
            log("patch: worse_query grant resolved \(bundleID) -> \(path)")
            return path
        }

        // Fallback for iOS builds where MCM refuses to hand out sandbox
        // tokens (e.g. iOS 18.1.x): scan the app-data root with the inode
        // walk and read each container's MCM metadata plist directly. The
        // raw reads only succeed when the sandbox escape is active.
        if let scanned = resolveAppContainerPathByMetadataScan(bundleID: bundleID) {
            _ = retainContainerAccess(scanned)
            log("patch: filesystem metadata scan resolved \(bundleID)")
            return scanned
        }
        return nil
    }

    /// Standalone extraction of PatchPathValidator.canonicalBundleIdentifier
    /// (the only patch-models symbol the cleaner slice used): true when the
    /// value is already in canonical bundle-identifier form.
    private static func isCanonicalBundleIdentifier(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == rawValue,
              !value.isEmpty,
              value.utf8.count <= 255,
              UUID(uuidString: value) == nil,
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        for component in components {
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ scalar in
                      let v = scalar.value
                      return (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v) || v == 45
                  }),
                  component.first != "-",
                  component.last != "-"
            else {
                return false
            }
        }
        return true
    }

    static func resolveAppContainerPathByMetadataScan(bundleID: String) -> String? {
        // Standalone build: worse_query is the sandbox escape (the opa334
        // kernel chain is not shipped). The scan below simply finds
        // nothing when container access is not active.
        let dirs = enumerateDirectories(path: appDataRoot)
        guard !dirs.isEmpty else {
            log("patch: metadata scan unavailable — no containers enumerated")
            return nil
        }
        for dir in dirs {
            guard UUID(uuidString: (dir as NSString).lastPathComponent) != nil else { continue }
            guard let metadata = readContainerMetadata(containerPath: dir),
                  metadata.bundleID == bundleID else { continue }
            let canonical = ContainerDiscoveryMerger.canonicalPath(dir)
            guard isApplicationContainerPath(canonical) else { continue }
            return canonical
        }
        return nil
    }

    // MARK: Primary — MobileInstallation / LSApplicationWorkspace

    static func installedAppsFromAPI() -> [InstalledApp] {
        let raw = installedAppInfo() as? [String: [String: Any]] ?? [:]
        var apps: [InstalledApp] = []
        var missingContainer = 0
        for (bundleID, info) in raw {
            var containerPath = info["container"] as? String ?? ""
            if containerPath.isEmpty {
                var lookupError: NSString?
                if let resolved = MCMActivateContainerPath(2, bundleID, false, &lookupError),
                   isApplicationContainerPath(resolved) {
                    containerPath = resolved
                } else {
                    missingContainer += 1
                }
            }
            // Skip entries we cannot browse — empty path is dropped by mergers anyway.
            guard !containerPath.isEmpty else { continue }
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: info["name"] as? String ?? "",
                containerPath: containerPath,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            ))
        }
        log("browser: LS/API apps=\(apps.count) raw=\(raw.count) missingContainer=\(missingContainer)")
        return apps
    }

    static func applicationBundleMetadataCatalog() -> [String: ApplicationBundleMetadata] {
        var catalog: [String: ApplicationBundleMetadata] = [:]
        for root in applicationBundleRoots {
            for metadata in applicationBundleMetadata(at: root.path, nested: root.nested) {
                catalog[metadata.bundleID] = metadata
            }
        }
        log("browser: app-bundle metadata resolved \(catalog.count) names")
        return catalog
    }

    static func applyingBundleMetadata(
        to apps: [InstalledApp],
        catalog: [String: ApplicationBundleMetadata]
    ) -> [InstalledApp] {
        apps.map { app in
            guard let metadata = catalog[app.bundleID] else { return app }
            return InstalledApp(
                bundleID: app.bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: app.bundleID,
                    candidates: [metadata.displayName, app.name]
                ),
                containerPath: app.containerPath,
                version: app.version.isEmpty ? metadata.version : app.version,
                icon: app.icon
            )
        }
    }

    static func dynamicAppIdentifiers() -> [String] {
        var enumerationError: NSString?
        let identifiers = MCMEnumerateIdentifiersForClass(2, 1_024, &enumerationError)
        let enumerationDetail = enumerationError.map { String($0) } ?? "none"
        log("browser: MCM class-2 identifiers=\(identifiers.count) detail=\(enumerationDetail)")
        return identifiers
    }

    static func installedAppsFromMCM(
        identifiers: [String]? = nil,
        bundleMetadata: [String: ApplicationBundleMetadata] = [:]
    ) -> [InstalledApp] {
        let identifiers = identifiers ?? dynamicAppIdentifiers()

        var apps: [InstalledApp] = []
        for (index, bundleID) in identifiers.enumerated() {
            var lookupError: NSString?
            guard let containerPath = MCMActivateContainerPath(2, bundleID, false, &lookupError) else {
                let lookupDetail = lookupError.map { String($0) } ?? "no path"
                if index < 3 { log("mcm[\(index)]: \(bundleID) -> \(lookupDetail)") }
                continue
            }
            if index < 3 { log("mcm[\(index)]: \(bundleID) -> \(containerPath)") }

            let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let metadata = bundleMetadata[bundleID]
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [metadata?.displayName, rawInfo["name"] as? String]
                ),
                containerPath: containerPath,
                version: rawInfo["version"] as? String ?? metadata?.version ?? "",
                icon: rawInfo["icon"] as? UIImage
            ))
        }
        log("browser: MCM resolved \(apps.count)/\(identifiers.count) app paths")
        return apps
    }

    // MARK: LaunchServices store discovery

    static func installedAppsFromMHACandidates(
        identifiers: [String],
        bundleMetadata: [String: ApplicationBundleMetadata] = [:],
        progress: (([InstalledApp]) -> Void)? = nil
    ) -> [InstalledApp] {
        guard !identifiers.isEmpty else {
            log("browser: MHA catalog returned no bundle candidates")
            return []
        }

        var apps: [InstalledApp] = []
        for (index, bundleID) in identifiers.enumerated() {
            var lookupError: NSString?
            guard let containerPath = MCMActivateContainerPath(
                2,
                bundleID,
                false,
                &lookupError
            ),
                  isApplicationContainerPath(containerPath) else {
                if index < 3 {
                    let detail = lookupError.map { String($0) } ?? "invalid app-data path"
                    log("mha-candidate[\(index)]: \(bundleID) -> \(detail)")
                }
                continue
            }

            let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let metadata = bundleMetadata[bundleID]
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [metadata?.displayName, rawInfo["name"] as? String]
                ),
                containerPath: containerPath,
                version: rawInfo["version"] as? String ?? metadata?.version ?? "",
                icon: rawInfo["icon"] as? UIImage
            ))
            if apps.count <= 5 {
                log("browser: MHA-C2 resolved \(bundleID) -> \(containerPath)")
            }
            if apps.count.isMultiple(of: 8) {
                progress?(apps)
            }
        }

        progress?(apps)
        log("browser: MHA-C2 resolved \(apps.count)/\(identifiers.count) bundle candidates")
        return apps
    }

    private static func applicationBundleMetadata(
        at rootPath: String,
        nested: Bool
    ) -> [ApplicationBundleMetadata] {
        let handle = grantContainerAccess(rootPath)
        defer {
            if handle >= 0 { worse_query_release(handle) }
        }

        let fileManager = FileManager.default
        guard let rootEntries = try? fileManager.contentsOfDirectory(atPath: rootPath) else {
            log("browser: app-bundle metadata unavailable root=\(rootPath) grant=\(handle)")
            return []
        }

        let bundlePaths: [String]
        if nested {
            bundlePaths = rootEntries.prefix(2_048).flatMap { entry -> [String] in
                guard UUID(uuidString: entry) != nil else { return [] }
                let containerPath = (rootPath as NSString).appendingPathComponent(entry)
                let children = (try? fileManager.contentsOfDirectory(atPath: containerPath)) ?? []
                return children.prefix(16).compactMap { child in
                    guard child.hasSuffix(".app") else { return nil }
                    return (containerPath as NSString).appendingPathComponent(child)
                }
            }
        } else {
            bundlePaths = rootEntries.prefix(2_048).compactMap { entry in
                guard entry.hasSuffix(".app") else { return nil }
                return (rootPath as NSString).appendingPathComponent(entry)
            }
        }

        return bundlePaths.compactMap { bundlePath in
            let infoPath = (bundlePath as NSString).appendingPathComponent("Info.plist")
            let infoSize = (try? fileManager.attributesOfItem(atPath: infoPath)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard infoSize > 0, infoSize <= 2 * 1_024 * 1_024 else { return nil }
            guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: infoPath)) else {
                return nil
            }
            return ApplicationBundleMetadataReader.metadata(
                from: plistData,
                localizedInfo: Bundle(path: bundlePath)?.localizedInfoDictionary
            )
        }
    }

    static func launchServicesStoreIdentifiers() -> [String] {
        var cachePaths: [String] = []
        var seenCachePaths = Set<String>()

        func addCachePath(_ rawPath: String) {
            let path = ContainerDiscoveryMerger.canonicalPath(rawPath)
            guard !path.isEmpty, seenCachePaths.insert(path).inserted else { return }
            cachePaths.append(path)
        }

        var leasedCachePaths = Set<String>()
        var serviceLookupError: NSString?
        if let servicePath = MCMActivateContainerPath(
            10,
            "com.apple.lsd",
            false,
            &serviceLookupError
        ) {
            let cachePath = (servicePath as NSString).appendingPathComponent("Library/Caches")
            addCachePath(cachePath)
            leasedCachePaths.insert(ContainerDiscoveryMerger.canonicalPath(cachePath))
        } else if shouldUseBadQuery {
            let detail = serviceLookupError.map { String($0) } ?? "no path"
            log("browser: MCM com.apple.lsd activation unavailable detail=\(detail)")
        }

        let traversedSystemDirectories = enumerateDirectoriesWithTraversalGrant(path: systemDataRoot)
        let systemDirectories = traversedSystemDirectories.isEmpty
            ? enumerateDirectories(path: systemDataRoot)
            : traversedSystemDirectories
        for directory in systemDirectories {
            // Attempt the raw metadata read even without a traversal grant:
            // it succeeds when the sandbox escape is active, which is the
            // only path left when MCM/bad_query grants are denied.
            guard readContainerMetadata(containerPath: directory)?.bundleID == "com.apple.lsd" else {
                continue
            }
            addCachePath((directory as NSString).appendingPathComponent("Library/Caches"))
        }

        // Older and Simulator layouts keep the same store outside the MCM
        // service-container layout. They are harmless fallbacks on device.
        addCachePath("/var/db/lsd")
        addCachePath("/var/mobile/Library/Caches")

        var identifiers: [String] = []
        var seenIdentifiers = Set<String>()
        let maximumCandidateCount = 65_536

        for cachePath in cachePaths where identifiers.count < maximumCandidateCount {
            let hasLease = leasedCachePaths.contains(
                ContainerDiscoveryMerger.canonicalPath(cachePath)
            )
            let handle: Int64
            if hasLease || !shouldUseBadQuery {
                handle = -1
            } else {
                handle = grantContainerAccess(cachePath)
                if handle < 0 {
                    log("browser: LaunchServices traversal grant failed \(cachePath) -> \(handle)")
                    continue
                }
            }
            defer {
                if handle >= 0 { worse_query_release(handle) }
            }

            let names = (try? FileManager.default.contentsOfDirectory(atPath: cachePath)) ?? []
            for name in names where identifiers.count < maximumCandidateCount {
                guard name.hasPrefix("com.apple.LaunchServices-"),
                      name.hasSuffix("-v2.csstore") else {
                    continue
                }
                let storePath = (cachePath as NSString).appendingPathComponent(name)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: storePath)[.size]) as? NSNumber,
                      size.uint64Value > 0,
                      size.uint64Value <= 64 * 1_024 * 1_024,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: storePath), options: .mappedIfSafe) else {
                    continue
                }
                let remaining = maximumCandidateCount - identifiers.count
                let extracted = LaunchServicesCandidateExtractor.identifiers(from: data, limit: remaining)
                for identifier in extracted where seenIdentifiers.insert(identifier).inserted {
                    identifiers.append(identifier)
                }
                log("browser: LaunchServices store \(name) bytes=\(data.count) candidates=\(identifiers.count)")
            }
        }

        log("browser: LaunchServices store total candidates=\(identifiers.count)")
        return identifiers
    }

    static func isApplicationContainerPath(_ path: String) -> Bool {
        let canonicalRoot = ContainerDiscoveryMerger.canonicalPath(appDataRoot)
        let canonicalPath = ContainerDiscoveryMerger.canonicalPath(path)
        guard canonicalPath.hasPrefix(canonicalRoot + "/") else { return false }
        return UUID(uuidString: (canonicalPath as NSString).lastPathComponent) != nil
    }

    // MARK: Filesystem discovery

    static func enumerateDirectories(path: String, maxInode: Int64 = 2_000_000) -> [String] {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard clean.hasPrefix("/") else { return [] }

        if let names = try? FileManager.default.contentsOfDirectory(atPath: clean), !names.isEmpty {
            return names.map { (clean as NSString).appendingPathComponent($0) }
        }

        var pathC = clean.utf8CString.map { Int8($0) }
        guard let result = bad_query_list(&pathC, maxInode) else {
            log("enumerate: NULL for \(clean)")
            return []
        }
        defer { free(result) }
        let list = String(cString: result).components(separatedBy: "\n").filter { !$0.isEmpty }
        if !list.isEmpty {
            log("enumerate: inode fallback for \(clean) -> \(list.count) entries")
        } else {
            log("enumerate: FileManager+inode unavailable for \(clean)")
        }
        return list
    }

    static func enumerateDirectoriesWithTraversalGrant(path: String) -> [String] {
        if !shouldUseBadQuery {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path), !names.isEmpty {
                return names.map { (path as NSString).appendingPathComponent($0) }
            }
            return enumerateDirectories(path: path)
        }

        let handle = grantContainerAccess(path)
        if handle >= 0 {
            defer { worse_query_release(handle) }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path), !names.isEmpty {
                return names.map { (path as NSString).appendingPathComponent($0) }
            }
        } else {
            log("browser: root traversal grant failed \(path) -> \(handle)")
        }

        return enumerateDirectories(path: path)
    }

    static func readContainerMetadata(containerPath: String) -> ContainerMetadata? {
        let metadataPath = metadataPath(for: containerPath)

        var data: Data?
        if let fd = fopen(metadataPath, "r") {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var bytes: [UInt8] = []
            while true {
                let n = fread(&buffer, 1, buffer.count, fd)
                if n <= 0 { break }
                bytes.append(contentsOf: buffer[0..<n])
            }
            fclose(fd)
            if !bytes.isEmpty { data = Data(bytes) }
        }
        if data == nil { data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)) }

        guard let validData = data,
              let plist = try? PropertyListSerialization.propertyList(from: validData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let bundleID = plist["MCMMetadataIdentifier"] as? String ?? ""
        var displayName = ""
        if let info = plist["MCMMetadataInfo"] as? [String: Any] {
            displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
        }
        return ContainerMetadata(bundleID: bundleID, displayName: displayName)
    }

    static func metadataPath(for containerPath: String) -> String {
        (containerPath as NSString).appendingPathComponent(
            ".com.apple.mobile_container_manager.metadata.plist"
        )
    }

    // Adaptation: the bad_query container-query traversal was patched in
    // iOS 27 beta 5. Grants now come from worse_query (same containermanager
    // family, driven through an App Group the app owns). alt_flags is tried
    // in the upstream PoC's order (true, then false).
    static func grantContainerAccess(_ containerPath: String, logFailure: Bool = true) -> Int64 {
        guard shouldUseBadQuery else { return -1 }
        guard let group = AppGroupDiscovery.workingGroupIdentifier() else {
            log("grant: no accessible app group; cannot grant \(containerPath)")
            return -2
        }
        let clean = containerPath.hasSuffix("/") ? String(containerPath.dropLast()) : containerPath
        var handle = worse_query(clean, group, false, true)
        if handle < 0 {
            handle = worse_query(clean, group, true, true)
        }
        if handle < 0 && logFailure {
            log("grant: worse_query failed for \(clean) -> \(handle)")
        }
        return handle
    }

    private static func registerRetainedGrant(handle: Int64, for containerPath: String) {
        let clean = ContainerDiscoveryMerger.canonicalPath(containerPath)
        retainedGrantLock.lock()
        retainedGrantHandles[clean] = handle
        retainedGrantLock.unlock()
    }

    // MARK: Retained grants (Cleaner)

    private static var retainedGrantHandles: [String: Int64] = [:]
    private static let retainedGrantLock = NSLock()

    /// Grants access to a container and keeps the extension alive for the
    /// rest of the process, mirroring the MCM lease registry. Returns true
    /// when access to the path is held.
    static func retainContainerAccess(_ containerPath: String) -> Bool {
        let clean = ContainerDiscoveryMerger.canonicalPath(containerPath)
        retainedGrantLock.lock()
        let alreadyHeld = retainedGrantHandles[clean] != nil
        retainedGrantLock.unlock()
        if alreadyHeld { return true }
        let handle = grantContainerAccess(clean)
        guard handle >= 0 else { return false }
        retainedGrantLock.lock()
        retainedGrantHandles[clean] = handle
        retainedGrantLock.unlock()
        return true
    }

    static func containersFromFilesystem() -> [InstalledApp] {
        let grantedDirectories = enumerateDirectoriesWithTraversalGrant(path: appDataRoot)
        let dirs: [String]
        if grantedDirectories.isEmpty {
            dirs = enumerateDirectories(path: appDataRoot)
            log("browser: filesystem root=\(appDataRoot) inode fallback enumerated \(dirs.count) containers")
        } else {
            dirs = grantedDirectories
            log("browser: filesystem root=\(appDataRoot) traversal enumerated \(dirs.count) containers")
        }
        let apps = dirs.compactMap { dir -> InstalledApp? in
            let uuid = (dir as NSString).lastPathComponent
            guard UUID(uuidString: uuid) != nil else { return nil }
            let fallback = ContainerIdentityResolver.fallbackIdentity(containerPath: dir)
            return InstalledApp(
                bundleID: fallback.bundleID,
                name: fallback.displayName,
                containerPath: dir,
                version: "",
                icon: nil
            )
        }
        log("browser: filesystem accepted \(apps.count)/\(dirs.count) app containers")
        return apps
    }

    /// Adaptation: filesystem-discovered containers with identities
    /// resolved from each container's MCM metadata plist, read under a
    /// worse_query grant. Unresolved containers keep their fallback
    /// (UUID) identity and are filtered out by presentation policy.
    // One-shot deep probe (first container only): separates the two
    // alt_flags variants and reports whether post-grant reads actually
    // work — fopen errno, byte count, plist keys, directory entries.

    // Identity fallback: the container metadata plist sits behind a
    // stricter protection than the container itself (post-grant opendir
    // works, fopen on the metadata file returns EPERM). Most apps leave
    // Library/Preferences/<bundleID>.plist behind, so the directory
    // listing alone usually names the owner.
    private static func bundleIDFromPreferencesListing(containerPath: String) -> (bundleID: String?, entries: [String]) {
        let prefsPath = (containerPath as NSString).appendingPathComponent("Library/Preferences")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: prefsPath)) ?? []
        return (preferencesCandidates(entries: entries).first, entries)
    }

    // All bundle-ID-shaped names in Library/Preferences, in a deterministic
    // order (third-party IDs alphabetically, then com.apple IDs).
    private static func preferencesCandidates(entries: [String]) -> [String] {
        let ids = entries.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(".plist".count)) }
            .filter { $0.contains(".") && !$0.contains(" ") }
        return ids.sorted { a, b in
            let aApple = a.hasPrefix("com.apple.")
            let bApple = b.hasPrefix("com.apple.")
            if aApple != bApple { return !aApple }
            return a < b
        }
    }

    private static func preferencesCandidateIDs(containerPath: String) -> [String] {
        let prefsPath = (containerPath as NSString).appendingPathComponent("Library/Preferences")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: prefsPath)) ?? []
        return preferencesCandidates(entries: entries)
    }

    // Identity candidates from Library/Saved Application State: the system
    // names those directories "<bundleID>.savedState", a much stronger
    // signal than the preference-file soup.
    private static func savedStateCandidateIDs(containerPath: String) -> [String] {
        let statePath = ((containerPath as NSString)
            .appendingPathComponent("Library/Saved Application State"))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: statePath)) ?? []
        return entries
            .filter { $0.hasSuffix(".savedState") }
            .map { String($0.dropLast(".savedState".count)) }
            .filter { $0.contains(".") && !$0.contains(" ") }
    }

    private static func identityCandidates(containerPath: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for candidate in savedStateCandidateIDs(containerPath: containerPath)
            + preferencesCandidateIDs(containerPath: containerPath) {
            if seen.insert(candidate).inserted {
                ordered.append(candidate)
            }
        }
        return ordered
    }

    // Identity pinning: a candidate is the container's true bundle ID when
    // the MCM path lookup for it resolves back to this very container.
    // Verification is definitive, so try generously: busy containers (the
    // ByteDance/Tencent apps) carry dozens of SDK preference files and the
    // true ID is rarely among the first few alphabetically.
    private static func verifiedBundleID(candidates: [String], containerPath: String) -> String? {
        for candidate in candidates.prefix(40) {
            var lookupError: NSString?
            guard let path = MCMContainerPathForIdentifier(2, candidate, false, &lookupError) else {
                continue
            }
            if ContainerDiscoveryMerger.canonicalPath(path) == containerPath {
                return candidate
            }
        }
        return nil
    }

    static func resolvedFilesystemApps() -> [InstalledApp] {
        // Adaptation: root-level traversal grants are refused by the kernel
        // on iOS 27.3 (worse_query -6), so enumerate the container UUIDs via
        // the inode walk and grant each concrete container path on its own —
        // the shape worse_query was proven with. Grants stay retained so the
        // Cleaner can scan (and later clean) through them.
        let dirs = enumerateDirectories(path: appDataRoot).filter {
            UUID(uuidString: ($0 as NSString).lastPathComponent) != nil
        }
        var resolved: [InstalledApp] = []
        var grantedCount = 0
        var identifiedCount = 0
        var failedCount = 0
        var metadataIdentifiedCount = 0
        var prefsIdentifiedCount = 0
        var verifiedIdentifiedCount = 0
        var unresolvedLogged = 0
        var unclaimedPaths: [String] = []
        var unidentifiedLogged = 0
        var resolvedIndexByPath: [String: Int] = [:]
        var resolvedIndexByBundleID: [String: Int] = [:]
        var resolvedVerified: [String: Bool] = [:]
        for (index, dir) in dirs.enumerated() {
            let canonical = ContainerDiscoveryMerger.canonicalPath(dir)
            let sample = index < 5
            let handle = grantContainerAccess(canonical, logFailure: sample)
            guard handle >= 0 else {
                failedCount += 1
                if sample {
                    log("cleaner grant sample[\(index)]: \(canonical) -> \(handle)")
                }
                continue
            }
            grantedCount += 1
            let metadata = readContainerMetadata(containerPath: canonical)
            var bundleID = metadata?.bundleID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var displayName = metadata?.displayName ?? ""
            var identityVerified = false
            if bundleID.isEmpty || bundleID.hasPrefix("systemgroup.") {
                let candidates = identityCandidates(containerPath: canonical)
                let verified = verifiedBundleID(candidates: candidates, containerPath: canonical)
                let pick = verified ?? candidates.first
                if let pick, !pick.hasPrefix("systemgroup.") {
                    bundleID = pick
                    displayName = ""
                    identityVerified = verified != nil
                    prefsIdentifiedCount += 1
                    if verified != nil { verifiedIdentifiedCount += 1 }
                } else if !candidates.isEmpty, unresolvedLogged < 8 {
                    unresolvedLogged += 1
                    log("cleaner: identity unresolved container=\(canonical) candidates=\(Array(candidates.prefix(8)))")
                }
            } else {
                metadataIdentifiedCount += 1
                identityVerified = true
            }
            guard !bundleID.isEmpty, !bundleID.hasPrefix("systemgroup.") else {
                if sample {
                    log("cleaner grant sample[\(index)]: granted, identity unavailable \(canonical)")
                }
                unclaimedPaths.append(canonical)
                if unidentifiedLogged < 12 {
                    unidentifiedLogged += 1
                    log("cleaner: unidentified \(canonical) candidates=\(identityCandidates(containerPath: canonical).count)")
                }
                worse_query_release(handle)
                continue
            }
            registerRetainedGrant(handle: handle, for: canonical)
            identifiedCount += 1
            if sample {
                log("cleaner grant sample[\(index)]: \(bundleID) granted + identified")
            }
            let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let app = InstalledApp(
                bundleID: bundleID,
                name: displayName.isEmpty ? bundleID : displayName,
                containerPath: canonical,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            )
            // Two containers can claim one ID (an app and its extension).
            // A verified identity replaces an unverified one; otherwise the
            // first claim wins.
            if let existingIndex = resolvedIndexByBundleID[bundleID] {
                if identityVerified, resolvedVerified[bundleID] != true {
                    resolved[existingIndex] = app
                    resolvedVerified[bundleID] = true
                }
            } else {
                resolvedIndexByBundleID[bundleID] = resolved.count
                resolvedIndexByPath[canonical] = resolved.count
                resolvedVerified[bundleID] = identityVerified
                resolved.append(app)
            }
        }
        log("cleaner: filesystem resolve total=\(dirs.count) granted=\(grantedCount) identified=\(identifiedCount) (metadata=\(metadataIdentifiedCount) prefs=\(prefsIdentifiedCount) verified=\(verifiedIdentifiedCount)) failed=\(failedCount)")

        // Dictionary probing: apps whose local Preferences are empty
        // (their defaults live in an App Group suite) never produce
        // identity candidates. Ask containermanagerd for the container
        // path of every known bundle ID that is still unresolved; its
        // answer is authoritative, and the name table is the dictionary.
        var probeHits = 0
        let unclaimedSet = Set(unclaimedPaths)
        for (bundleID, friendlyName) in KnownApps.table where resolvedIndexByBundleID[bundleID] == nil {
            var lookupError: NSString?
            guard let path = MCMContainerPathForIdentifier(2, bundleID, false, &lookupError) else {
                continue
            }
            let canonical = ContainerDiscoveryMerger.canonicalPath(path)
            let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let probedApp = InstalledApp(
                bundleID: bundleID,
                name: friendlyName,
                containerPath: canonical,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            )
            if let claimedIndex = resolvedIndexByPath[canonical] {
                // Already listed under a heuristic identity; the
                // containermanagerd answer replaces it. A verified
                // identity is never displaced.
                guard resolvedVerified[resolved[claimedIndex].bundleID] != true else { continue }
                let oldID = resolved[claimedIndex].bundleID
                resolvedIndexByBundleID.removeValue(forKey: oldID)
                resolvedVerified.removeValue(forKey: oldID)
                resolved[claimedIndex] = probedApp
                resolvedIndexByBundleID[bundleID] = claimedIndex
                resolvedVerified[bundleID] = true
                probeHits += 1
                log("cleaner: probe hit \(bundleID) reclaimed from \(oldID)")
                continue
            }
            let enumerated = unclaimedSet.contains(canonical)
            if !enumerated, !FileManager.default.fileExists(atPath: canonical) {
                continue
            }
            let probeHandle = grantContainerAccess(canonical, logFailure: false)
            guard probeHandle >= 0 else { continue }
            registerRetainedGrant(handle: probeHandle, for: canonical)
            resolvedIndexByPath[canonical] = resolved.count
            resolvedIndexByBundleID[bundleID] = resolved.count
            resolvedVerified[bundleID] = true
            resolved.append(probedApp)
            probeHits += 1
            log("cleaner: probe hit \(bundleID) enumerated=\(enumerated)")
        }
        if probeHits > 0 {
            log("cleaner: dictionary probe hits=\(probeHits)")
        }

        // Friendly names from the built-in table; bundle containers are
        // unreachable in this sandbox (see KnownApps).
        resolved = resolved.map { app in
            guard let friendly = KnownApps.displayName(for: app.bundleID) else { return app }
            return InstalledApp(
                bundleID: app.bundleID,
                name: friendly,
                containerPath: app.containerPath,
                version: app.version,
                icon: app.icon
            )
        }
        return resolved
    }

    static func inferredApp(
        for fallback: InstalledApp,
        knownAppsByBundleID: [String: InstalledApp],
        launchServicesIdentifiers: Set<String>
    ) -> InstalledApp? {
        guard UUID(uuidString: fallback.bundleID) != nil else { return fallback }

        // Read the MCM metadata plist directly. With the sandbox escape
        // active the raw read succeeds even when every MCM/bad_query grant
        // is denied; without it the read simply fails and we fall through.
        if let metadata = readContainerMetadata(containerPath: fallback.containerPath) {
            let bundleID = metadata.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if ContainerBundleCandidateResolver.isValidBundleIdentifier(bundleID),
               !bundleID.hasPrefix("systemgroup.") {
                let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                let resolvedName = metadata.displayName.isEmpty
                    ? (info["name"] as? String ?? bundleID)
                    : metadata.displayName
                return InstalledApp(
                    bundleID: bundleID,
                    name: resolvedName,
                    containerPath: fallback.containerPath,
                    version: info["version"] as? String ?? "",
                    icon: info["icon"] as? UIImage
                )
            }
        }

        let handle = grantContainerAccess(fallback.containerPath)
        defer {
            if handle >= 0 { worse_query_release(handle) }
        }

        let libraryPath = (fallback.containerPath as NSString).appendingPathComponent("Library")
        let savedStatePath = (libraryPath as NSString).appendingPathComponent("Saved Application State")
        let preferencesPath = (libraryPath as NSString).appendingPathComponent("Preferences")
        let savedStates = (try? FileManager.default.contentsOfDirectory(atPath: savedStatePath)) ?? []
        let preferences = (try? FileManager.default.contentsOfDirectory(atPath: preferencesPath)) ?? []
        let strongCandidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: savedStates,
            preferenceFileNames: []
        )
        let candidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: savedStates,
            preferenceFileNames: preferences
        )

        func resolvedApp(from candidates: [String], source: String) -> InstalledApp? {
            for bundleID in candidates {
                if let known = knownAppsByBundleID[bundleID] {
                    return InstalledApp(
                        bundleID: bundleID,
                        name: known.name,
                        containerPath: fallback.containerPath,
                        version: known.version,
                        icon: known.icon
                    )
                }

                let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                guard info["found"] as? Bool == true else { continue }
                return InstalledApp(
                    bundleID: bundleID,
                    name: info["name"] as? String ?? bundleID,
                    containerPath: fallback.containerPath,
                    version: info["version"] as? String ?? "",
                    icon: info["icon"] as? UIImage
                )
            }

            guard let bundleID = ContainerBundleCandidateResolver.confirmedCandidate(
                candidates: candidates,
                launchServicesIdentifiers: launchServicesIdentifiers
            ) else {
                return nil
            }
            let uuid = (fallback.containerPath as NSString).lastPathComponent
            log("browser: content+LaunchServices confirmed \(uuid) -> \(bundleID) source=\(source)")
            return InstalledApp(
                bundleID: bundleID,
                name: bundleID,
                containerPath: fallback.containerPath,
                version: "",
                icon: nil
            )
        }

        if let app = resolvedApp(from: candidates, source: "state/preferences") {
            return app
        }
        if let bundleID = strongCandidates.first {
            return InstalledApp(
                bundleID: bundleID,
                name: bundleID,
                containerPath: fallback.containerPath,
                version: "",
                icon: nil
            )
        }

        let artifactPaths = [
            (libraryPath as NSString).appendingPathComponent("SplashBoard/Snapshots"),
            (libraryPath as NSString).appendingPathComponent("Caches/Snapshots"),
            (libraryPath as NSString).appendingPathComponent("Cookies"),
            (libraryPath as NSString).appendingPathComponent("WebKit")
        ]
        let artifactNames = artifactPaths.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
        let artifactCandidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: [],
            preferenceFileNames: [],
            artifactNames: artifactNames
        )
        if let app = resolvedApp(from: artifactCandidates, source: "artifacts") {
            return app
        }

        let uuid = (fallback.containerPath as NSString).lastPathComponent
        let preview = (candidates + artifactCandidates).prefix(6).joined(separator: ",")
        log("browser: unresolved \(uuid) metadata=unavailable savedStates=\(savedStates.count) preferences=\(preferences.count) artifacts=\(artifactNames.count) candidates=[\(preview)]")
        return nil
    }

    static func inferUnidentifiedApps(
        in apps: [InstalledApp],
        knownApps: [InstalledApp],
        launchServicesIdentifiers: Set<String> = []
    ) -> [InstalledApp] {
        let knownByBundleID = Dictionary(knownApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var inferredCount = 0
        let result = apps.enumerated().map { index, app -> InstalledApp in
            guard UUID(uuidString: app.bundleID) != nil,
                  let inferred = autoreleasepool(invoking: {
                      inferredApp(
                        for: app,
                        knownAppsByBundleID: knownByBundleID,
                        launchServicesIdentifiers: launchServicesIdentifiers
                      )
                  }) else {
                return app
            }
            inferredCount += 1
            if inferredCount <= 5 {
                log("browser: inferred \((app.containerPath as NSString).lastPathComponent) -> \(inferred.bundleID)")
            }
            return inferred
        }
        let unresolvedCount = result.filter { UUID(uuidString: $0.bundleID) != nil }.count
        log("browser: inferred identities for \(inferredCount)/\(apps.count) merged containers; unresolved=\(unresolvedCount)")
        return result
    }

    // MARK: File browsing

    static func listFiles(at path: String) -> [FileEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else {
            log("listFiles: FAILED for \(path) errno=\(errno)")
            return []
        }
        var entries: [FileEntry] = []
        for item in items {
            if item.hasPrefix(".") { continue }
            let full = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let attributes = try? fm.attributesOfItem(atPath: full)
            let size = isDir.boolValue
                ? -1
                : (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(
                FileEntry(
                    name: item,
                    path: full,
                    isDirectory: isDir.boolValue,
                    size: size,
                    modifiedAt: attributes?[.modificationDate] as? Date
                )
            )
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func readTextFile(at path: String, limit: Int = 200_000) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "Unable to read file."
        }
        let truncated = data.prefix(limit)
        if let text = String(data: truncated, encoding: .utf8) {
            return data.count > limit ? text + "\n… [truncated]" : text
        }
        if let text = String(data: truncated, encoding: .utf16) {
            return data.count > limit ? text + "\n… [truncated]" : text
        }
        return "Binary data (\(data.count) bytes) — not text."
    }
}
