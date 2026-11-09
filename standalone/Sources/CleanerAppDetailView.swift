import SwiftUI

/// Shared selection state for one app's inventory. Lives as long as the
/// user stays inside the app's drill-down stack; leaving the app locks
/// protected entries again and drops the selection.
final class CleanerInventoryModel: ObservableObject {
    let containerPath: String
    @Published var selectedPaths = Set<String>()
    @Published var unlockedPaths = Set<String>()
    var entrySizes: [String: Int64] = [:]
    var entryCounts: [String: Int] = [:]
    var defaultsApplied = Set<String>()
    private var grantEnsured = false

    /// The root view's onAppear fires again every time the user pops
    /// back to it; the container grant only needs one successful
    /// retain per inventory session.
    func ensureGrant() {
        guard !grantEnsured else { return }
        grantEnsured = true
        let path = containerPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if !ContainerStore.retainContainerAccess(path) {
                DispatchQueue.main.async { self?.grantEnsured = false }
            }
        }
    }

    /// After a deletion, drop the cached sizes of the deleted paths,
    /// everything under them, and every ancestor (their totals
    /// changed). All other entries keep their cached sizes, so
    /// navigating back never re-measures a level that did not change.
    func invalidateSizes(forPaths paths: [String]) {
        for path in paths {
            for key in Array(entrySizes.keys)
            where key == path || key.hasPrefix(path + "/") || path.hasPrefix(key + "/") {
                entrySizes.removeValue(forKey: key)
                entryCounts.removeValue(forKey: key)
            }
        }
    }

    init(containerPath: String) {
        self.containerPath = containerPath
    }

    func size(of paths: [String]) -> Int64 {
        paths.reduce(0) { $0 + (entrySizes[$1] ?? 0) }
    }

    var selectedNormalPaths: [String] {
        selectedPaths.filter { !ContainerInventoryService.isProtected(relativePath: $0) }.sorted()
    }

    var selectedProtectedPaths: [String] {
        selectedPaths.filter { ContainerInventoryService.isProtected(relativePath: $0) }.sorted()
    }
}

struct CleanerAppInventoryRoot: View {
    let appName: String
    let bundleID: String
    let containerPath: String
    @StateObject private var model: CleanerInventoryModel

    init(appName: String, bundleID: String, containerPath: String) {
        self.appName = appName
        self.bundleID = bundleID
        self.containerPath = containerPath
        _model = StateObject(wrappedValue: CleanerInventoryModel(containerPath: containerPath))
    }

    var body: some View {
        CleanerAppDetailView(
            appName: appName,
            bundleID: bundleID,
            relativePath: "",
            model: model
        )
        .onAppear {
            // Make sure the worse_query grant for this container is held
            // before any listing or deletion happens below. The model
            // deduplicates: reappearing after a pop does not re-grant.
            model.ensureGrant()
        }
    }
}

struct CleanerAppDetailView: View {
    let appName: String
    let bundleID: String
    let relativePath: String
    @ObservedObject var model: CleanerInventoryModel

    @State private var entries: [InventoryEntry] = []
    @State private var measuredPaths = Set<String>()
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var pendingUnlock: InventoryEntry?
    @State private var pendingBatch: BatchKind?
    @State private var resultMessage: String?
    @State private var isCleaning = false

    private enum BatchKind: Identifiable {
        case normal
        case protectedItems
        var id: String { self == .normal ? "normal" : "protected" }
    }

