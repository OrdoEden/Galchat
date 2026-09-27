import UIKit

/// Galchat 的产品色：B 站樱粉与 Galgame 樱花粉之间的柔和粉色。
extension UIColor {
    static let galchatPink = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.56, blue: 0.69, alpha: 1)
            : UIColor(red: 0.941, green: 0.294, blue: 0.478, alpha: 1)
    }

    /// 用于粉色实心底上的白色图标和文字，白字对比度更高。
    static let galchatPinkStrong = UIColor(red: 0.757, green: 0.231, blue: 0.416, alpha: 1)
}
