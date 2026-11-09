import Foundation

struct CleanerResolvedApplication: Equatable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
}

struct CleanerCatalogRecord: Equatable {
    let application: CleanerResolvedApplication
    let containerPath: String
    let usage: LimitedCleanerUsage

    var bundleID: String { application.bundleID }
}

enum CleanerSortOrder: String, CaseIterable, Identifiable {
    case largestFirst
    case smallestFirst

    var id: String { rawValue }
}

enum CleanerCatalog {
    static func sorted<Record>(
        _ records: [Record],
        order: CleanerSortOrder,
        size: (Record) -> Int64,
        displayName: (Record) -> String,
        stableID: (Record) -> String
    ) -> [Record] {
        records.sorted { left, right in
            let leftSize = size(left)
            let rightSize = size(right)
            if leftSize != rightSize {
                switch order {
                case .largestFirst:
                    return leftSize > rightSize
                case .smallestFirst:
                    return leftSize < rightSize
                }
            }

            let nameComparison = displayName(left).localizedCaseInsensitiveCompare(displayName(right))
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return stableID(left).localizedCaseInsensitiveCompare(stableID(right)) == .orderedAscending
        }
    }

    static func selectingAllVisible(
        _ visibleBundleIDs: [String],
        preserving selectedBundleIDs: Set<String>
    ) -> Set<String> {
        selectedBundleIDs.union(visibleBundleIDs)
    }

    static func scanNewApplications(
        _ applications: [CleanerResolvedApplication],
        scannedBundleIDs: inout Set<String>,
        shouldIncludeBundleID: (String) -> Bool,
        activateContainer: (CleanerResolvedApplication) -> String?,
        isValidContainerPath: (String) -> Bool,
        usageForContainer: (String) -> LimitedCleanerUsage?
    ) -> [CleanerCatalogRecord] {
        var records: [CleanerCatalogRecord] = []
        for application in applications {
            let bundleID = application.bundleID
            guard shouldIncludeBundleID(bundleID),
                  scannedBundleIDs.insert(bundleID).inserted,
                  let containerPath = activateContainer(application),
                  isValidContainerPath(containerPath),
                  let usage = usageForContainer(containerPath),
                  usage.totalBytes > 0 else {
                continue
            }
            records.append(
                CleanerCatalogRecord(
                    application: application,
                    containerPath: containerPath,
                    usage: usage
                )
            )
        }
        return records
    }
}

/// Cross-view refresh signals. The inventory detail pages delete through
/// ContainerInventoryService, which the main list cannot observe, so a
/// detail deletion marks its bundle ID here. When the list reappears it
/// consumes the marks and patches just those rows in place instead of
/// leaving stale sizes on screen until the next full scan.
final class CleanerRefreshCenter {
    static let shared = CleanerRefreshCenter()

    private let lock = NSLock()
    private var dirtyBundleIDs = Set<String>()

    func markDirty(bundleID: String) {
        lock.lock()
        dirtyBundleIDs.insert(bundleID)
        lock.unlock()
    }

    func consumeDirty() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let dirty = dirtyBundleIDs
        dirtyBundleIDs.removeAll()
        return dirty
    }
}
