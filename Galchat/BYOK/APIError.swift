import Foundation

/// 模型请求失败。`status` 为 nil 表示传输层失败（超时、DNS、TLS）。
struct APIError: LocalizedError {
    let route: APIRoute
    let status: Int?
    let detail: String

    var errorDescription: String? {
        if let status {
            return "\(route.displayName) HTTP \(status)：\(detail.prefix(120))"
        }
        return "\(route.displayName)请求失败：\(detail.prefix(120))"
    }

    /// 4xx 是配置问题（密钥错、模型名错、参数错），重试只会重复失败。
    var isClientError: Bool {
        guard let status else { return false }
        return (400..<500).contains(status)
    }
}
