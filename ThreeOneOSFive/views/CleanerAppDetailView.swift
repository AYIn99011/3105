import SwiftUI

/// Shared selection state for one app's inventory. Lives as long as the
/// user stays inside the app's drill-down stack; leaving the app locks
/// protected entries again and drops the selection.
final class CleanerInventoryModel: ObservableObject {
    let containerPath: String
    @Published var selectedPaths = Set<String>()
    @Published var unlockedPaths = Set<String>()
    var entrySizes: [String: Int64] = [:]
    var defaultsApplied = Set<String>()

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
            // before any listing or deletion happens below.
            let path = containerPath
            DispatchQueue.global(qos: .userInitiated).async {
                _ = ContainerStore.retainContainerAccess(path)
            }
        }
    }
}

struct CleanerAppDetailView: View {
    let appName: String
    let bundleID: String
    let relativePath: String
    @ObservedObject var model: CleanerInventoryModel

    @State private var entries: [InventoryEntry] = []
    @State private var isLoading = true
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
        HStack(spacing: 10) {
            selectionControl(entry)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.isDirectory
                    ? "\(entry.itemCount) 个文件"
                    : (entry.isSymlink ? "符号链接 · 不跟随" : "文件"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(sizeText(entry.bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if entry.isDirectory {
                NavigationLink {
                    CleanerAppDetailView(
                        appName: appName,
                        bundleID: bundleID,
                        relativePath: entry.relativePath,
                        model: model
                    )
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 22)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture {
            if entry.isProtected && !model.unlockedPaths.contains(entry.relativePath) {
                pendingUnlock = entry
            }
        }
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
        isLoading = true
        let containerPath = model.containerPath
        let level = relativePath
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ContainerInventoryService.listLevel(
                containerPath: containerPath,
                relativePath: level
            )
            DispatchQueue.main.async {
                entries = loaded
                isLoading = false
                for entry in loaded {
                    model.entrySizes[entry.relativePath] = entry.bytes
                    if model.defaultsApplied.insert(entry.relativePath).inserted,
                       !entry.isProtected,
                       !entry.isSymlink,
                       ContainerInventoryService.isDefaultSelected(relativePath: entry.relativePath) {
                        model.selectedPaths.insert(entry.relativePath)
                    }
                }
            }
        }
    }

    private func runDeletion(paths: [String]) {
        guard !isCleaning else { return }
        isCleaning = true
        let containerPath = model.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
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
                loadLevel()
            }
        }
    }

    private func sizeText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