    private var title: String {
        if relativePath.isEmpty { return appName }
        return (relativePath as NSString).lastPathComponent
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("正在盘点…").foregroundStyle(.secondary)
                }
            } else if entries.isEmpty {
                Text("这一层是空的").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                } header: {
                    if relativePath.isEmpty {
                        Text(bundleID).textCase(nil)
                    } else {
                        Text(relativePath).textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isLoading, !entries.isEmpty, measuredPaths.count < entries.count {
                ProgressView(value: Double(measuredPaths.count), total: Double(entries.count))
                    .progressViewStyle(.linear)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !model.selectedPaths.isEmpty {
                batchBar
            }
        }
        .onAppear { loadLevel() }
        .alert(item: $pendingUnlock) { entry in
            Alert(
                title: Text("解锁保护项"),
                message: Text("「\(entry.name)」属于受保护数据，删错可能导致该 App 丢账号或存档。解锁后仅在本次页面内可勾选。"),
                primaryButton: .destructive(Text("解锁")) {
                    model.unlockedPaths.insert(entry.relativePath)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .alert(item: $pendingBatch) { batch in
            batchAlert(batch)
        }
        .alert("清理结果", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("完成") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var batchBar: some View {
        VStack(spacing: 8) {
            let normal = model.selectedNormalPaths
            if !normal.isEmpty {
                Button {
                    pendingBatch = .normal
                } label: {
                    Label(
                        "清理普通项 \(normal.count) 个 · \(sizeText(model.size(of: normal)))",
                        systemImage: "trash"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCleaning)
            }
            let protectedItems = model.selectedProtectedPaths
            if !protectedItems.isEmpty {
                Button {
                    pendingBatch = .protectedItems
                } label: {
                    Label(
                        "清理保护项 \(protectedItems.count) 个 · \(sizeText(model.size(of: protectedItems)))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isCleaning)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func batchAlert(_ batch: BatchKind) -> Alert {
        switch batch {
        case .normal:
            let paths = model.selectedNormalPaths
            return Alert(
                title: Text("清理普通项"),
                message: Text("将删除 \(paths.count) 项，共 \(sizeText(model.size(of: paths)))。此操作不可恢复。"),
                primaryButton: .destructive(Text("清理")) {
                    runDeletion(paths: paths)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .protectedItems:
            let paths = model.selectedProtectedPaths
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            return Alert(
                title: Text("⚠️ 清理保护项"),
                message: Text("以下受保护数据将被永久删除：\(names)。删错可能导致该 App 丢账号或存档，确认继续？"),
                primaryButton: .destructive(Text("确认删除")) {
                    runDeletion(paths: paths)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private func entryRow(_ entry: InventoryEntry) -> some View {
        // Navigation goes through an invisible background link so the whole
        // row drills in, while the checkbox/lock stays an independent
        // control on top. A row-level long-press gesture previously sat on
        // the same container and swallowed the link's taps; unlocking now
        // happens by tapping the lock itself.
        ZStack {
            if entry.isDirectory {
                NavigationLink {
                    CleanerAppDetailView(
                        appName: appName,
                        bundleID: bundleID,
                        relativePath: entry.relativePath,
                        model: model
                    )
                } label: {
                    EmptyView()
                }
                .opacity(0)
            }
            HStack(spacing: 10) {
                selectionControl(entry)
                entryContent(entry)
            }
        }
        .contentShape(Rectangle())
    }

    private func entryContent(_ entry: InventoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(measuredPaths.contains(entry.relativePath) || !entry.isDirectory
                ? sizeText(entry.bytes)
                : "计算中")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func subtitle(_ entry: InventoryEntry) -> String {
        if entry.isSymlink { return "符号链接 · 不跟随" }
        if !entry.isDirectory { return "文件" }
        return measuredPaths.contains(entry.relativePath)
            ? "\(entry.itemCount) 个文件"
            : "正在统计…"
    }

    @ViewBuilder
    private func selectionControl(_ entry: InventoryEntry) -> some View {
        if entry.isSymlink {
            Image(systemName: "link")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .frame(width: 26)
        } else if entry.isProtected && !model.unlockedPaths.contains(entry.relativePath) {
            Button {
                pendingUnlock = entry
            } label: {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                toggleSelection(entry)
            } label: {
                Image(systemName: model.selectedPaths.contains(entry.relativePath)
                    ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(model.selectedPaths.contains(entry.relativePath)
                        ? (entry.isProtected ? Color.red : Color.accentColor)
                        : Color.secondary)
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleSelection(_ entry: InventoryEntry) {
        if model.selectedPaths.contains(entry.relativePath) {
            model.selectedPaths.remove(entry.relativePath)
        } else {
            model.selectedPaths.insert(entry.relativePath)
        }
    }

    private func loadLevel() {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        measuredPaths = []
        let containerPath = model.containerPath
        let level = relativePath
        DispatchQueue.global(qos: .userInitiated).async {
            // Shallow first: the level renders instantly even above a
            // multi-GB subtree; recursive sizing streams in per entry.
            let shallow = ContainerInventoryService.shallowEntries(
                containerPath: containerPath,
                relativePath: level
            )
            DispatchQueue.main.async {
                guard loadGeneration == generation else { return }
                entries = shallow
                isLoading = false
                // Sizes measured earlier in this inventory session are
                // cached on the model: reappearing on a level (popping
                // back from a deeper level, switching tabs) reuses them
                // and measures only what is missing or was invalidated
                // by a deletion -- no level is ever re-measured whole.
                var pending: [InventoryEntry] = []
                for entry in shallow {
                    if !entry.isDirectory {
                        measuredPaths.insert(entry.relativePath)
                        model.entrySizes[entry.relativePath] = entry.bytes
                        model.entryCounts[entry.relativePath] = entry.itemCount
                    } else if let cachedBytes = model.entrySizes[entry.relativePath] {
                        if let rowIndex = entries.firstIndex(where: { $0.id == entry.id }) {
                            entries[rowIndex].bytes = cachedBytes
                            entries[rowIndex].itemCount = model.entryCounts[entry.relativePath] ?? entry.itemCount
                        }
                        measuredPaths.insert(entry.relativePath)
                    } else {
                        pending.append(entry)
                    }
                    applyDefaultSelection(entry)
                }
                if pending.isEmpty {
                    sortEntries()
                } else {
                    measurePending(pending, containerPath: containerPath, generation: generation)
                }
            }
        }
    }

    private func measurePending(_ pending: [InventoryEntry], containerPath: String, generation: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: pending.count) { index in
                let entry = pending[index]
                guard let measured = ContainerInventoryService.measureEntry(
                    containerPath: containerPath,
                    relativePath: entry.relativePath
                ) else {
                    return
                }
                DispatchQueue.main.async {
                    guard loadGeneration == generation else { return }
                    if let rowIndex = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[rowIndex].bytes = measured.bytes
                        entries[rowIndex].itemCount = measured.itemCount
                    }
                    measuredPaths.insert(entry.relativePath)
                    model.entrySizes[entry.relativePath] = measured.bytes
                    model.entryCounts[entry.relativePath] = measured.itemCount
                }
            }
            DispatchQueue.main.async {
                guard loadGeneration == generation else { return }
                sortEntries()
            }
        }
    }

    private func sortEntries() {
        entries.sort {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func applyDefaultSelection(_ entry: InventoryEntry) {
        if model.defaultsApplied.insert(entry.relativePath).inserted,
           !entry.isProtected,
           !entry.isSymlink,
           ContainerInventoryService.isDefaultSelected(relativePath: entry.relativePath) {
            model.selectedPaths.insert(entry.relativePath)
        }
    }

    private func runDeletion(paths: [String]) {
        guard !isCleaning else { return }
        isCleaning = true
        let containerPath = model.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
            // Grants can go stale while the user browses levels; renew
            // this container's grant immediately before deleting.
            _ = ContainerStore.retainContainerAccess(containerPath)
            let result = ContainerInventoryService.delete(
                containerPath: containerPath,
                relativePaths: paths
            )
            DispatchQueue.main.async {
                isCleaning = false
                for path in paths {
                    model.selectedPaths.remove(path)
                }
                resultMessage = "已释放 \(sizeText(result.freedBytes))，删除 \(result.removedItemCount) 个文件，失败 \(result.failedItemCount) 个。"
                // The main list cannot observe this deletion; mark the
                // app dirty so its row is re-measured when it reappears.
                CleanerRefreshCenter.shared.markDirty(bundleID: bundleID)
                model.invalidateSizes(forPaths: paths)
                loadLevel()
            }
        }
    }

    private func sizeText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
