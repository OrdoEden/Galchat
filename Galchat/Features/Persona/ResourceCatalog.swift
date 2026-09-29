import CryptoKit
import Foundation

/// 远程资源库：从 GitHub 上的 `catalog.json` 拉取可下载人格和提示词包，校验后安装，同时执行人格的远程下架。
///
/// `catalog.json` 结构见 docs/persona-file-format.md。包地址和形象地址可以写相对路径，按目录所在位置解析，
/// 所以同一份目录既能从 GitHub raw 读取，也能从 jsDelivr 镜像读取。
@MainActor
final class ResourceCatalog {
    static let shared = ResourceCatalog()
    static let changed = Notification.Name("Galchat.ResourceCatalog.changed")

    /// 按顺序尝试；第一个成功的地址作为相对路径的基准。
    static let sourceURLs = [
        URL(string: "https://raw.githubusercontent.com/OrdoEden/GalchatResource/main/catalog.json")!,
        URL(string: "https://cdn.jsdelivr.net/gh/OrdoEden/GalchatResource@main/catalog.json")!
    ]
    static let sourceDescription = "github.com/OrdoEden/GalchatResource"
    private static let lastRefreshKey = "Galchat.ResourceCatalog.lastRefresh"
    private static let refreshInterval: TimeInterval = 30 * 60
    private static let maximumCatalogBytes = 1_000_000

    struct Document: Decodable {
        var schemaVersion: Int
        var personas: [Entry]
        var revoked: [Revocation]?
        var prompts: Resource?
    }

    /// 单个可下载文件（目前是提示词包）。
    struct Resource: Decodable {
        var version: String
        var package: String
        var sha256: String
        var size: Int
    }

    struct Entry: Decodable {
        var id: String
        var name: String
        var summary: String
        var version: String
        /// `.personal` 文件地址。
        var package: String
        var sha256: String
        var size: Int
        /// 可选的形象预览图地址，用于列表缩略图。
        var portrait: String?
        var sortOrder: Int?
    }

    struct Revocation: Decodable {
        var id: String
        var reason: String?
    }

    /// 解析好地址的条目。
    struct Item {
        var entry: Entry
        var packageURL: URL
        var portraitURL: URL?
    }

    private(set) var items: [Item] = []
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private var installing: Set<String> = []
    private var refreshTask: Task<Void, Never>?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private init() {}

    func isInstalling(_ id: String) -> Bool { installing.contains(id) }

    /// 进入前台时调用；距上次成功刷新不足 30 分钟就跳过。
    func refreshIfNeeded() {
        let last = UserDefaults.standard.object(forKey: Self.lastRefreshKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.refreshInterval else { return }
        refresh()
    }

    /// 拉取目录，执行下架，静默更新未经本机修改的附带/下载人格，以及更新提示词包。
    func refresh() {
        guard refreshTask == nil else { return }
        isRefreshing = true
        lastError = nil
        notify()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (document, base) = try await self.fetchDocument()
                let revoked = Set((document.revoked ?? []).map { $0.id.lowercased() })
                self.items = document.personas.compactMap { entry in
                    guard PersonaPackage.validID(entry.id), !revoked.contains(entry.id.lowercased()),
                          let packageURL = Self.resolve(entry.package, against: base) else { return nil }
                    return Item(entry: entry, packageURL: packageURL,
                                portraitURL: entry.portrait.flatMap { Self.resolve($0, against: base) })
                }
                .sorted { ($0.entry.sortOrder ?? 1000, $0.entry.id) < ($1.entry.sortOrder ?? 1000, $1.entry.id) }
                PersonaStore.shared.applyRevocations((document.revoked ?? []).reduce(into: [:]) { $0[$1.id] = $1.reason ?? "" })
                UserDefaults.standard.set(Date(), forKey: Self.lastRefreshKey)
                await self.autoUpdate()
                if let prompts = document.prompts { await self.updatePrompts(prompts, base: base) }
            } catch {
                self.lastError = "人格库暂时连不上：\(error.localizedDescription)"
            }
            self.isRefreshing = false
            self.refreshTask = nil
            self.notify()
        }
    }

    /// 下载、校验并保存一个人格。已安装的同标识人格会被替换。
    func install(_ item: Item) async throws {
        let id = item.entry.id
        guard !installing.contains(id) else { return }
        installing.insert(id)
        notify()
        defer {
            installing.remove(id)
            notify()
        }
        guard !PersonaStore.shared.isRevoked(id: id) else { throw failure("这个人格已经下架。") }
        guard item.entry.size > 0, item.entry.size <= PersonaPackage.maximumPackageBytes else {
            throw failure("人格包大小不符合要求。")
        }
        let data = try await download(item.packageURL, limit: item.entry.size)
        guard data.count == item.entry.size, Self.sha256(data) == item.entry.sha256.lowercased() else {
            throw failure("下载的人格包校验失败，请稍后重试。")
        }
        let package = try await Task.detached(priority: .userInitiated) {
            let package = try JSONDecoder().decode(PersonaPackage.self, from: data)
            try package.validate()
            return package
        }.value
        guard package.id == id, package.manifest.version == item.entry.version else {
            throw failure("人格库的信息与下载的人格包不一致。")
        }
        try PersonaStore.shared.save(package, source: .catalog)
    }

    func thumbnailData(for item: Item) async -> Data? {
        guard let url = item.portraitURL else { return nil }
        return try? await download(url, limit: PersonaPackage.maximumAssetBytes)
    }

    // MARK: - 私有

    private func autoUpdate() async {
        let store = PersonaStore.shared
        for item in items {
            guard let installed = store.profiles.first(where: { $0.id == item.entry.id }),
                  [.bundled, .catalog].contains(store.source(of: installed.id)),
                  PersonaPackage.isVersion(item.entry.version, newerThan: installed.manifest.version) else { continue }
            try? await install(item)
        }
    }

    /// 题目包只在版本更新时下载；下载或校验失败时保留当前题目包，下次同步再试。
    private func updatePrompts(_ resource: Resource, base: URL) async {
        guard PersonaPackage.isVersion(resource.version, newerThan: PromptStore.current.version),
              resource.size > 0, resource.size <= PromptPack.maximumBytes,
              let url = Self.resolve(resource.package, against: base),
              let data = try? await download(url, limit: resource.size),
              data.count == resource.size, Self.sha256(data) == resource.sha256.lowercased() else { return }
        do {
            guard try PromptPack.decode(data).version == resource.version else { return }
            try PromptStore.install(data)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fetchDocument() async throws -> (Document, URL) {
        var lastError: Error = failure("没有可用的人格库地址。")
        for url in Self.sourceURLs {
            do {
                let data = try await download(url, limit: Self.maximumCatalogBytes)
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.schemaVersion == 1 else { throw failure("人格库版本较新，请更新 App。") }
                return (document, url)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        guard url.scheme == "https" else { throw failure("只支持 HTTPS 地址。") }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw failure("服务器返回了错误。")
        }
        guard data.count <= limit else { throw failure("下载内容超过大小限制。") }
        return data
    }

    private static func resolve(_ string: String, against base: URL) -> URL? {
        guard let url = URL(string: string, relativeTo: base)?.absoluteURL, url.scheme == "https" else { return nil }
        return url
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func failure(_ text: String) -> PersonaPackage.PackageError { .message(text) }
}
