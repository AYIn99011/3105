import SwiftUI
import UIKit
import ImageIO

// MARK: - System wallpaper viewer (PosterBoard)
//
// Read-only tab: locates PosterBoard's data container through the
// same worse_query machinery as the cleaner, lists every image file
// inside it (standard formats plus Apple's raw .cpbitmap renders),
// previews them with size and modification time, and exports copies
// through the share sheet. Nothing here deletes or writes inside
// the PosterBoard container: exports are rendered into this app's
// own temporary directory first.

struct WallpaperItem: Identifiable, Equatable {
    let relativePath: String
    let size: Int64
    let modified: Date
    let isCPBitmap: Bool
    var id: String { relativePath }
    var fileName: String { (relativePath as NSString).lastPathComponent }
}

// MARK: - cpbitmap decoding

enum CPBitmapDecoder {
    /// .cpbitmap files are headerless BGRA32 dumps: rows are stored
    /// bottom-up, the pixel width is padded up to a multiple of 16,
    /// and newer files append a binary plist carrying the real
    /// dimensions. Every attempt is logged so a device run confirms
    /// which layout matched.
    static func decode(path: String) -> UIImage? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let name = (path as NSString).lastPathComponent
        var pixelBytes = data.count
        var plistWidth: Int?
        var plistHeight: Int?
        if let dims = trailingPlistDimensions(in: data) {
            plistWidth = dims.width
            plistHeight = dims.height
            pixelBytes = data.count - dims.trailerLength
            log("wallpaper: cpbitmap \(name) plist dims \(dims.width)x\(dims.height) trailer=\(dims.trailerLength)")
        }
        var widths: [Int] = []
        if let w = plistWidth { widths.append(w) }
        widths += [1320, 1290, 1260, 1206, 1179, 1170, 1284, 1242, 1125, 1080, 828, 750]
        for w in widths where w > 0 {
            for stride in candidateStrides(width: w) {
                guard stride > 0, pixelBytes > 0, pixelBytes % stride == 0 else { continue }
                let h = pixelBytes / stride
                guard h > 0 else { continue }
                if let fixed = plistHeight, h != fixed { continue }
                let ratio = Double(h) / Double(w)
                guard ratio > 0.3, ratio < 3.5 else { continue }
                if let image = render(data: data, pixelBytes: pixelBytes, width: w, height: h, stride: stride) {
                    log("wallpaper: cpbitmap \(name) decoded \(w)x\(h) stride=\(stride)")
                    return image
                }
            }
        }
        log("wallpaper: cpbitmap \(name) decode failed bytes=\(data.count)")
        return nil
    }

    private static func candidateStrides(width w: Int) -> [Int] {
        var out: [Int] = []
        for s in [((w + 15) / 16) * 16 * 4, ((w * 4 + 63) / 64) * 64, w * 4] where !out.contains(s) {
            out.append(s)
        }
        return out
    }

    /// Find a trailing binary plist and pull width/height out of it,
    /// wherever they are nested. Returns the dimension pair and the
    /// number of trailer bytes the plist occupies.
    private static func trailingPlistDimensions(in data: Data)
        -> (width: Int, height: Int, trailerLength: Int)?
    {
        let magic = Data("bplist00".utf8)
        guard let range = data.range(of: magic, options: .backwards) else { return nil }
        let plistData = data.subdata(in: range.lowerBound..<data.count)
        guard let object = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) else { return nil }
        var width: Int?
        var height: Int?
        func hunt(_ any: Any) {
            if let dict = any as? [String: Any] {
                for (key, value) in dict {
                    let k = key.lowercased()
                    if k == "width", let v = value as? Int { width = v }
                    if k == "height", let v = value as? Int { height = v }
                    if k == "size", let v = value as? String {
                        let nums = v
                            .replacingOccurrences(of: "{", with: "")
                            .replacingOccurrences(of: "}", with: "")
                            .split(separator: ",")
                            .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                        if nums.count == 2 {
                            width = Int(nums[0])
                            height = Int(nums[1])
                        }
                    }
                    hunt(value)
                }
            } else if let array = any as? [Any] {
                for element in array { hunt(element) }
            }
        }
        hunt(object)
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return (w, h, data.count - range.lowerBound)
    }

    private static func render(data: Data, pixelBytes: Int, width: Int, height: Int, stride: Int) -> UIImage? {
        let source = data.prefix(pixelBytes)
        var flipped = Data(count: pixelBytes)
        flipped.withUnsafeMutableBytes { dst in
            source.withUnsafeBytes { src in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                for row in 0..<height {
                    memcpy(d + row * stride, s + (height - 1 - row) * stride, stride)
                }
            }
        }
        guard let provider = CGDataProvider(data: flipped as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Scanning

enum WallpaperScanner {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif",
        "bmp", "tif", "tiff", "cpbitmap"
    ]

    static func scan(containerPath: String) -> [WallpaperItem] {
        let rootLength = (containerPath as NSString).length
        var items: [WallpaperItem] = []
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: containerPath),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                )
                guard values?.isRegularFile == true else { continue }
                let name = url.lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                let size = Int64(values?.fileSize ?? 0)
                var isImage = imageExtensions.contains(ext)
                if !isImage && ext.isEmpty && size >= 10_240 {
                    isImage = QQImageScanner.isImageFile(at: url.path, name: name)
                }
                guard isImage else { continue }
                let rel = String(url.path.dropFirst(rootLength + 1))
                items.append(WallpaperItem(
                    relativePath: rel,
                    size: size,
                    modified: values?.contentModificationDate ?? .distantPast,
                    isCPBitmap: ext == "cpbitmap"
                ))
            }
        }
        items.sort { $0.modified > $1.modified }
        return items
    }
}

