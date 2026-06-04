import AppKit
import Combine

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var maxItems: Int {
        didSet {
            UserDefaults.standard.set(maxItems, forKey: "maxItems")
            trim()
            save()
        }
    }

    private let baseDir: URL
    private let blobsDir: URL
    private let historyURL: URL
    private let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        return c
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = support.appendingPathComponent("ClipDrawer", isDirectory: true)
        blobsDir = baseDir.appendingPathComponent("blobs", isDirectory: true)
        historyURL = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        // 收紧目录权限 0o700,避免其它用户/进程窥探剪贴历史
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobsDir.path)

        // 排除出 Time Machine / iCloud Drive 备份
        var baseURL = baseDir
        var baseRV = URLResourceValues()
        baseRV.isExcludedFromBackup = true
        try? baseURL.setResourceValues(baseRV)
        var blobsURL = blobsDir
        var blobsRV = URLResourceValues()
        blobsRV.isExcludedFromBackup = true
        try? blobsURL.setResourceValues(blobsRV)

        let stored = UserDefaults.standard.integer(forKey: "maxItems")
        maxItems = stored == 0 ? 50 : stored

        load()
    }

    // MARK: - 安全文件名校验

    private static let safeImageNameRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\\.png$",
            options: [.caseInsensitive]
        )
    }()

    private static func isSafeImageName(_ s: String) -> Bool {
        guard let regex = safeImageNameRegex else { return false }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, options: [], range: range) != nil
    }

    // MARK: - 读写历史

    private func load() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        guard let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else {
            // 损坏的 history.json 不静默丢弃,改名保留以便排查
            if FileManager.default.fileExists(atPath: historyURL.path) {
                let ts = Int(Date().timeIntervalSince1970)
                let backupURL = baseDir.appendingPathComponent("history.corrupt-\(ts).json")
                try? FileManager.default.moveItem(at: historyURL, to: backupURL)
            }
            return
        }
        items = decoded
        trim()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: historyURL, options: .atomic)
        // 收紧文件权限,只让本用户读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    // MARK: - 新增

    func addText(_ text: String) {
        let trimmed = text
        guard !trimmed.isEmpty else { return }
        // 与历史任意一条文本相同则提到最前，避免 A/B/A 反复插入产生重复
        if let idx = items.firstIndex(where: { $0.kind == .text && $0.text == trimmed }) {
            let existing = items.remove(at: idx)
            items.insert(existing, at: 0)
            save()
            return
        }
        items.insert(ClipItem(text: trimmed), at: 0)
        trim()
        save()
    }

    func addImage(_ data: Data) {
        let fileName = UUID().uuidString + ".png"
        let url = blobsDir.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        // 收紧 blob 权限，只让本用户读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        items.insert(ClipItem(imageFileName: fileName), at: 0)
        trim()
        save()
    }

    // MARK: - 图片读取

    func image(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName, Self.isSafeImageName(name) else { return nil }
        if let cached = imageCache.object(forKey: name as NSString) { return cached }
        let url = blobsDir.appendingPathComponent(name)
        guard let img = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(img, forKey: name as NSString)
        return img
    }

    // MARK: - 写回剪贴板

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            if let text = item.text { pb.setString(text, forType: .string) }
        case .image:
            if let name = item.imageFileName, Self.isSafeImageName(name) {
                let url = blobsDir.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    pb.setData(data, forType: .png)
                }
            }
        }
    }

    // MARK: - 删除

    func delete(_ item: ClipItem) {
        if let name = item.imageFileName, Self.isSafeImageName(name) {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
            imageCache.removeObject(forKey: name as NSString)
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where item.imageFileName != nil {
            if let name = item.imageFileName, Self.isSafeImageName(name) {
                try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
                imageCache.removeObject(forKey: name as NSString)
            }
        }
        imageCache.removeAllObjects()
        items.removeAll()
        save()
    }

    // MARK: - 裁剪到上限

    private func trim() {
        guard items.count > maxItems else { return }
        let removed = items[maxItems...]
        for item in removed where item.imageFileName != nil {
            if let name = item.imageFileName, Self.isSafeImageName(name) {
                try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
                imageCache.removeObject(forKey: name as NSString)
            }
        }
        items = Array(items.prefix(maxItems))
    }
}
