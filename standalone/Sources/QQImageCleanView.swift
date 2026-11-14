import SwiftUI
import UIKit
import ImageIO

// MARK: - QQ chat image cleaner
//
// A dedicated tab for QQ (com.tencent.mqq): discovers the chat-image
// directories inside QQ's data container by directory-name features
// (the layout is never hardcoded — every hit is logged so the first
// run can be cross-checked against QQ's own image count), then shows
// the images in a thumbnail grid with long-press brush selection and
// a confirm-then-delete flow. Deletion goes through the inventory
// service's fd-relative machinery, one relative path per file.

struct QQImageItem: Identifiable, Equatable {
    let relativePath: String
    let size: Int64
    var id: String { relativePath }
}

enum QQImageScanner {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"
    ]

    /// Directory names (lowercased) treated as chat-image stores.
    static func isChatImageDirectory(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("qq_images") || n.contains("image_cache") { return true }
        if n.contains("chat_image") || n.contains("chatimage") { return true }
        if n == "image" || n == "images" || n == "picture" || n == "pictures" { return true }
        return false
    }

    static func isImageFile(at path: String, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return true }
        guard ext.isEmpty else { return false }
        // Extensionless files inside a chat-image directory are common
        // (hash-named payloads); sniff the magic header before counting
        // them as images.
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 3 else { return false }
        let b = [UInt8](head)
        if b[0] == 0xFF && b[1] == 0xD8 { return true }                       // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E { return true }       // PNG
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return true }       // GIF
        if head.count >= 12,
           b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return true } // HEIC ftyp
        if head.count >= 12,
           b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46,
           b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 { return true }      // WEBP
        return false
    }

    /// Walks the container once, collecting image files under matched
    /// chat-image directories. Also returns per-directory statistics
    /// for every image-named directory (matched or not) for the log.
    static func scan(containerPath: String)
        -> (items: [QQImageItem], matchedDirs: [String], candidateStats: [(String, Int, Int64)])
    {
        let root = containerPath as NSString
        // Pass 1: discover directories.
        var allDirs: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: containerPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                allDirs.append(url.path)
            }
        }
        let matched = allDirs.filter { isChatImageDirectory(($0 as NSString).lastPathComponent) }
        // Drop matched dirs nested inside another matched dir.
        let matchedSet = Set(matched)
        let topMatched = matched.filter { dir in
            var parent = (dir as NSString).deletingLastPathComponent
            while parent.hasPrefix(containerPath) && parent != containerPath {
                if matchedSet.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }

        // Pass 2: collect files under matched dirs; gather stats for
        // every directory whose name mentions images.
        var items: [QQImageItem] = []
        var stats: [String: (count: Int, bytes: Int64)] = [:]
        for dir in topMatched {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let name = url.lastPathComponent
                guard isImageFile(at: url.path, name: name) else { continue }
                let size = Int64(values?.fileSize ?? 0)
                let relative = String(url.path.dropFirst(root.length + 1))
                items.append(QQImageItem(relativePath: relative, size: size))
            }
        }
        for dir in allDirs where (dir as NSString).lastPathComponent.lowercased().contains("image") {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var count = 0
            var bytes: Int64 = 0
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                count += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
            if count > 0 {
                stats[String(dir.dropFirst(root.length + 1))] = (count, bytes)
            }
        }
        items.sort { $0.size > $1.size }
        let candidates = stats
            .map { ($0.key, $0.value.count, $0.value.bytes) }
            .sorted { $0.2 > $1.2 }
        return (items, topMatched.map { String($0.dropFirst(root.length + 1)) }, candidates)
    }
}