// MARK: - Image loading

enum WallpaperImageLoader {
    private static let cpCache = NSCache<NSString, UIImage>()

    /// Full-size image for previews and PNG export.
    static func loadFull(item: WallpaperItem, absolutePath: String, completion: @escaping (UIImage?) -> Void) {
        if item.isCPBitmap {
            loadCPBitmap(path: absolutePath, completion: completion)
        } else {
            QQThumbnailLoader.load(path: absolutePath, maxPixel: 2400) { completion($0) }
        }
    }

    static func loadThumbnail(item: WallpaperItem, absolutePath: String, completion: @escaping (UIImage?) -> Void) {
        if item.isCPBitmap {
            loadCPBitmap(path: absolutePath) { full in
                guard let full else { completion(nil); return }
                let maxPixel = 360.0
                let scale = min(1.0, maxPixel / max(full.size.width, full.size.height))
                if scale >= 1.0 { completion(full); return }
                let target = CGSize(
                    width: (full.size.width * scale).rounded(),
                    height: (full.size.height * scale).rounded()
                )
                let renderer = UIGraphicsImageRenderer(size: target)
                completion(renderer.image { _ in
                    full.draw(in: CGRect(origin: .zero, size: target))
                })
            }
        } else {
            QQThumbnailLoader.load(path: absolutePath, maxPixel: 360) { completion($0) }
        }
    }

