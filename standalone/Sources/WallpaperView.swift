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
        let magic = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        log("wallpaper: cpbitmap \(name) magic \(magic)")
        var pixelBytes = data.count
        var plistWidth: Int?
        var plistHeight: Int?
        if let dims = trailingPlistDimensions(in: data) {
            plistWidth = dims.width
            plistHeight = dims.height
            pixelBytes = data.count - dims.trailerLength
            log("wallpaper: cpbitmap \(name) plist dims \(dims.width)x\(dims.height) trailer=\(dims.trailerLength)")
        }
        var expectedHeight = plistHeight
        var widths: [Int] = []
        if let w = plistWidth { widths.append(w) }
        if let dims = filenameDimensions(name) {
            widths.append(dims.0)
            if expectedHeight == nil { expectedHeight = dims.1 }
            log("wallpaper: cpbitmap \(name) filename dims \(dims.0)x\(dims.1)")
        }
        widths += [1320, 1290, 1260, 1206, 1179, 1170, 1284, 1242, 1125, 1080, 828, 750]
        for w in widths where w > 0 {
            for stride in candidateStrides(width: w) {
                guard stride > 0, pixelBytes > 0, pixelBytes % stride == 0 else { continue }
                let h = pixelBytes / stride
                guard h > 0 else { continue }
                if let fixed = expectedHeight, h != fixed { continue }
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

    /// MappedImageCache names embed the render geometry, e.g.
    /// `b[{{0, 0}, {440, 956}}]-s[3.000000]` = 440x956 pt at 3x.
    private static func filenameDimensions(_ name: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\{(\\d+),\\s*(\\d+)\\}\\]-s\\[(\\d+(?:\\.\\d+)?)\\]"
        ) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let r1 = Range(match.range(at: 1), in: name),
              let r2 = Range(match.range(at: 2), in: name),
              let r3 = Range(match.range(at: 3), in: name),
              let w = Double(name[r1]), let h = Double(name[r2]), let s = Double(name[r3])
        else { return nil }
        return (Int(w * s), Int(h * s))
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
        // The container also holds watch-complication snapshots and
        // poster preview renders (MappedImageCache) — what counts as
        // "wallpaper" here is the configured posters themselves (the
        // PRB extension data store) plus the full-screen V16 renders
        // of the current home/lock posters.
        let unfiltered = items.count
        items = items.filter {
            $0.relativePath.hasPrefix("Library/Application Support/PRBPosterExtensionDataStore/")
                || $0.fileName.hasPrefix("V16-OS")
        }
        log("wallpaper: filter kept=\(items.count) excluded=\(unfiltered - items.count)")
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
            loadCPBitmap(path: absolutePath, maxPixel: 2400, completion: completion)
        } else {
            QQThumbnailLoader.load(path: absolutePath, maxPixel: 2400) { completion($0) }
        }
    }

    static func loadThumbnail(item: WallpaperItem, absolutePath: String, completion: @escaping (UIImage?) -> Void) {
        if item.isCPBitmap {
            loadCPBitmap(path: absolutePath, maxPixel: 360, completion: completion)
        } else {
            QQThumbnailLoader.load(path: absolutePath, maxPixel: 360) { completion($0) }
        }
    }

    /// Modern PosterBoard ".cpbitmap" files are often ordinary
    /// encoded images under a bitmap name (their sizes are not even
    /// divisible by 4, so they cannot be raw BGRA dumps): let ImageIO
    /// sniff the payload first, and only fall back to the raw
    /// cpbitmap decoder when ImageIO cannot read the file.
    private static func loadCPBitmap(path: String, maxPixel: Int, completion: @escaping (UIImage?) -> Void) {
        QQThumbnailLoader.load(path: path, maxPixel: maxPixel) { image in
            if let image {
                log("wallpaper: cpbitmap imageio decoded \((path as NSString).lastPathComponent)")
                completion(image)
                return
            }
            loadRawCPBitmap(path: path) { raw in
                guard let raw else { completion(nil); return }
                let limit = Double(maxPixel)
                let scale = min(1.0, limit / max(raw.size.width, raw.size.height))
                if scale >= 1.0 { completion(raw); return }
                let target = CGSize(
                    width: (raw.size.width * scale).rounded(),
                    height: (raw.size.height * scale).rounded()
                )
                let renderer = UIGraphicsImageRenderer(size: target)
                completion(renderer.image { _ in
                    raw.draw(in: CGRect(origin: .zero, size: target))
                })
            }
        }
    }

    private static func loadRawCPBitmap(path: String, completion: @escaping (UIImage?) -> Void) {
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
    @Published var packages: [PosterPackage] = []
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
        let foundPackages = await Task.detached(priority: .userInitiated) {
            PosterPackageScanner.scan(containerPath: container)
        }.value
        packages = foundPackages
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
    @State private var section = 0

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
                } else if section == 0 {
                    Text("共 \(model.packages.count) 个海报包")
                } else {
                    Text("共 \(model.items.count) 张 · \(WallpaperModel.format(model.totalBytes))")
                }
                Spacer()
                if section == 1 {
                    Button(sortBySize ? "按大小" : "按时间") {
                        sortBySize.toggle()
                    }
                    .font(.subheadline)
                }
            }
            .font(.subheadline)
            Picker("模式", selection: $section) {
                Text("海报包").tag(0)
                Text("图片").tag(1)
            }
            .pickerStyle(.segmented)
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

    @ViewBuilder
    private var content: some View {
        if section == 0 {
            packageList
        } else {
            imageGrid
        }
    }

    private var packageList: some View {
        ScrollView {
            if model.packages.isEmpty && !model.isScanning {
                ContentUnavailableView(
                    "没有海报包",
                    systemImage: "photo.slash",
                    description: Text(model.statusText ?? "未发现海报配置。")
                )
                .padding(.top, 60)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.packages) { package in
                        NavigationLink {
                            PosterPackageDetailView(
                                package: package,
                                containerPath: model.containerPath ?? ""
                            )
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(package.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(package.providerID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(package.files.count) 个文件 · \(WallpaperModel.format(package.totalBytes)) · \(Self.rowTimeFormatter.string(from: package.modified))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var imageGrid: some View {
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

// MARK: - Poster packages (whole-configuration export)

struct PackageFile: Identifiable, Equatable {
    /// Path relative to the configuration directory.
    let relativePath: String
    let size: Int64
    let modified: Date
    var id: String { relativePath }
}

/// One poster configuration inside the PRB extension data store:
/// a provider's `configurations/<UUID>` directory, holding every
/// version and content file of one configured poster. Interactive
/// (.tendies) posters live here too — their assets are videos and
/// descriptor plists, not images, so the image grid never sees them.
struct PosterPackage: Identifiable, Equatable {
    /// Configuration directory, relative to the container root.
    let relativePath: String
    let providerID: String
    let configID: String
    let displayName: String
    let files: [PackageFile]
    var id: String { relativePath }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var modified: Date { files.map(\.modified).max() ?? .distantPast }
}

enum PosterPackageScanner {
    static func scan(containerPath: String) -> [PosterPackage] {
        let storeRel = "Library/Application Support/PRBPosterExtensionDataStore"
        let storeAbs = (containerPath as NSString).appendingPathComponent(storeRel)
        var packages: [PosterPackage] = []
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: storeAbs) else {
            log("wallpaper-pkg: store not found at \(storeRel)")
            return []
        }
        for version in versions {
            let extRoot = "\(storeRel)/\(version)/Extensions"
            let extAbs = (containerPath as NSString).appendingPathComponent(extRoot)
            guard let providers = try? FileManager.default.contentsOfDirectory(atPath: extAbs) else { continue }
            for provider in providers {
                let cfgRoot = "\(extRoot)/\(provider)/configurations"
                let cfgRootAbs = (containerPath as NSString).appendingPathComponent(cfgRoot)
                guard let configs = try? FileManager.default.contentsOfDirectory(atPath: cfgRootAbs) else { continue }
                for cfg in configs {
                    let cfgRel = "\(cfgRoot)/\(cfg)"
                    let cfgAbs = (containerPath as NSString).appendingPathComponent(cfgRel)
                    var files: [PackageFile] = []
                    if let enumerator = FileManager.default.enumerator(
                        at: URL(fileURLWithPath: cfgAbs),
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                        options: []
                    ) {
                        let rootLength = (cfgAbs as NSString).length
                        for case let url as URL in enumerator {
                            let values = try? url.resourceValues(
                                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                            )
                            guard values?.isRegularFile == true else { continue }
                            files.append(PackageFile(
                                relativePath: String(url.path.dropFirst(rootLength + 1)),
                                size: Int64(values?.fileSize ?? 0),
                                modified: values?.contentModificationDate ?? .distantPast
                            ))
                        }
                    }
                    files.sort { $0.size > $1.size }
                    let name = displayName(cfgAbs: cfgAbs, files: files) ?? cfg
                    let package = PosterPackage(
                        relativePath: cfgRel, providerID: provider,
                        configID: cfg, displayName: name, files: files
                    )
                    packages.append(package)
                    log("wallpaper-pkg: \(provider) cfg=\(cfg) name=\(name) files=\(files.count) bytes=\(package.totalBytes)")
                    for file in files.prefix(40) {
                        log("wallpaper-pkg:   file \(file.relativePath) bytes=\(file.size)")
                    }
                }
            }
        }
        packages.sort { $0.modified > $1.modified }
        log("wallpaper-pkg: total packages=\(packages.count)")
        return packages
    }

    /// Best-effort display name: hunt the configuration's shallow
    /// plist files for a human-readable name key.
    private static func displayName(cfgAbs: String, files: [PackageFile]) -> String? {
        let keys = ["name", "posterName", "displayName", "title", "Name", "Title"]
        for file in files
        where file.relativePath.hasSuffix(".plist")
            && file.relativePath.split(separator: "/").count <= 2 {
            let path = (cfgAbs as NSString).appendingPathComponent(file.relativePath)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = object as? [String: Any] else { continue }
            log("wallpaper-pkg: plist \(file.relativePath) keys=\(Array(dict.keys).sorted())")
            for key in keys {
                if let value = dict[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }
}

// MARK: - Minimal stored-zip writer

/// Just enough ZIP to hand a directory tree to the Files app:
/// stored (uncompressed) entries, CRC-32, UTF-8 names. Files are
/// streamed in chunks — poster videos never sit in memory whole.
enum ZipWriter {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32<S: Sequence>(bytes: S, crc: UInt32) -> UInt32 where S.Element == UInt8 {
        var c = crc ^ 0xFFFF_FFFF
        for byte in bytes {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let day = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, day)
    }

    /// entries: (archive name, absolute source path, mtime)
    static func write(entries: [(String, String, Date)], to url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? out.close() }
        var offset: UInt64 = 0
        var central: [(String, UInt32, UInt32, UInt32, UInt16, UInt16)] = []

        func append(_ data: Data) {
            out.write(data)
            offset += UInt64(data.count)
        }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        for (name, source, modified) in entries {
            guard let input = try? FileHandle(forReadingFrom: URL(fileURLWithPath: source)) else { return false }
            // Pass 1: CRC + size.
            var crc: UInt32 = 0
            var size: UInt64 = 0
            while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
                crc = crc32(bytes: chunk, crc: crc)
                size += UInt64(chunk.count)
            }
            guard size <= UInt64(UInt32.max) else { try? input.close(); return false }
            try? input.seek(toOffset: 0)
            let nameData = Data(name.utf8)
            let (time, day) = dosDateTime(modified)
            let localOffset = UInt32(offset)
            var header = Data()
            header.append(u32(0x0403_4B50))
            header.append(u16(20))
            header.append(u16(0x0800))
            header.append(u16(0))
            header.append(u16(time))
            header.append(u16(day))
            header.append(u32(crc))
            header.append(u32(UInt32(size)))
            header.append(u32(UInt32(size)))
            header.append(u16(UInt16(nameData.count)))
            header.append(u16(0))
            header.append(nameData)
            append(header)
            // Pass 2: copy payload.
            while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
                append(chunk)
            }
            try? input.close()
            central.append((name, crc, UInt32(size), localOffset, time, day))
        }

        let centralStart = offset
        for (name, crc, size, localOffset, time, day) in central {
            let nameData = Data(name.utf8)
            var record = Data()
            record.append(u32(0x0201_4B50))
            record.append(u16(20))
            record.append(u16(20))
            record.append(u16(0x0800))
            record.append(u16(0))
            record.append(u16(time))
            record.append(u16(day))
            record.append(u32(crc))
            record.append(u32(size))
            record.append(u32(size))
            record.append(u16(UInt16(nameData.count)))
            record.append(u16(0))
            record.append(u16(0))
            record.append(u16(0))
            record.append(u16(0))
            record.append(u32(0))
            record.append(u32(localOffset))
            record.append(nameData)
            append(record)
        }
        var end = Data()
        end.append(u32(0x0605_4B50))
        end.append(u16(0))
        end.append(u16(0))
        end.append(u16(UInt16(central.count)))
        end.append(u16(UInt16(central.count)))
        end.append(u32(UInt32(offset - centralStart)))
        end.append(u32(UInt32(centralStart)))
        end.append(u16(0))
        append(end)
        return true
    }
}

// MARK: - Poster package detail

struct PosterPackageDetailView: View {
    let package: PosterPackage
    let containerPath: String
    @State private var sharePayload: SharePayload?
    @State private var exporting = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(package.files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.relativePath)
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text("\(WallpaperModel.format(file.size)) · \(Self.timeFormatter.string(from: file.modified))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(package.files.count) 个文件 · 共 \(WallpaperModel.format(package.totalBytes))")
                }
            }
            .listStyle(.plain)
            Button {
                exportZip()
            } label: {
                if exporting {
                    ProgressView()
                } else {
                    Label("导出整包（zip）", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(exporting || package.files.isEmpty)
            .padding()
        }
        .navigationTitle(package.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: [payload.url])
        }
    }

    private func exportZip() {
        exporting = true
        let package = self.package
        let containerPath = self.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
            let cfgAbs = (containerPath as NSString).appendingPathComponent(package.relativePath)
            let entries: [(String, String, Date)] = package.files.map { file in
                (
                    "\(package.configID)/\(file.relativePath)",
                    (cfgAbs as NSString).appendingPathComponent(file.relativePath),
                    file.modified
                )
            }
            let safeName = package.displayName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).zip")
            try? FileManager.default.removeItem(at: url)
            let ok = ZipWriter.write(entries: entries, to: url)
            log("wallpaper-pkg: export \(package.configID) ok=\(ok) entries=\(entries.count)")
            DispatchQueue.main.async {
                exporting = false
                if ok { sharePayload = SharePayload(url: url) }
            }
        }
    }
}
