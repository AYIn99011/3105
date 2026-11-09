import Foundation
import Darwin

/// One entry inside an app container, as shown by the drill-down inventory.
/// `relativePath` is relative to the container root (e.g. "Library/Caches").
struct InventoryEntry: Identifiable, Equatable {
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    var bytes: Int64
    var itemCount: Int
    let isProtected: Bool

    var id: String { relativePath }
}

struct InventoryDeletionResult: Equatable {
    let removedItemCount: Int
    let failedItemCount: Int
    let freedBytes: Int64
}

/// Drill-down inventory for a single app container: list one level at a
/// time, measure recursively, delete exactly the paths the user picked.
/// All filesystem work is fd-relative with O_NOFOLLOW, mirroring
/// LimitedCleanerService, and the container root must pass the same
/// application-container validation.
enum ContainerInventoryService {
    // MARK: - Classification

    static func isProtected(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        if components.count >= 2, components[0] == "Library", components[1] == "Preferences" {
            return true
        }
        if components.contains("mmkv") { return true }
        if name == "USERID_SAVE_KEY" { return true }
        if name.hasSuffix(".archiver") { return true }
        if name == ".com.apple.mobile_container_manager.metadata.plist" { return true }
        return false
    }

    static func isDefaultSelected(relativePath: String) -> Bool {
        relativePath == "tmp"
            || relativePath.hasPrefix("tmp/")
            || relativePath == "Library/Caches"
            || relativePath.hasPrefix("Library/Caches/")
    }

    // MARK: - Listing