    private static func loadCPBitmap(path: String, completion: @escaping (UIImage?) -> Void) {
        let key = path as NSString
        if let hit = cpCache.object(forKey: key) {
            completion(hit)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = CPBitmapDecoder.decode(path: path)
            if let image { cpCache.setObject(image, forKey: key) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

// MARK: - Model

@MainActor
final class WallpaperModel: ObservableObject {
    @Published var items: [WallpaperItem] = []
    @Published var isScanning = false
    @Published var statusText: String?
    private(set) var containerPath: String?
    private var didLoad = false

    nonisolated static let posterBoardBundleID = "com.apple.PosterBoard"

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
        if let path = ContainerStore.resolveAppContainerPath(bundleID: Self.posterBoardBundleID) {
            return path
        }
        // Targeted fallback, same trick as the QQ tab: identify
        // PosterBoard's container by its preferences file.
        let root = "/var/mobile/Containers/Data/Application"
        for dir in ContainerStore.enumerateDirectories(path: root) {
            let canonical = ContainerDiscoveryMerger.canonicalPath(dir)
            let handle = ContainerStore.grantContainerAccess(canonical, logFailure: false)
            guard handle >= 0 else { continue }
            let prefs = (canonical as NSString).appendingPathComponent("Library/Preferences")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: prefs)) ?? []
            if names.contains(Self.posterBoardBundleID + ".plist") {
                _ = ContainerStore.retainContainerAccess(canonical)
                log("wallpaper: container resolved by prefs scan -> \(canonical)")
                return canonical
            }
            worse_query_release(handle)
        }
        return nil
    }

    func load() async {
        isScanning = true
        statusText = nil
        let resolved = await Task.detached(priority: .userInitiated) { [self] in
            resolveContainer()
        }.value
        guard let container = resolved else {
            isScanning = false
            statusText = "没有找到 PosterBoard（系统壁纸）的容器。"
            log("wallpaper: container not found")
            return
        }
        containerPath = container
        _ = ContainerStore.retainContainerAccess(container)
        log("wallpaper: container \(container)")
        let scanned = await Task.detached(priority: .userInitiated) {
            WallpaperScanner.scan(containerPath: container)
        }.value
        items = scanned
        isScanning = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for item in scanned.prefix(60) {
            log("wallpaper: item \(item.relativePath) bytes=\(item.size) mtime=\(formatter.string(from: item.modified))")
        }
        log("wallpaper: total images=\(scanned.count) bytes=\(scanned.reduce(0) { $0 + $1.size })")
        if scanned.isEmpty {
            statusText = "容器找到了，但里面没扫到图片文件。把日志发我，我对着真实目录结构调。"
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Share sheet

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Views

private struct WallpaperThumbCell: View {
    let item: WallpaperItem
    let absolutePath: String
    @State private var image: UIImage?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.secondary.opacity(0.15)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if item.isCPBitmap {
                    VStack(spacing: 2) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("cpbitmap").font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            VStack(alignment: .leading, spacing: 0) {
                Text(WallpaperModel.format(item.size))
                    .font(.system(size: 10, weight: .medium))
                Text(Self.timeFormatter.string(from: item.modified))
                    .font(.system(size: 9))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2)
            .padding(3)
        }
        .clipped()
        .task(id: absolutePath) {
            image = nil
            WallpaperImageLoader.loadThumbnail(item: item, absolutePath: absolutePath) { loaded in
                image = loaded
            }
        }
    }
}

private struct WallpaperPreviewView: View {
    let item: WallpaperItem
    let absolutePath: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var sharePayload: SharePayload?
    @State private var preparing = false

    private static let fullTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                    ProgressView().tint(.white)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fileName).font(.subheadline).bold()
                    Text(item.relativePath).font(.caption2).foregroundStyle(.gray)
                    Text("大小 \(WallpaperModel.format(item.size)) · 修改 \(Self.fullTimeFormatter.string(from: item.modified))")
                        .font(.caption)
                    if let image {
                        Text("尺寸 \(Int(image.size.width)) × \(Int(image.size.height))")
                            .font(.caption)
                    }
                    Button {
                        prepareExport()
                    } label: {
                        if preparing {
                            ProgressView()
                        } else {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preparing)
                    .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .task {
            WallpaperImageLoader.loadFull(item: item, absolutePath: absolutePath) { loaded in
                image = loaded
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: [payload.url])
        }
    }

    /// Render the export into our own temporary directory: another
    /// app cannot read through our worse_query grant, so the share
    /// sheet must hand over a copy we own.
    private func prepareExport() {
        preparing = true
        let item = self.item
        let absolutePath = self.absolutePath
        let loadedImage = self.image
        DispatchQueue.global(qos: .userInitiated).async {
            var out: URL?
            let tmp = FileManager.default.temporaryDirectory
            if item.isCPBitmap {
                if let img = loadedImage ?? CPBitmapDecoder.decode(path: absolutePath),
                   let png = img.pngData() {
                    let url = tmp.appendingPathComponent(
                        (item.fileName as NSString).deletingPathExtension + ".png"
                    )
                    try? png.write(to: url)
                    out = url
                } else {
                    // Decode failed: hand over the raw file so it can
                    // still be converted elsewhere.
                    let url = tmp.appendingPathComponent(item.fileName)
                    try? FileManager.default.copyItem(
                        at: URL(fileURLWithPath: absolutePath), to: url
                    )
                    out = url
                }
            } else {
                let url = tmp.appendingPathComponent(item.fileName)
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.copyItem(
                    at: URL(fileURLWithPath: absolutePath), to: url
                )
                out = url
            }
            DispatchQueue.main.async {
                preparing = false
                if let out { sharePayload = SharePayload(url: out) }
            }
        }
    }
}

struct WallpaperView: View {
    @StateObject private var model = WallpaperModel()
    @State private var previewItem: WallpaperItem?
    @State private var sortBySize = false

    private let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 3), count: 3)

    private var displayedItems: [WallpaperItem] {
        if sortBySize {
            return model.items.sorted { $0.size > $1.size }
        }
        return model.items
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                content
            }
            .navigationTitle("系统壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isScanning)
                }
            }
        }
        .onAppear { model.loadIfNeeded() }
        .fullScreenCover(item: $previewItem) { item in
            WallpaperPreviewView(item: item, absolutePath: absolutePath(for: item))
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                if model.isScanning {
                    ProgressView()
                    Text("正在扫描 PosterBoard 容器…")
                } else {
                    Text("共 \(model.items.count) 张 · \(WallpaperModel.format(model.totalBytes))")
                }
                Spacer()
                Button(sortBySize ? "按大小" : "按时间") {
                    sortBySize.toggle()
                }
                .font(.subheadline)
            }
            .font(.subheadline)
            if let status = model.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("只读工具：只查看和导出，不会改动或删除壁纸文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var content: some View {
        ScrollView {
            if model.items.isEmpty && !model.isScanning {
                ContentUnavailableView(
                    "没有图片",
                    systemImage: "photo.slash",
                    description: Text(model.statusText ?? "未发现壁纸图片。")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(displayedItems) { item in
                        WallpaperThumbCell(item: item, absolutePath: absolutePath(for: item))
                            .onTapGesture { previewItem = item }
                    }
                }
                .padding(3)
            }
        }
    }

    private func absolutePath(for item: WallpaperItem) -> String {
        guard let container = model.containerPath else { return item.relativePath }
        return (container as NSString).appendingPathComponent(item.relativePath)
    }
}