enum QQThumbnailLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func load(path: String, maxPixel: Int, completion: @escaping (UIImage?) -> Void) {
        let key = "\(path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = makeThumbnail(path: path, maxPixel: maxPixel)
            if let image { cache.setObject(image, forKey: key) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func makeThumbnail(path: String, maxPixel: Int) -> UIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

@MainActor
final class QQImageModel: ObservableObject {
    @Published var items: [QQImageItem] = []
    @Published var selected: Set<String> = []
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var statusText: String?
    @Published var resultText: String?
    private(set) var containerPath: String?
    private var didLoad = false

    static let qqBundleID = "com.tencent.mqq"

    var selectedItems: [QQImageItem] { items.filter { selected.contains($0.relativePath) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        Task { await load() }
    }

    func reload() {
        Task { await load() }
    }

    private nonisolated func resolveContainer() -> String? {
        if let path = ContainerStore.resolveAppContainerPath(bundleID: Self.qqBundleID) {
            return path
        }
        // Targeted fallback: walk the app-data root and identify QQ's
        // container by its preferences file, like the main scan does.
        let root = "/var/mobile/Containers/Data/Application"
        for dir in ContainerStore.enumerateDirectories(path: root) {
            let canonical = ContainerDiscoveryMerger.canonicalPath(dir)
            let handle = ContainerStore.grantContainerAccess(canonical, logFailure: false)
            guard handle >= 0 else { continue }
            let prefs = (canonical as NSString).appendingPathComponent("Library/Preferences")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: prefs)) ?? []
            if names.contains(Self.qqBundleID + ".plist") {
                _ = ContainerStore.retainContainerAccess(canonical)
                log("qqimg: container resolved by prefs scan -> \(canonical)")
                return canonical
            }
            worse_query_release(handle)
        }
        return nil
    }

    func load() async {
        isScanning = true
        statusText = nil
        resultText = nil
        let resolved = await Task.detached(priority: .userInitiated) { [self] in
            resolveContainer()
        }.value
        guard let container = resolved else {
            isScanning = false
            statusText = "没有找到 QQ 的数据容器。"
            log("qqimg: container not found")
            return
        }
        containerPath = container
        _ = ContainerStore.retainContainerAccess(container)
        let scan = await Task.detached(priority: .userInitiated) {
            QQImageScanner.scan(containerPath: container)
        }.value
        items = scan.items
        selected.removeAll()
        isScanning = false
        for dir in scan.matchedDirs {
            log("qqimg: matched dir \(dir)")
        }
        for (dir, count, bytes) in scan.candidateStats.prefix(20) {
            log("qqimg: image-dir candidate \(dir) files=\(count) bytes=\(bytes)")
        }
        log("qqimg: total images=\(scan.items.count) bytes=\(scan.items.reduce(0) { $0 + $1.size })")
        if scan.items.isEmpty {
            statusText = "没有发现聊天图片目录。把日志发我，我对着目录名单调匹配规则。"
        }
    }

    func toggle(_ item: QQImageItem) {
        if selected.contains(item.relativePath) {
            selected.remove(item.relativePath)
        } else {
            selected.insert(item.relativePath)
        }
    }

    func deleteSelected() async {
        guard let container = containerPath, !selected.isEmpty else { return }
        isDeleting = true
        let paths = items.filter { selected.contains($0.relativePath) }.map(\.relativePath)
        let result = await Task.detached(priority: .userInitiated) {
            ContainerInventoryService.delete(containerPath: container, relativePaths: paths)
        }.value
        let removedPaths = Set(paths)
        items.removeAll { removedPaths.contains($0.relativePath) && result.failedItemCount == 0 }
        if result.failedItemCount > 0 {
            // Keep the list honest: rescan rather than guess which failed.
            isDeleting = false
            resultText = "删除完成：成功 \(result.removedItemCount) 张，失败 \(result.failedItemCount) 张，已释放 \(Self.format(result.freedBytes))。正在重新扫描…"
            CleanerRefreshCenter.shared.markDirty(bundleID: Self.qqBundleID)
            await load()
            return
        }
        selected.removeAll()
        isDeleting = false
        resultText = "已删除 \(result.removedItemCount) 张，释放 \(Self.format(result.freedBytes))。"
        CleanerRefreshCenter.shared.markDirty(bundleID: Self.qqBundleID)
        log("qqimg: deleted=\(result.removedItemCount) failed=\(result.failedItemCount) freed=\(result.freedBytes)")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


// MARK: - Views

private struct QQCellFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct QQThumbCell: View {
    let absolutePath: String
    let sizeText: String
    let selected: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Color.secondary.opacity(0.15)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            Text(sizeText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(3)
        }
        .overlay {
            if selected {
                Rectangle().stroke(Color.accentColor, lineWidth: 3)
                Color.accentColor.opacity(0.18)
            }
        }
        .clipped()
        .task(id: absolutePath) {
            image = nil
            QQThumbnailLoader.load(path: absolutePath, maxPixel: 320) { loaded in
                image = loaded
            }
        }
    }
}

private struct QQImagePreviewView: View {
    let absolutePath: String
    let sizeText: String
    let isSelected: Bool
    let onToggleSelect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .padding()
                }
                Spacer()
                HStack(spacing: 16) {
                    Text(sizeText).foregroundStyle(.white)
                    Button(isSelected ? "取消选中" : "选中这张") { onToggleSelect() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .task {
            QQThumbnailLoader.load(path: absolutePath, maxPixel: 1600) { loaded in
                image = loaded
            }
        }
    }
}

struct QQImageCleanView: View {
    @StateObject private var model = QQImageModel()
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var brushAnchor: Int?
    @State private var brushCurrent: Int?
    @State private var brushTarget = true
    @State private var brushBase: Set<String> = []
    @State private var brushing = false
    @State private var previewItem: QQImageItem?
    @State private var confirmDelete = false

    private let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 3), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                grid
            }
            .navigationTitle("QQ 聊天图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isScanning || model.isDeleting)
                }
            }
        }
        .onAppear { model.loadIfNeeded() }
        .confirmationDialog(
            "删除 \(model.selectedItems.count) 张图片？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(QQImageModel.format(model.selectedBytes))，删除后不可恢复。建议先关闭 QQ 再删。")
        }
        .alert("清理结果", isPresented: resultPresented) {
            Button("好") { model.resultText = nil }
        } message: {
            Text(model.resultText ?? "")
        }
        .fullScreenCover(item: $previewItem) { item in
            QQImagePreviewView(
                absolutePath: absolutePath(for: item),
                sizeText: QQImageModel.format(item.size),
                isSelected: effectiveSelected(item),
                onToggleSelect: { model.toggle(item) }
            )
        }
    }

    private var resultPresented: Binding<Bool> {
        Binding(
            get: { model.resultText != nil },
            set: { if !$0 { model.resultText = nil } }
        )
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                if model.isScanning {
                    ProgressView()
                    Text("正在扫描 QQ 聊天图片…")
                } else {
                    Text("共 \(model.items.count) 张 · \(QQImageModel.format(model.totalBytes))")
                }
                Spacer()
                if !model.selected.isEmpty {
                    Text("已选 \(model.selectedItems.count) 张 · \(QQImageModel.format(model.selectedBytes))")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.subheadline)
            HStack(spacing: 10) {
                Button("全选") {
                    model.selected = Set(model.items.map(\.relativePath))
                }
                .disabled(model.items.isEmpty || brushing)
                Button("清空选择") { model.selected.removeAll() }
                    .disabled(model.selected.isEmpty || brushing)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    if model.isDeleting {
                        ProgressView()
                    } else {
                        Text("删除").bold()
                    }
                }
                .disabled(model.selected.isEmpty || model.isDeleting || brushing)
            }
            .font(.subheadline)
            if let status = model.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.items.isEmpty && !model.isScanning {
                    ContentUnavailableView(
                        "没有图片",
                        systemImage: "photo.slash",
                        description: Text(model.statusText ?? "未发现聊天图片。")
                    )
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            cell(index: index, item: item)
                        }
                    }
                    .padding(3)
                    .onPreferenceChange(QQCellFrameKey.self) { frames in
                        cellFrames = frames
                    }
                    .gesture(brushGesture(proxy: proxy))
                }
            }
            .coordinateSpace(name: "QQGRID")
            .scrollDisabled(brushing)
        }
    }

    private func cell(index: Int, item: QQImageItem) -> some View {
        let selected = effectiveSelected(index: index, item: item)
        return ZStack(alignment: .topTrailing) {
            QQThumbCell(
                absolutePath: absolutePath(for: item),
                sizeText: QQImageModel.format(item.size),
                selected: selected
            )
            .onTapGesture { previewItem = item }

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? Color.accentColor : .white)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(item) }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: QQCellFrameKey.self,
                    value: [index: geo.frame(in: .named("QQGRID"))]
                )
            }
        )
        .id(item.id)
    }

    // MARK: Brush selection

    private func effectiveSelected(index: Int, item: QQImageItem) -> Bool {
        if let anchor = brushAnchor, let current = brushCurrent {
            let range = min(anchor, current)...max(anchor, current)
            if range.contains(index) { return brushTarget }
            return brushBase.contains(item.relativePath)
        }
        return model.selected.contains(item.relativePath)
    }

    private func effectiveSelected(_ item: QQImageItem) -> Bool {
        if let index = model.items.firstIndex(of: item) {
            return effectiveSelected(index: index, item: item)
        }
        return model.selected.contains(item.relativePath)
    }

    private func indexAt(_ point: CGPoint) -> Int? {
        if let hit = cellFrames.first(where: { $0.value.contains(point) })?.key {
            return hit
        }
        return cellFrames.min { a, b in
            let da = hypot(a.value.midX - point.x, a.value.midY - point.y)
            let db = hypot(b.value.midX - point.x, b.value.midY - point.y)
            return da < db
        }?.key
    }

    private func brushGesture(proxy: ScrollViewProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("QQGRID")))
            .onChanged { value in
                guard case .second(true, let drag?) = value, let drag else { return }
                guard let index = indexAt(drag.location) else { return }
                if brushAnchor == nil {
                    brushAnchor = index
                    brushBase = model.selected
                    brushTarget = !brushBase.contains(model.items[index].relativePath)
                    brushing = true
                }
                brushCurrent = index
                // Edge auto-scroll while brushing.
                if let maxRendered = cellFrames.keys.max(),
                   index >= maxRendered, maxRendered < model.items.count - 1 {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(model.items[maxRendered].id, anchor: .bottom)
                    }
                } else if let minRendered = cellFrames.keys.min(),
                          index <= minRendered, minRendered > 0 {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(model.items[minRendered].id, anchor: .top)
                    }
                }
            }
            .onEnded { _ in
                if let anchor = brushAnchor, let current = brushCurrent {
                    var next = brushBase
                    let range = min(anchor, current)...max(anchor, current)
                    for i in range where model.items.indices.contains(i) {
                        if brushTarget {
                            next.insert(model.items[i].relativePath)
                        } else {
                            next.remove(model.items[i].relativePath)
                        }
                    }
                    model.selected = next
                }
                brushAnchor = nil
                brushCurrent = nil
                brushing = false
            }
    }

    private func absolutePath(for item: QQImageItem) -> String {
        guard let container = model.containerPath else { return item.relativePath }
        return (container as NSString).appendingPathComponent(item.relativePath)
    }
}
