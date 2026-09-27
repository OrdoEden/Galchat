import UIKit

public extension UIControl {
    /// Expands the control's hit area without changing its visual frame.
    var clickEdgeInsets: UIEdgeInsets {
        get {
            guard let value = objc_getAssociatedObject(self, &RuntimeKey.clickEdgeInsets) as? NSValue else {
                return .zero
            }
            return value.uiEdgeInsetsValue
        }
        set {
            objc_setAssociatedObject(
                self,
                &RuntimeKey.clickEdgeInsets,
                NSValue(uiEdgeInsets: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Compatibility name used by older Objective-C callers.
    @objc var objc_clickEdgeInsets: UIEdgeInsets {
        get { clickEdgeInsets }
        set { clickEdgeInsets = newValue }
    }

}

private enum RuntimeKey {
    static var clickEdgeInsets: UInt8 = 0
}

/// UIButton's hit-test override lives in a subclass because Swift does not
/// allow overriding superclass methods from an extension.
final class HitTargetButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let insets = clickEdgeInsets
        guard insets != .zero, !isHidden, alpha > 0 else {
            return super.point(inside: point, with: event)
        }

        return bounds.inset(by: UIEdgeInsets(
            top: -insets.top,
            left: -insets.left,
            bottom: -insets.bottom,
            right: -insets.right
        )).contains(point)
    }
}
