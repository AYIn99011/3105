//
//  AppTypeCleanView.swift
//  Qingsao
//
//  Long-press an app in the cleaner list and clean it by folder type
//  instead of drilling level by level. Classification is two-layered:
//  layer 1 is location semantics from Apple's File System Programming
//  Guide (tmp and Library/Caches are regenerable by design; Documents
//  and Library/Application Support are persistent, backup-included
//  areas that must not be bulk-treated), layer 2 classifies the custom
//  folders inside the persistent areas by framework/SDK naming, with
//  database and account classes locked out of this panel (they stay on
//  the detail page's unlock flow).
//

import SwiftUI

enum FolderType: String, CaseIterable, Identifiable {
    case cache
    case dynamicPackage
    case logs
    case modelsAssets
    case webData
    case userContent
    case other
    case database
    case accountConfig

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cache: return "缓存"
        case .dynamicPackage: return "动态包"
        case .logs: return "日志埋点"
        case .modelsAssets: return "模型素材"
        case .webData: return "网页数据"
        case .userContent: return "用户内容"
        case .other: return "其他"
        case .database: return "数据库"
        case .accountConfig: return "账户配置"
        }
    }

    var isLocked: Bool { self == .database || self == .accountConfig }

    var defaultSelected: Bool {
        switch self {
        case .cache, .dynamicPackage, .logs, .modelsAssets: return true
        default: return false
        }
    }

    var sortRank: Int {
        switch self {
        case .cache: return 0
        case .dynamicPackage: return 1
        case .logs: return 2
        case .modelsAssets: return 3
        case .webData: return 4
        case .userContent: return 5
        case .other: return 6
        case .database: return 7
        case .accountConfig: return 8
        }
    }
}

enum FolderTypeClassifier {
    /// Names whose literal text misleads the keyword rules.
    private static let exactOverrides: [String: FolderType] = [
        "NebulaAppBiz": .other,
    ]

    static func classify(entry: InventoryEntry) -> FolderType {
        let path = entry.relativePath
        let name = entry.name
        let lower = name.lowercased()

        // Layer 1: location semantics.
        if path == "tmp" || path.hasPrefix("tmp/") { return .cache }
        if path == "Library/Caches" || path.hasPrefix("Library/Caches/") { return .cache }
        if path == "Library/Preferences" || path.hasPrefix("Library/Preferences/") {
            return .accountConfig
        }
        // Items the inventory already flags as protected stay locked.
        if entry.isProtected {
            return lower.contains("mmkv") ? .database : .accountConfig
        }
        if let exact = exactOverrides[name] { return exact }

        // Layer 2: framework naming. Locked classes first.
        if lower.contains("passport") || lower.contains("account") { return .accountConfig }
        if lower == "cfg" || lower.contains("config")
            || lower == "contact" || lower.contains("contacts") { return .accountConfig }
        // Telemetry stores are logs even when they are sqlite files.
        if lower.contains("tracker") || lower.contains("utmc")
            || lower.contains("analytics") || lower.contains("heimdallr") { return .logs }
        if lower.contains("mmkv") || lower.contains("database") || lower == "databases"
            || lower.hasSuffix(".sqlite") || lower.hasSuffix(".sqlite-wal")
            || lower.hasSuffix(".sqlite-shm") || lower.hasSuffix(".db")
            || lower.contains("storage") { return .database }
        if lower.contains("draft") { return .userContent }
        if lower == "webkit" || lower == "httpstorages" || lower == "cookies"
            || lower == "splashboard" || lower == "saved application state" { return .webData }
        if lower == "logs" || lower == "log" || lower.contains("_log") || lower.hasPrefix("log_")
            || lower.contains("logging") || lower.contains("crash")
            || lower.contains("applog") || lower.contains("monitor") { return .logs }
        if lower.contains("pitaya") || lower.contains("voice") || lower.contains("model")
            || lower.contains("render") || lower.contains("emotion")
            || lower.contains("effect") || lower.contains("gesture") { return .modelsAssets }
        if lower.contains("webapp") || lower.contains("ajx") || lower.contains("nebula")
            || lower.contains("namapp") || lower == "drb" || lower.contains("lynx")
            || lower.contains("h5") || lower.contains("cloudres")
            || lower.contains("offline") || lower.contains("download")
            || lower.contains("hybrid") { return .dynamicPackage }
        if lower.contains("cache") { return .cache }
        return .other
    }
}

struct AppTypeCleanView: View {
    let app: InstalledApp

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [TypeGroup] = []
    @State private var selectedTypes = Set<FolderType>()
    @State private var isScanning = true
    @State private var isCleaning = false
    @State private var cleaningTypeTitle: String?
    @State private var showConfirm = false
    @State private var resultMessage: String?

    struct TypeGroup: Identifiable {
        let type: FolderType
        var paths: [String] = []
        var totalBytes: Int64 = 0
        var itemCount: Int = 0
        var id: FolderType { type }
    }

