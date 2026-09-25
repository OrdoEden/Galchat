import Foundation
import Synapse

/// BYOK 密钥存储。按用户要求使用 UserDefaults 而非 Keychain。
///
/// 注意：UserDefaults 是沙盒内的明文 plist，会随设备备份导出。
/// 换回 Keychain 时只需替换本文件的 read/write 实现，调用方不受影响。
struct SecretStore {
    private let store: SynapseCredentialStore

    init(defaults: UserDefaults = .standard) {
        self.store = SynapseCredentialStore(defaults: defaults, namespace: "jarvis.secret")
    }

    func key(for route: APIRoute) -> String {
        store.key(for: route.rawValue)
    }

    func setKey(_ value: String, for route: APIRoute) {
        store.setKey(value, for: route.rawValue)
    }

    func hasKey(for route: APIRoute) -> Bool {
        !key(for: route).isEmpty
    }

}