    static func listLevel(containerPath: String, relativePath: String) -> [InventoryEntry] {
        guard let rootDescriptor = openContainerRoot(containerPath) else { return [] }
        defer { close(rootDescriptor) }

        let components = relativePath.isEmpty
            ? []
            : relativePath.split(separator: "/").map(String.init)
        guard let levelDescriptor = openDirectory(
            components: components,
            relativeTo: rootDescriptor
        ) else {
            return []
        }
        defer { close(levelDescriptor) }

        var entries: [InventoryEntry] = []
        forEachEntry(in: levelDescriptor) { name, information in
            let childRelativePath = relativePath.isEmpty ? name : relativePath + "/" + name
            let mode = information.st_mode & S_IFMT
            switch mode {
            case S_IFREG:
                entries.append(InventoryEntry(
                    relativePath: childRelativePath,
                    name: name,
                    isDirectory: false,
                    isSymlink: false,
                    bytes: max(0, Int64(information.st_size)),
                    itemCount: 1,
                    isProtected: isProtected(relativePath: childRelativePath)
                ))
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(levelDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                var bytes: Int64 = 0
                var count = 0
                if childDescriptor >= 0 {
                    let summary = scanDirectory(childDescriptor)
                    bytes = summary.bytes
                    count = summary.itemCount
                    close(childDescriptor)
                }
                entries.append(InventoryEntry(
                    relativePath: childRelativePath,
                    name: name,
                    isDirectory: true,
                    isSymlink: false,
                    bytes: bytes,
                    itemCount: count,
                    isProtected: isProtected(relativePath: childRelativePath)
                ))
            case S_IFLNK:
                entries.append(InventoryEntry(
                    relativePath: childRelativePath,
                    name: name,
                    isDirectory: false,
                    isSymlink: true,
                    bytes: 0,
                    itemCount: 0,
                    isProtected: true
                ))
            default:
                break
            }
        }
        return entries.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Shallow listing + progressive measuring

    /// Names and types only, no recursion: a level renders immediately even
    /// when it contains a multi-GB subtree. Sizes arrive via measureEntry.
    static func shallowEntries(containerPath: String, relativePath: String) -> [InventoryEntry] {
        guard let rootDescriptor = openContainerRoot(containerPath) else { return [] }
        defer { close(rootDescriptor) }

        let components = relativePath.isEmpty
            ? []
            : relativePath.split(separator: "/").map(String.init)
        guard let levelDescriptor = openDirectory(
            components: components,
            relativeTo: rootDescriptor
        ) else {
            log("inventory: level \(relativePath.isEmpty ? "<root>" : relativePath) open failed errno=\(errno)")
            return []
        }
        defer { close(levelDescriptor) }

        var entries: [InventoryEntry] = []
        forEachEntry(in: levelDescriptor) { name, information in
            let childRelativePath = relativePath.isEmpty ? name : relativePath + "/" + name
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                entries.append(InventoryEntry(
                    relativePath: childRelativePath,
                    name: name,
                    isDirectory: false,
                    isSymlink: false,
                    bytes: max(0, Int64(information.st_size)),
                    itemCount: 1,
                    isProtected: isProtected(relativePath: childRelativePath)
                ))
            case S_IFDIR:
                entries.append(InventoryEntry(
                    relativePath: childRelativePath,
                    name: name,
                    isDirectory: true,
                    isSymlink: false,
                    bytes: 0,
                    itemCount: 0,
                    isProtected: isProtected(relativePath: childRelativePath)
                ))
            case S_IFLNK:
                entries.append(InventoryEntry(
                    relativePath: childRelativePath,
                    name: name,
                    isDirectory: false,
                    isSymlink: true,
                    bytes: 0,
                    itemCount: 0,
                    isProtected: true
                ))
            default:
                break
            }
        }
        log("inventory: level \(relativePath.isEmpty ? "<root>" : relativePath) entries=\(entries.count)")
        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func measureEntry(
        containerPath: String,
        relativePath: String
    ) -> (bytes: Int64, itemCount: Int)? {
        guard let rootDescriptor = openContainerRoot(containerPath) else { return nil }
        defer { close(rootDescriptor) }

        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return nil }
        guard let parentDescriptor = openDirectory(
            components: Array(components.dropLast()),
            relativeTo: rootDescriptor
        ) else {
            return nil
        }
        defer { close(parentDescriptor) }

        var information = stat()
        let status = name.withCString {
            fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return nil }
        switch information.st_mode & S_IFMT {
        case S_IFREG:
            return (max(0, Int64(information.st_size)), 1)
        case S_IFDIR:
            let childDescriptor = name.withCString {
                openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard childDescriptor >= 0 else { return nil }
            let summary = scanDirectory(childDescriptor)
            close(childDescriptor)
            return summary
        default:
            return (0, 0)
        }
    }

    // MARK: - Whole-container size

    /// Total bytes of every top-level entry (Documents, Library, tmp and
    /// the rest), for the main list's size column.
    static func measureContainer(containerPath: String) -> Int64? {
        guard let rootDescriptor = openContainerRoot(containerPath) else { return nil }
        defer { close(rootDescriptor) }
        var total: Int64 = 0
        forEachEntry(in: rootDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                total += max(0, Int64(information.st_size))
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                if childDescriptor >= 0 {
                    total += scanDirectory(childDescriptor).bytes
                    close(childDescriptor)
                }
            default:
                break
            }
        }
        return total
    }

    // MARK: - Deletion

    static func delete(
        containerPath: String,
        relativePaths: [String]
    ) -> InventoryDeletionResult {
        guard let rootDescriptor = openContainerRoot(containerPath) else {
            log("inventory: delete aborted, container root not openable \(containerPath)")
            return InventoryDeletionResult(
                removedItemCount: 0,
                failedItemCount: relativePaths.count,
                freedBytes: 0
            )
        }
        defer { close(rootDescriptor) }

        var removed = 0
        var failed = 0
        var freed: Int64 = 0

        for relativePath in relativePaths {
            let components = relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            let parentComponents = Array(components.dropLast())
            guard let parentDescriptor = openDirectory(
                components: parentComponents,
                relativeTo: rootDescriptor
            ) else {
                log("inventory: delete \(relativePath) parent open failed errno=\(errno)")
                failed += 1
                continue
            }

            var information = stat()
            let status = name.withCString {
                fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else {
                close(parentDescriptor)
                continue // Already gone; nothing to do.
            }

            let mode = information.st_mode & S_IFMT
            if mode == S_IFDIR {
                let childDescriptor = name.withCString {
                    openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard childDescriptor >= 0 else {
                    log("inventory: delete \(relativePath) dir open failed errno=\(errno)")
                    failed += 1
                    close(parentDescriptor)
                    continue
                }
                let before = scanDirectory(childDescriptor)
                close(childDescriptor)
                // scanDirectory consumed the directory offset of that fd
                // (dup shares the open file description), so removal must
                // traverse a freshly opened descriptor — reusing the
                // scanned one makes removal see an empty directory and the
                // final rmdir fails with ENOTEMPTY.
                let removalDescriptor = name.withCString {
                    openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard removalDescriptor >= 0 else {
                    log("inventory: delete \(relativePath) reopen for removal failed errno=\(errno)")
                    failed += 1
                    close(parentDescriptor)
                    continue
                }
                var summary = RemovalSummary()
                removeDirectoryContents(removalDescriptor, summary: &summary)
                close(removalDescriptor)
                let result = name.withCString {
                    unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                }
                if result != 0 {
                    log("inventory: delete \(relativePath) rmdir failed errno=\(errno) removedContents=\(summary.removedItemCount) failedContents=\(summary.failedItemCount)")
                }
                if result == 0 {
                    removed += summary.removedItemCount
                    freed += before.bytes
                } else {
                    failed += summary.failedItemCount + 1
                    // Partial removal: credit only what actually vanished.
                    let afterDescriptor = name.withCString {
                        openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    }
                    if afterDescriptor >= 0 {
                        let after = scanDirectory(afterDescriptor)
                        close(afterDescriptor)
                        freed += max(0, before.bytes - after.bytes)
                    }
                }
            } else {
                let result = name.withCString { unlinkat(parentDescriptor, $0, 0) }
                if result == 0 {
                    removed += 1
                    freed += max(0, Int64(information.st_size))
                } else if errno != ENOENT {
                    failed += 1
                }
            }
            close(parentDescriptor)
        }

        return InventoryDeletionResult(
            removedItemCount: removed,
            failedItemCount: failed,
            freedBytes: freed
        )
    }

    // MARK: - fd plumbing (mirrors LimitedCleanerService)

    private static func openContainerRoot(_ containerPath: String) -> Int32? {
        guard ContainerStore.isApplicationContainerPath(containerPath) else { return nil }
        let descriptor = open(
            containerPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        return descriptor >= 0 ? descriptor : nil
    }

    private static func openDirectory(
        components: [String],
        relativeTo rootDescriptor: Int32
    ) -> Int32? {
        var currentDescriptor = dup(rootDescriptor)
        guard currentDescriptor >= 0 else { return nil }
        for component in components {
            let nextDescriptor = component.withCString {
                openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            close(currentDescriptor)
            guard nextDescriptor >= 0 else { return nil }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func scanDirectory(_ directoryDescriptor: Int32) -> (bytes: Int64, itemCount: Int) {
        var bytes: Int64 = 0
        var itemCount = 0
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                bytes += max(0, Int64(information.st_size))
                itemCount += 1
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard childDescriptor >= 0 else { return }
                let nested = scanDirectory(childDescriptor)
                close(childDescriptor)
                bytes += nested.bytes
                itemCount += nested.itemCount
            default:
                break
            }
        }
        return (bytes, itemCount)
    }

    private static func removeDirectoryContents(
        _ directoryDescriptor: Int32,
        summary: inout RemovalSummary
    ) {
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                if result == 0 {
                    summary.removedItemCount += 1
                } else if errno != ENOENT {
                    summary.failedItemCount += 1
                }
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard childDescriptor >= 0 else {
                    if errno != ENOENT && errno != ELOOP {
                        summary.failedItemCount += 1
                    }
                    return
                }
                removeDirectoryContents(childDescriptor, summary: &summary)
                close(childDescriptor)
                let result = name.withCString {
                    unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                }
                if result != 0, errno != ENOENT, errno != ENOTEMPTY {
                    summary.failedItemCount += 1
                }
            default:
                break
            }
        }
    }

    private static func forEachEntry(
        in directoryDescriptor: Int32,
        body: (String, stat) -> Void
    ) {
        let iterationDescriptor = dup(directoryDescriptor)
        guard iterationDescriptor >= 0,
              let directory = fdopendir(iterationDescriptor) else {
            if iterationDescriptor >= 0 { close(iterationDescriptor) }
            return
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var information = stat()
            let status = name.withCString {
                fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }
            body(name, information)
        }
    }
}

private struct RemovalSummary {
    var removedItemCount = 0
    var failedItemCount = 0
}
