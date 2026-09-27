import Foundation

/// 人格只包含文字文件；导入不会执行脚本，也不会读取包外的文件。
nonisolated struct PersonaPackage: Codable, Identifiable, Sendable {
    struct LegacyProfile: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var identity: String
        var replyStyle: String
    }

    struct Manifest: Codable, Sendable {
        var schemaVersion: Int
        var id: String
        var name: String
        var summary: String
        var version: String
        var documents: [String]
        var licenseFiles: [String]?
        var sourceURL: String?
        var sourceRevision: String?
        var sortOrder: Int?
        var defaultSelected: Bool?
        // 旧默认值也由包声明，应用无需认识任何具体人格。
        var legacyProfiles: [LegacyProfile]?
        var legacyInstallationKeys: [String]?
    }

    enum PackageError: LocalizedError, Sendable {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    static let maximumBytes = 1_000_000
    static let maximumPromptBytes = 128_000
    var manifest: Manifest
    var files: [String: String]
    var id: String { manifest.id }
    var prompt: String {
        (["人格：\(manifest.name)", manifest.summary] + manifest.documents.map {
            "【\($0)】\n\(files[$0] ?? "")"
        }).joined(separator: "\n\n")
    }

    static func new(name: String = "") -> Self {
        Self(manifest: Manifest(schemaVersion: 1, id: UUID().uuidString.lowercased(), name: name,
                                summary: "", version: "1.0", documents: ["PERSONA.md"]),
             files: ["PERSONA.md": ""])
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id != "." && id != ".."
            && id.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
            }
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 240 && !path.contains("\\")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    func validate() throws {
        guard manifest.schemaVersion == 1 else {
            throw PackageError.message("这个人格包的版本暂不支持。")
        }
        guard Self.validID(id), !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.name.count <= 50, manifest.summary.count <= 500,
              !manifest.version.isEmpty, manifest.version.count <= 100 else {
            throw PackageError.message("人格名称最多 50 字，简介最多 500 字，并需要有效的标识和版本。")
        }
        let paths = manifest.documents + (manifest.licenseFiles ?? [])
        guard !manifest.documents.isEmpty, paths.count <= 64,
              Set(paths).count == paths.count, files.count <= 64,
              files.keys.allSatisfy(Self.validPath), paths.allSatisfy(Self.validPath),
              manifest.documents.allSatisfy({ $0.lowercased().hasSuffix(".md") }),
              paths.allSatisfy({ files[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw PackageError.message("人格说明或许可文件缺失。请检查文件清单，每份人格说明都需要是非空的 Markdown 文件。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard prompt.utf8.count <= Self.maximumPromptBytes,
              try encoder.encode(self).count <= Self.maximumBytes else {
            throw PackageError.message("人格包太大：文件合计最多 1 MB，发送给模型的说明最多 128 KB。")
        }
    }

    static func read(from url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Self, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result { try readContents(from: readableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PackageError.message("这个文件暂时无法读取，请下载到本地后重试。") }
        return try result.get()
    }

    private static func readContents(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PackageError.message("请选择实际文件，不要选择文件替身。") }
        let package: Self
        if values.isDirectory == true {
            let directory = url
            let manifest = try JSONDecoder().decode(Manifest.self, from: readFile("manifest.json", in: directory))
            let paths = manifest.documents + (manifest.licenseFiles ?? [])
            guard paths.count <= 64, Set(paths).count == paths.count else {
                throw PackageError.message("人格包的文件清单过长或有重复。")
            }
            var files: [String: String] = [:]
            var byteCount = 0
            for path in paths {
                let data = try readFile(path, in: directory)
                byteCount += data.count
                guard byteCount <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
                    throw PackageError.message("人格包需要使用 UTF-8 文字文件，合计不超过 1 MB。")
                }
                files[path] = text
            }
            package = Self(manifest: manifest, files: files)
        } else if url.pathExtension.lowercased() == "md" {
            let data = try boundedData(at: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw PackageError.message("这份人格说明不是 UTF-8 文字文件。")
            }
            var imported = Self.new(name: String(url.deletingPathExtension().lastPathComponent.prefix(50)))
            imported.files["PERSONA.md"] = text
            package = imported
        } else {
            package = try JSONDecoder().decode(Self.self, from: boundedData(at: url))
        }
        try package.validate()
        return package
    }

    private static func readFile(_ path: String, in directory: URL) throws -> Data {
        guard validPath(path) else { throw PackageError.message("人格包包含无效的文件路径。") }
        var url = directory
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PackageError.message("人格包不能引用包外文件或文件替身。")
            }
        }
        return try boundedData(at: url)
    }

    private static func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw PackageError.message("请选择不超过 1 MB 的文字文件。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw PackageError.message("人格文件超过 1 MB。") }
        return data
    }
}
