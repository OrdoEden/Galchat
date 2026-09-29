import UIKit
import SnapKit

// MARK: - 形象图片

/// 人格形象的解码与缓存。人格包没有形象时用 App 标志。
@MainActor
enum PersonaImages {
    static let logo = UIImage(named: "PersonaLogo")
    static let logoBackground = UIColor(red: 0.98, green: 0.80, blue: 0.85, alpha: 1)
    private static let cache = NSCache<NSString, UIImage>()

    static func portrait(for profile: PersonaPackage) -> UIImage? {
        guard let data = profile.portraitData else { return nil }
        let key = "portrait#\(profile.id)#\(profile.manifest.version)#\(data.count)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = UIImage(data: data) else { return nil }
        let image = decoded.preparingForDisplay() ?? decoded
        cache.setObject(image, forKey: key)
        return image
    }

    /// 头像：取形象上方的正方形区域（半身像的脸通常在这里）。
    static func avatar(for profile: PersonaPackage) -> UIImage? {
        guard let portrait = portrait(for: profile), portrait.size.width > 0 else { return nil }
        let key = "avatar#\(profile.id)#\(profile.manifest.version)#\(profile.portraitData?.count ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let side: CGFloat = 168
        let scale = side / portrait.size.width
        let height = portrait.size.height * scale
        let top = min(max(0, height * 0.04), max(0, height - side))
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            portrait.draw(in: CGRect(x: 0, y: -top, width: side, height: height))
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - 头像条

final class PersonaAvatarCell: UICollectionViewCell {
    static let reuseID = "PersonaAvatarCell"
    static let size = CGSize(width: 60, height: 84)

    enum Kind {
        case persona(image: UIImage?, name: String)
        case none
        case library
    }

    private let ring = UIView()
    private let imageView = UIImageView()
    private let symbolView = UIImageView()
    private let nameLabel = UILabel()
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.layer.cornerRadius = 30
        ring.layer.borderWidth = 2
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 26
        symbolView.contentMode = .center
        symbolView.tintColor = .secondaryLabel
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textAlignment = .center
        dot.backgroundColor = .galchatPink
        dot.layer.cornerRadius = 3

        contentView.addSubview(ring)
        ring.addSubview(imageView)
        imageView.addSubview(symbolView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(dot)
        ring.snp.makeConstraints { make in
            make.top.centerX.equalToSuperview()
            make.size.equalTo(60)
        }
        imageView.snp.makeConstraints { make in make.edges.equalToSuperview().inset(4) }
        symbolView.snp.makeConstraints { make in make.edges.equalToSuperview() }
        nameLabel.snp.makeConstraints { make in
            make.top.equalTo(ring.snp.bottom).offset(4)
            make.leading.trailing.equalToSuperview()
        }
        dot.snp.makeConstraints { make in
            make.size.equalTo(6)
            make.centerY.equalTo(nameLabel)
            make.leading.equalTo(nameLabel.snp.trailing).offset(-4)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ kind: Kind, isFocused: Bool, isActive: Bool) {
        let label: String
        switch kind {
        case .persona(let image, let name):
            imageView.image = image ?? PersonaImages.logo
            imageView.backgroundColor = PersonaImages.logoBackground
            symbolView.image = nil
            label = String(name.prefix(4))
            accessibilityLabel = name
        case .none:
            imageView.image = nil
            imageView.backgroundColor = .secondarySystemGroupedBackground
            symbolView.image = UIImage(systemName: "circle.slash")
            label = "不使用"
            accessibilityLabel = "不使用人格"
        case .library:
            imageView.image = nil
            imageView.backgroundColor = .secondarySystemGroupedBackground
            symbolView.image = UIImage(systemName: "arrow.down.circle")
            label = "人格库"
            accessibilityLabel = "打开人格库"
        }
        nameLabel.text = label
        nameLabel.textColor = isFocused ? .label : .secondaryLabel
        nameLabel.font = .systemFont(ofSize: 11, weight: isFocused ? .semibold : .regular)
        ring.layer.borderColor = (isFocused ? UIColor.label : .clear).resolvedColor(with: traitCollection).cgColor
        dot.isHidden = !isActive
        accessibilityValue = isActive ? "使用中" : nil
        accessibilityTraits = isFocused ? [.button, .selected] : .button
    }
}

// MARK: - 走马灯

/// 居中吸附、两侧缩小变淡的横向布局。
final class PersonaCarouselLayout: UICollectionViewFlowLayout {
    static func itemWidth(for containerWidth: CGFloat) -> CGFloat { min(floor(containerWidth * 0.64), 300) }
    static func height(for containerWidth: CGFloat) -> CGFloat { ceil(itemWidth(for: containerWidth) * 4 / 3) + 28 }

    override init() {
        super.init()
        scrollDirection = .horizontal
        minimumLineSpacing = 0
        minimumInteritemSpacing = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var pageWidth: CGFloat { itemSize.width }

    override func prepare() {
        if let collectionView {
            let width = Self.itemWidth(for: collectionView.bounds.width)
            itemSize = CGSize(width: width, height: ceil(width * 4 / 3))
            let side = (collectionView.bounds.width - width) / 2
            sectionInset = UIEdgeInsets(top: 14, left: side, bottom: 14, right: side)
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView, let attributes = super.layoutAttributesForElements(in: rect) else { return nil }
        let center = collectionView.contentOffset.x + collectionView.bounds.width / 2
        return attributes.map { original in
            let item = original.copy() as! UICollectionViewLayoutAttributes
            let distance = min(1, abs(item.center.x - center) / max(1, itemSize.width))
            let scale = 1 - 0.14 * distance
            item.transform = CGAffineTransform(scaleX: scale, y: scale)
            item.alpha = 1 - 0.45 * distance
            item.zIndex = Int((1 - distance) * 10)
            return item
        }
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint,
                                      withScrollingVelocity velocity: CGPoint) -> CGPoint {
        guard let collectionView, pageWidth > 0 else { return proposedContentOffset }
        let count = collectionView.numberOfItems(inSection: 0)
        let current = (collectionView.contentOffset.x / pageWidth).rounded()
        var page: CGFloat
        if abs(velocity.x) > 0.3 {
            page = current + (velocity.x > 0 ? 1 : -1)
        } else {
            page = (proposedContentOffset.x / pageWidth).rounded()
        }
        page = min(max(0, page), CGFloat(max(0, count - 1)))
        return CGPoint(x: page * pageWidth, y: proposedContentOffset.y)
    }
}

final class PersonaCarouselCell: UICollectionViewCell {
    static let reuseID = "PersonaCarouselCell"

    private let imageView = UIImageView()
    private let badge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 26
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 12)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        imageView.snp.makeConstraints { make in make.edges.equalToSuperview() }

        badge.text = "  使用中  "
        badge.font = .systemFont(ofSize: 12, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = .galchatPink
        badge.layer.cornerRadius = 12
        badge.clipsToBounds = true
        contentView.addSubview(badge)
        badge.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(12)
            make.height.equalTo(24)
        }
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(profile: PersonaPackage, isActive: Bool) {
        let portrait = PersonaImages.portrait(for: profile)
        imageView.image = portrait ?? PersonaImages.logo
        contentView.backgroundColor = portrait == nil ? PersonaImages.logoBackground : .secondarySystemGroupedBackground
        badge.isHidden = !isActive
        accessibilityLabel = profile.manifest.name
        accessibilityValue = isActive ? "使用中" : nil
        accessibilityHint = "左右滑动切换人格，长按可编辑或删除"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 26).cgPath
    }
}
