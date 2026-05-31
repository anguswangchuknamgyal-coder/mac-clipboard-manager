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
    private var imageCache: [String: NSImage] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = support.appendingPathComponent("ClipDrawer", isDirectory: true)
        blobsDir = baseDir.appendingPathComponent("blobs", isDirectory: true)
        historyURL = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let stored = UserDefaults.standard.integer(forKey: "maxItems")
        maxItems = stored == 0 ? 50 : stored

        load()
    }

    // MARK: - 读写历史

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else {
            return
        }
        items = decoded
        trim()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    // MARK: - 新增

    func addText(_ text: String) {
        let trimmed = text
        guard !trimmed.isEmpty else { return }
        // 与最新一条相同则置顶刷新，避免重复
        if let first = items.first, first.kind == .text, first.text == trimmed {
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
        items.insert(ClipItem(imageFileName: fileName), at: 0)
        trim()
        save()
    }

    // MARK: - 图片读取

    func image(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFileName else { return nil }
        if let cached = imageCache[name] { return cached }
        let url = blobsDir.appendingPathComponent(name)
        guard let img = NSImage(contentsOf: url) else { return nil }
        imageCache[name] = img
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
            if let name = item.imageFileName {
                let url = blobsDir.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    pb.setData(data, forType: .png)
                }
            }
        }
    }

    // MARK: - 删除

    func delete(_ item: ClipItem) {
        if let name = item.imageFileName {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
            imageCache[name] = nil
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where item.imageFileName != nil {
            if let name = item.imageFileName {
                try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
            }
        }
        imageCache.removeAll()
        items.removeAll()
        save()
    }

    // MARK: - 裁剪到上限

    private func trim() {
        guard items.count > maxItems else { return }
        let removed = items[maxItems...]
        for item in removed where item.imageFileName != nil {
            if let name = item.imageFileName {
                try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
                imageCache[name] = nil
            }
        }
        items = Array(items.prefix(maxItems))
    }
}
