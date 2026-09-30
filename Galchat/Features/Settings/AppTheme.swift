import UIKit
import SnapKit

/// 界面主题：四种背景，在“设置 → 外观主题”里切换。
///
/// 主题只负责两件事：页面底色（含顶部一层很淡的晕染）和界面的深浅色。
/// 玻璃、按钮、列表行都沿用系统材质，不随主题单独调色，避免每加一个主题就要改一堆控件。
enum GalchatTheme: String, CaseIterable {
    case mist, frost, plain, night

    var title: String {
        switch self {
        case .mist: return "樱雾"
        case .frost: return "霜白"
        case .plain: return "素白"
        case .night: return "夜樱（深色）"
        }
    }

    var subtitle: String {
        switch self {
        case .mist: return "暖白底，顶部一层淡粉和杏色晕染，和品牌粉最搭"
        case .frost: return "偏冷的浅灰底，右上一点粉、左上一点浅蓝"
        case .plain: return "米白底，只在顶部留很淡的粉色，最干净"
        case .night: return "深色模式：暗底配酒红晕染，粉色提亮"
        }
    }

    /// 页面底色。
    var background: UIColor {
        switch self {
        // 都不用纯白：大面积 #FFFFFF 在手机上很刺眼。
        case .mist: return UIColor(hex: 0xF7F2F3)
        case .frost: return UIColor(hex: 0xF1F2F5)
        case .plain: return UIColor(hex: 0xF6F5F2)
        case .night: return UIColor(hex: 0x141014)
        }
    }

    /// 顶部晕染色的两层（从上往下淡出）。nil 表示不画晕染。
    var washColors: [UIColor]? {
        switch self {
        case .mist: return [UIColor(hex: 0xFFD9E4), UIColor(hex: 0xFFE8DA)]
        case .frost: return [UIColor(hex: 0xFFE0EA), UIColor(hex: 0xE3ECF6)]
        case .plain: return [UIColor(hex: 0xFFF2F5), UIColor(hex: 0xFFF2F5)]
        case .night: return [UIColor(hex: 0x4A1C2E), UIColor(hex: 0x3A2226)]
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        self == .night ? .dark : .light
    }

    var isDark: Bool { self == .night }
}

/// 当前主题。改主题时把新样式广播给所有页面。
@MainActor
final class ThemeStore {
    static let shared = ThemeStore()
    static let changed = Notification.Name("Galchat.ThemeStore.changed")

    private static let key = "Galchat.theme"
    private let defaults: UserDefaults

    private(set) var current: GalchatTheme

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.string(forKey: Self.key).flatMap(GalchatTheme.init(rawValue:)) ?? .mist
    }

    func apply(_ theme: GalchatTheme) {
        guard theme != current else { return }
        current = theme
        defaults.set(theme.rawValue, forKey: Self.key)
        applyToWindows()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// 启动时调用一次，保证主题在第一个页面出现前生效。
    func applyToWindows() {
        for scene in UIApplication.shared.connectedScenes {
            for case let window as UIWindow in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = current.interfaceStyle
                window.backgroundColor = current.background
            }
        }
    }
}

/// 页面背景：底色 + 顶部晕染。固定在内容之下，不随滚动移动。
final class ThemeBackgroundView: UIView {
    private let gradient = CAGradientLayer()
    private let wash: [UIColor]?
    private var theme: GalchatTheme

    init(theme: GalchatTheme) {
        self.theme = theme
        wash = theme.washColors
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(300, bounds.height))
        CATransaction.commit()
    }

    private func apply() {
        backgroundColor = theme.background
        guard let wash else {
            gradient.isHidden = true
            return
        }
        gradient.isHidden = false
        gradient.colors = [wash[0].cgColor, wash[0].withAlphaComponent(0.5).cgColor,
                           wash[1].withAlphaComponent(0).cgColor]
        gradient.locations = [0, 0.4, 1]
    }
}
