import UIKit

public extension UIView {
    var right: CGFloat {
        get { frame.maxX }
        set { frame.origin.x = newValue - frame.width }
    }

    var height: CGFloat {
        get { frame.height }
        set { frame.size.height = newValue }
    }
}
