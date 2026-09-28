import Foundation

/// App Group 内共享文件的底层读写。主 App 与键盘都编译这个文件。
///
/// `ReplyBundleStore` 和 `AffectionProjectionStore` 的落盘方式必须完全一致——
/// 同一套目录、同一套文件保护、同一套原子写。之前这套逻辑写在
/// `ReplyBundleStore` 里，加第二个共享文件时抽出来，避免逐份复制后漂移。
nonisolated enum GalchatSharedFile {
    /// App Group 标识来自 Info.plist 的 `VisynAppGroupIdentifier`（主 App 与键盘配了同一个值）。
    static var containerURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VisynAppGroupIdentifier") as? String,
              !group.isEmpty, !group.hasPrefix("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container
    }

    /// 共享文件所在子目录。
    static let directoryName = "Galchat"

    static var directoryURL: URL? {
        containerURL?.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(named name: String) -> URL? {
        directoryURL?.appendingPathComponent(name)
    }

    static func modificationDate(named name: String) -> Date? {
        guard let url = fileURL(named: name) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func read<T: Decodable>(_ type: T.Type, named name: String) -> T? {
        guard let url = fileURL(named: name), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// 原子写入并设文件保护。候选、联系人标题和好感度都属于聊天衍生数据。
    @discardableResult
    static func write<T: Encodable>(_ value: T, named name: String) -> Bool {
        guard let url = fileURL(named: name), let data = try? encoder.encode(value) else { return false }
        let directory = url.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var excluded = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func remove(named name: String) {
        guard let url = fileURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
