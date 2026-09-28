import UIKit

/// 一排按键。按「字母键宽」为单位排版，复刻系统键盘的错落。
///
/// 系统键盘的字母键宽固定为「整排 10 等分」，不随本排键数拉伸：
/// 第二排 9 个键因此整体居中、比第一排缩进半个键位；第三排两端是更宽的 ⇧ / ⌫，
/// 中间 7 个字母居中。用 `UIStackView.fillEqually` 做不出这种错落。
final class KeyRowView: UIView {
    enum Width {
        /// 字母键宽的倍数。
        case units(CGFloat)
        /// 占满剩余宽度（多个 flex 平分）。
        case flex
    }

    enum Arrangement {
        /// 从左依次排。含 flex 时正好铺满整排。
        case leading
        /// 整组居中（第二排）。
        case centered
        /// 首尾贴边，中间一组居中（第三排 ⇧ … ⌫）。
        case pinnedEdges
    }

    /// 键间距。与 `unitWidth` 共同决定每个键的位置。
    var gap: CGFloat = 6
    private var items: [(view: UIView, width: Width)] = []
    private var arrangement: Arrangement = .leading

    func setItems(_ items: [(UIView, Width)], arrangement: Arrangement) {
        self.items.forEach { $0.view.removeFromSuperview() }
        self.items = items.map { (view: $0.0, width: $0.1) }
        self.arrangement = arrangement
        items.forEach { addSubview($0.0) }
        setNeedsLayout()
    }

    /// 一个字母键的宽度：整排按 10 个键 + 9 个间距等分。
    var unitWidth: CGFloat { max(0, (bounds.width - 9 * gap) / 10) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let visible = items.filter { !$0.view.isHidden }
        guard !visible.isEmpty else { return }
        let total = bounds.width
        let unit = unitWidth
        let fixed = visible.reduce(CGFloat(0)) {
            if case .units(let n) = $1.width { return $0 + n * unit }
            return $0
        }
        let flexCount = visible.filter { if case .flex = $0.width { return true }; return false }.count
        let gaps = CGFloat(visible.count - 1) * gap
        let flexWidth = flexCount > 0 ? max(0, (total - fixed - gaps) / CGFloat(flexCount)) : 0
        let widths: [CGFloat] = visible.map {
            if case .units(let n) = $0.width { return n * unit }
            return flexWidth
        }

        func place(_ range: Range<Int>, from start: CGFloat) {
            var x = start
            for index in range {
                visible[index].view.frame = CGRect(x: x, y: 0, width: widths[index], height: bounds.height)
                x += widths[index] + gap
            }
        }
        func span(_ range: Range<Int>) -> CGFloat {
            range.reduce(CGFloat(0)) { $0 + widths[$1] } + CGFloat(max(0, range.count - 1)) * gap
        }

        switch arrangement {
        case .leading:
            place(0..<visible.count, from: 0)
        case .centered:
            let all = 0..<visible.count
            place(all, from: (total - span(all)) / 2)
        case .pinnedEdges where visible.count >= 3:
            place(0..<1, from: 0)
            let middle = 1..<(visible.count - 1)
            place(middle, from: (total - span(middle)) / 2)
            place((visible.count - 1)..<visible.count, from: total - widths[visible.count - 1])
        case .pinnedEdges:
            place(0..<visible.count, from: 0)
        }
    }
}

/// 展开后的完整候选网格，对应系统候选条右侧 ⌄ 展开的面板。
///
/// 每个候选的宽度向上取整到「六分之一屏宽」的整数倍，逐行铺开，和系统一样
/// 短词整齐成列、长词占多格。
final class CandidateGridView: UIScrollView {
    static let rowHeight: CGFloat = 46
    private var cells: [UIView] = []

    func setCells(_ cells: [UIView]) {
        self.cells.forEach { $0.removeFromSuperview() }
        self.cells = cells
        cells.forEach { addSubview($0) }
        contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let column = width / 6
        var x: CGFloat = 0
        var y: CGFloat = 0
        for cell in cells {
            let natural = cell.intrinsicContentSize.width
            let cellWidth = min(width, max(1, ceil(natural / column)) * column)
            if x > 0, x + cellWidth > width + 0.5 {
                x = 0
                y += Self.rowHeight
            }
            cell.frame = CGRect(x: x, y: y, width: cellWidth, height: Self.rowHeight)
            x += cellWidth
        }
        contentSize = CGSize(width: width, height: cells.isEmpty ? 0 : y + Self.rowHeight)
    }
}
