import Foundation

enum ClipKind: String, Codable {
    case text
    case image
}

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let kind: ClipKind
    /// 文本内容（kind == .text 时有效）
    var text: String?
    /// 图片在 blobs 目录下的文件名（kind == .image 时有效）
    var imageFileName: String?

    init(text: String) {
        self.id = UUID()
        self.date = Date()
        self.kind = .text
        self.text = text
        self.imageFileName = nil
    }

    init(imageFileName: String) {
        self.id = UUID()
        self.date = Date()
        self.kind = .image
        self.text = nil
        self.imageFileName = imageFileName
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.id == rhs.id
    }
}
