import Foundation

@MainActor
final class PersonaStore {
    static let shared = PersonaStore()
    static let changed = Notification.Name("Galchat.PersonaStore.changed")
    private static let legacyKey = "Galchat.personaProfiles.v1"

    private struct Selection: Codable {
        var schemaVersion = 1
        var activeID: String
    }

    private struct LegacyDocument: Decodable {
        var schemaVersion: Int
        var activeID: String
        var profiles: [PersonaPackage.LegacyProfile]
    }

    private(set) var profiles: [PersonaPackage] = []
    private(set) var activeID = ""
    private(set) var lastError: String?
    private var loadError: String?
    private var directory: URL?
    var prompt: String {
        guard loadError == nil else { return "" }
        return profiles.first(where: { $0.id == activeID })?.prompt ?? ""
    }
    var replyTransform: PersonaPackage.ReplyTransform? {
        guard loadError == nil else { return nil }
        return profiles.first(where: { $0.id == activeID })?.manifest.replyTransform
    }

    private init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Personas", isDirectory: true)
            self.directory = directory
            if !FileManager.default.fileExists(atPath: directory.path) {
                try installLibrary(at: directory)
            }
            let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: directory.appendingPathComponent("selection.json")))
            guard selection.schemaVersion == 1 else { throw failure("人格设置的版本暂不支持。") }
            let urls = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("packages"),
                                                                   includingPropertiesForKeys: nil)
            var loaded: [PersonaPackage] = []
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
                let package = try PersonaPackage.read(from: url)
                guard url.deletingPathExtension().lastPathComponent == package.id,
                      !loaded.contains(where: { $0.id.lowercased() == package.id.lowercased() }) else {
                    throw failure("人格文件的名称或标识重复，请检查本地文件。")
                }
                loaded.append(package)
            }
            profiles = sorted(loaded)
            // 删除文件后即使选择写入中断，也只会回到“不使用人格”。
            activeID = profiles.contains(where: { $0.id == selection.activeID }) ? selection.activeID : ""
        } catch {
            loadError = "人格文件未能读取，原文件已保留。\(error.localizedDescription)"
            lastError = loadError
        }
    }

    func select(id: String) throws {
        let directory = try writableDirectory()
        guard id.isEmpty || profiles.contains(where: { $0.id == id }) else { throw failure("找不到这个人格。") }
        try write(Selection(activeID: id), to: directory.appendingPathComponent("selection.json"))
        activeID = id
        notify()
    }

    func save(_ package: PersonaPackage) throws {
        let directory = try writableDirectory()
        var cleaned = package
        cleaned.manifest.name = cleaned.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.manifest.summary = cleaned.manifest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        try cleaned.validate()
        guard !profiles.contains(where: { $0.id != cleaned.id && $0.id.lowercased() == cleaned.id.lowercased() }) else {
            throw failure("已有一个标识相同的人格，请让两个文件使用不同的标识。")
        }
        try write(cleaned, to: packageURL(id: cleaned.id, in: directory))
        profiles.removeAll { $0.id == cleaned.id }
        profiles.append(cleaned)
        profiles = sorted(profiles)
        notify()
    }

    func delete(id: String) throws {
        let directory = try writableDirectory()
        guard profiles.contains(where: { $0.id == id }) else { throw failure("找不到这个人格。") }
        // 先保存取消选择，重新导入同一 ID 时也不会被意外启用。
        if activeID == id { try select(id: "") }
        try FileManager.default.removeItem(at: packageURL(id: id, in: directory))
        profiles.removeAll { $0.id == id }
        notify()
    }

    func importPackage(from url: URL) async throws -> PersonaPackage {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try PersonaPackage.read(from: url)
            }.value
        }
        catch let error as PersonaPackage.PackageError { throw error }
        catch { throw failure("无法读取这份人格。请选择 .personal 人格文件、完整的人格文件夹、旧版导出的 JSON 或 Markdown 说明。\(error.localizedDescription)") }
    }

    func exportPackage(id: String) throws -> URL {
        guard let package = profiles.first(where: { $0.id == id }) else { throw failure("找不到这个人格。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 文件名用人格名称，方便分享后辨认；去掉路径分隔等不安全字符，取不到时退回标识。
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let name = package.manifest.name.components(separatedBy: unsafe).joined()
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let url = directory.appendingPathComponent(name.isEmpty ? package.id : name)
            .appendingPathExtension(PersonaPackage.fileExtension)
        try write(package, to: url)
        return url
    }

    private func installLibrary(at directory: URL) throws {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Personas", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.path) else {
            throw failure("没有找到随 App 附带的人格文件，请检查资源是否完整。")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: [.isDirectoryKey])
        let seeds = try sorted(urls.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map { try PersonaPackage.read(from: $0) })
        guard Set(seeds.map { $0.id.lowercased() }).count == seeds.count else { throw failure("附带的人格标识重复。") }
        var packages = seeds
        var selected = seeds.first(where: { $0.manifest.defaultSelected == true })?.id ?? ""
        if let stored = UserDefaults.standard.object(forKey: Self.legacyKey) {
            guard let data = stored as? Data else { throw failure("旧人格数据无法识别。") }
            let legacy = try JSONDecoder().decode(LegacyDocument.self, from: data)
            guard legacy.schemaVersion == 1, Set(legacy.profiles.map { $0.id.lowercased() }).count == legacy.profiles.count,
                  legacy.profiles.contains(where: { $0.id == legacy.activeID }) else {
                throw failure("旧人格数据的版本或内容无法识别。")
            }
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            packages = []
            selected = legacy.activeID
            for profile in legacy.profiles {
                let seed = seeds.first { $0.manifest.legacyProfiles?.contains(profile) == true }
                // 只有完全未编辑的旧默认值才换成完整人格；用户修改原样保留。
                if let seed, !legacy.profiles.contains(where: { $0.id.lowercased() == seed.id.lowercased() && $0.id != profile.id }),
                   !packages.contains(where: { $0.id.lowercased() == seed.id.lowercased() }) {
                    packages.append(seed)
                    if selected == profile.id { selected = seed.id }
                } else {
                    var package = PersonaPackage.new(name: profile.name)
                    package.manifest.id = profile.id
                    package.files["PERSONA.md"] = [profile.identity, profile.replyStyle].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    try package.validate()
                    packages.append(package)
                }
            }
            for seed in seeds where !packages.contains(where: { $0.id.lowercased() == seed.id.lowercased() }) {
                let oldIDs = Set((seed.manifest.legacyProfiles ?? []).map(\.id))
                let hadProfile = legacy.profiles.contains { oldIDs.contains($0.id) }
                let keys = seed.manifest.legacyInstallationKeys ?? []
                let wasInstalled = keys.contains { (fields[$0] as? Bool) == true }
                // 有安装记录却不在列表中，表示用户已删除；不重新补入。
                if !hadProfile && !wasInstalled && (!keys.isEmpty || oldIDs.isEmpty) { packages.append(seed) }
            }
        }
        // 首次安装/迁移作为一个目录落地，中途失败保留旧存储供重试。
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".personas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("packages"), withIntermediateDirectories: true)
        for package in packages {
            try package.validate()
            try write(package, to: packageURL(id: package.id, in: staging))
        }
        try write(Selection(activeID: selected), to: staging.appendingPathComponent("selection.json"))
        try FileManager.default.moveItem(at: staging, to: directory)
    }

    private func packageURL(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("packages", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func writableDirectory() throws -> URL {
        if let loadError { throw failure(loadError) }
        guard let directory else { throw failure("人格保存位置不可用。") }
        return directory
    }

    private func sorted(_ packages: [PersonaPackage]) -> [PersonaPackage] {
        packages.sorted {
            let left = $0.manifest.sortOrder ?? 1000, right = $1.manifest.sortOrder ?? 1000
            return left == right ? $0.id < $1.id : left < right
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func notify() {
        lastError = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func failure(_ text: String) -> PersonaPackage.PackageError { .message(text) }
}