    private var selectedBytes: Int64 {
        groups.filter { selectedTypes.contains($0.type) }.reduce(0) { $0 + $1.totalBytes }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if isScanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在按类型盘点…")
                                .foregroundStyle(.secondary)
                        }
                    } else if groups.isEmpty {
                        Text("没有可分类的文件夹")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        typeRow(group)
                    }
                } footer: {
                    Text("按位置语义与文件夹命名分类。带锁的数据库与账户配置不在此清理，请到详情页解锁后处理；「其他」是无法归类的文件夹，默认不勾选。")
                }

                if isCleaning {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在清理\(cleaningTypeTitle ?? "")…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(app.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isCleaning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !isScanning, selectedBytes > 0 {
                    Button(role: .destructive) {
                        showConfirm = true
                    } label: {
                        Label("清理所选类型 · \(sizeText(selectedBytes))", systemImage: "trash")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isCleaning)
                    .padding()
                }
            }
            .alert("按类型清理", isPresented: $showConfirm) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) { clean() }
            } message: {
                let names = groups.filter { selectedTypes.contains($0.type) }
                    .map(\.type.title).joined(separator: "、")
                Text("将删除 \(app.displayName) 的「\(names)」，共 \(sizeText(selectedBytes))。")
            }
            .alert("清理结果", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("好") { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
            .onAppear { scan() }
        }
    }

    private func typeRow(_ group: TypeGroup) -> some View {
        let locked = group.type.isLocked
        let selected = selectedTypes.contains(group.type)
        return HStack(spacing: 10) {
            Image(systemName: locked ? "lock.fill" : (selected ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(locked ? Color.secondary : (selected ? Color.accentColor : Color.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.type.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(group.paths.count) 个文件夹 · \(group.itemCount) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(sizeText(group.totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !locked, !isCleaning, !isScanning else { return }
            if selected { selectedTypes.remove(group.type) } else { selectedTypes.insert(group.type) }
        }
    }

    private func sizeText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    // MARK: - Scan

    private func scan() {
        isScanning = true
        let path = app.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = Self.scanGroups(containerPath: path)
            DispatchQueue.main.async {
                groups = scanned
                selectedTypes = Set(scanned.filter { $0.type.defaultSelected && !$0.type.isLocked }.map(\.type))
                isScanning = false
            }
        }
    }

    /// Classification units: the children of tmp, of Library/Caches and of
    /// Documents, plus Library's own children, with Application Support
    /// expanded one level (its bundle-named children classify as .other
    /// rather than dragging the whole directory into one bucket).
    private static func scanGroups(containerPath: String) -> [TypeGroup] {
        _ = ContainerStore.retainContainerAccess(containerPath)
        var units: [InventoryEntry] = []
        let root = ContainerInventoryService.listLevel(containerPath: containerPath, relativePath: "")
        for entry in root {
            switch entry.name {
            case "tmp":
                units.append(contentsOf: ContainerInventoryService.listLevel(
                    containerPath: containerPath, relativePath: "tmp"))
            case "Library":
                for child in ContainerInventoryService.listLevel(
                    containerPath: containerPath, relativePath: "Library") {
                    if child.name == "Caches" {
                        units.append(contentsOf: ContainerInventoryService.listLevel(
                            containerPath: containerPath, relativePath: "Library/Caches"))
                    } else if child.name == "Application Support" {
                        units.append(contentsOf: ContainerInventoryService.listLevel(
                            containerPath: containerPath, relativePath: "Library/Application Support"))
                    } else {
                        units.append(child)
                    }
                }
            case "Documents":
                units.append(contentsOf: ContainerInventoryService.listLevel(
                    containerPath: containerPath, relativePath: "Documents"))
            default:
                units.append(entry)
            }
        }
        var byType: [FolderType: TypeGroup] = [:]
        for unit in units where !unit.isSymlink {
            let type = FolderTypeClassifier.classify(entry: unit)
            var group = byType[type] ?? TypeGroup(type: type)
            group.paths.append(unit.relativePath)
            group.totalBytes += unit.bytes
            group.itemCount += unit.itemCount
            byType[type] = group
        }
        return byType.values
            .filter { $0.itemCount > 0 || $0.totalBytes > 0 }
            .sorted { $0.type.sortRank < $1.type.sortRank }
    }

    // MARK: - Clean

    private func clean() {
        let targets = groups.filter { selectedTypes.contains($0.type) && !$0.type.isLocked }
        guard !targets.isEmpty else { return }
        isCleaning = true
        let path = app.containerPath
        let bundleID = app.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            var removed = 0
            var failed = 0
            var freed: Int64 = 0
            for group in targets {
                DispatchQueue.main.async { cleaningTypeTitle = group.type.title }
                let result = ContainerInventoryService.delete(
                    containerPath: path, relativePaths: group.paths)
                removed += result.removedItemCount
                failed += result.failedItemCount
                freed += result.freedBytes
            }
            CleanerRefreshCenter.shared.markDirty(bundleID: bundleID)
            let rescanned = Self.scanGroups(containerPath: path)
            DispatchQueue.main.async {
                groups = rescanned
                selectedTypes = Set(rescanned.filter { $0.type.defaultSelected && !$0.type.isLocked }.map(\.type))
                isCleaning = false
                cleaningTypeTitle = nil
                resultMessage = "已释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))，删除 \(removed) 项，失败 \(failed) 项。"
            }
        }
    }
}
