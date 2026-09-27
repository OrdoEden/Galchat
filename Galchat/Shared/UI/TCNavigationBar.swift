//
//  TCNavigationBarDelegate.swift
//  CleanUpAce
//
//  Created by gidon on 2026/7/22.
//

import UIKit
import SnapKit

@objc public protocol TCNavigationBarDelegate {
    func naviBackButtonAction()
    func naviRightButtonAction()
    @objc optional func naviRightSecondButtonAction() // 右侧第二按钮
    @objc optional func naviMidTitleAction()
}

/// 协议的默认实现
public extension TCNavigationBarDelegate {
    func naviRightButtonAction() {}
    func naviMidTitleAction() {}
}

open class NavigationBar: UIView {
    public static let barHeight: CGFloat = 56
    public static let largeTitleBarHeight: CGFloat = 64
    public static let homeTitleBarHeight: CGFloat = 44

    @objc public weak var delegate: TCNavigationBarDelegate?

    public var onLeadingButtonTapped: (() -> Void)?
    public var onRightSecondButtonTapped: (() -> Void)?
    public var onSecondaryButtonTapped: (() -> Void)?

    private var _interaction: Any? // 使用 Any 类型存储
    private var isPinnedToSafeArea = false
    private var usesLargeTitleLayout = false
    private var usesHomeTitleLayout = false
    private var hasSetupUI = false
    private var pinnedButtonBackgroundColor: UIColor = .white
    private var leadingButtonUsesText = false
    private var secondaryButtonUsesText = false
    private var primaryButtonUsesProStyle = false

    /// The top safe-area inset for this navigation bar's current window.
    /// It is zero until the view is attached to a window, then updates with
    /// rotation, multitasking, and other safe-area changes.
    private var kTopSafeHeight: CGFloat {
        safeAreaInsets.top
    }

    var adaptedIos26: Bool = true
    
    var closeIconName: String = "cancel_x_gray_30"
    var closeIconName26: String = "close_17"
    public var isUserModalIcon: Bool = false
    public var enableSmartModalAdaptation: Bool = false {
        didSet {
            // 如果在运行时动态修改，且已经显示在窗口上，立即刷新样式
            if enableSmartModalAdaptation && window != nil {
                applyModalStyle()
            }
        }
    }
    
    var defaultBackIconName: String = "icon_navi_back_36x36" {
        didSet {
            if !enableSmartModalAdaptation {
                setLeadingButton(
                    image: UIImage(named: defaultBackIconName) ?? defaultBackImage,
                    accessibilityLabel: "Back"
                )
            }
        }
    }

    private var defaultBackImage: UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        return UIImage(systemName: "chevron.left", withConfiguration: configuration)
    }

    @available(iOS 26.0, *)
    var interaction: UIScrollEdgeElementContainerInteraction? {
        get {
            return _interaction as? UIScrollEdgeElementContainerInteraction
        }
        set {
            _interaction = newValue
        }
    }
    
    @objc public lazy var backButton: UIButton = {
        var config = UIButton.makeBackButtonConfiguration(adaptedIos26: adaptedIos26)
		config.imagePadding = 8
        config.image = UIImage(named: defaultBackIconName) ?? defaultBackImage

        let button = HitTargetButton(configuration: config)
        button.setTitleColor(UIColor.black, for: .normal)
        button.tintColor = "#222222".toRGB
        button.clickEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 10)
        button.addTarget(self, action: #selector(backButtonAction), for: .touchUpInside)
		button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.accessibilityLabel = "Back"
        return button
    }()
    
    public lazy var rightButton: UIButton = {
        let button = HitTargetButton(configuration: UIButton.makeButtonConfiguration(adaptedIos26: adaptedIos26))
        button.setTitle(nil, for: .normal)
        button.tintColor = "#222222".toRGB
        button.setTitleColor(UIColor.black, for: .normal)
        button.adjustsImageWhenHighlighted = false
        button.clickEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 16)
        button.addTarget(self, action: #selector(rightButtonAction), for: .touchUpInside)
        button.titleLabel?.font = 16.normalFont
        button.isHidden = true
        button.contentVerticalAlignment = .center
        button.contentHorizontalAlignment = .center
        return button
	}() {
		didSet {
            if rightButton.configuration == nil {
                rightButton.configuration = UIButton.makeButtonConfiguration(adaptedIos26: adaptedIos26)
                rightButton.configuration?.background.backgroundColor = .clear
                rightButton.configuration?.baseBackgroundColor = .clear
                rightButton.updateConfiguration()
            }
            rightButton.contentVerticalAlignment = .center
            rightButton.contentHorizontalAlignment = .center
			rightButton.addTarget(self, action: #selector(rightButtonAction), for: .touchUpInside)
            contentView.addSubview(rightButton)
		}
	}
    
    public lazy var rightSecondButton: UIButton = {
        let button = HitTargetButton(configuration: UIButton.makeButtonConfiguration(adaptedIos26: adaptedIos26))
        button.setTitle(nil, for: .normal)
        button.tintColor = "#222222".toRGB
        button.setTitleColor(UIColor.black, for: .normal)
        button.adjustsImageWhenHighlighted = false
        button.clickEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 16)
        button.addTarget(self, action: #selector(rightSecondButtonAction), for: .touchUpInside)
        button.titleLabel?.font = 16.normalFont
        button.isHidden = true
        button.contentVerticalAlignment = .center
        button.contentHorizontalAlignment = .center
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }() {
        didSet {
            if rightSecondButton.configuration == nil {
                rightSecondButton.configuration = UIButton.makeButtonConfiguration(adaptedIos26: adaptedIos26)
                rightSecondButton.configuration?.background.backgroundColor = .clear
                rightSecondButton.configuration?.baseBackgroundColor = .clear
                rightSecondButton.updateConfiguration()
            }
            rightSecondButton.contentVerticalAlignment = .center
            rightSecondButton.contentHorizontalAlignment = .center
            rightSecondButton.addTarget(self, action: #selector(rightSecondButtonAction), for: .touchUpInside)
            contentView.addSubview(rightSecondButton)
        }
    }

    private let rightSecondTextLabel: UILabel = {
        let label = UILabel()
        label.font = 16.semiboldFont
        // This label is the text face of the scroll-edge Select All control.
        // Keep it readable when iOS applies the navigation bar's edge effect.
        label.textColor = .black
        label.textAlignment = .right
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = false
        label.isHidden = true
        return label
    }()
    
    lazy var contentView: UIView = {
        let view = UIView()
        return view
    }()
    
    public lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.text = ""
        label.textColor = "#222222".toRGB
        label.font = 17.semiboldFont
        label.textAlignment = .center
        label.isUserInteractionEnabled = true

        let tapGuesture = UITapGestureRecognizer(target: self, action: #selector(midTitleAction))
        label.addGestureRecognizer(tapGuesture)
        return label
    }()
    
    public var backButtonFont: UIFont? {
        didSet {
            backButton.titleLabel?.font = backButtonFont
        }
    }
    
    public var rightButtonFont: UIFont? {
        didSet {
            rightButton.titleLabel?.font = rightButtonFont
        }
    }
    
    public var rightSecondButtonFont: UIFont? {
        didSet {
            rightSecondButton.titleLabel?.font = rightSecondButtonFont
        }
    }
    
    public var titleLabelFont: UIFont? {
        didSet {
            titleLabel.font = titleLabelFont
        }
    }
    
    public var titleView: UIView? {
        didSet {
            setupUI()
            setupLayout()
        }
    }
    
    @objc public var title: String? {
        didSet {
            titleLabel.text = title?.local
        }
    }
    
    public var showDashLine: Bool? {
        didSet {
            dashLine.isHidden = !(showDashLine ?? false)
        }
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        setupUI()
        setupLayout()
    }

    init(adaptedIos26: Bool, defaultBackIconName: String? = nil) {
        self.adaptedIos26 = adaptedIos26
        if let defaultBackIconName {
            self.defaultBackIconName = defaultBackIconName
        }
        super.init(frame: .zero)
        self.backgroundColor = "#FFFFFF".toRGB

        setupUI()
        setupLayout()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupLayout()
    }

    /// Pins the navigation bar below the safe area using a stable height across view controllers.
    public func pinToTop(in containerView: UIView) {
        isPinnedToSafeArea = true

        if superview !== containerView {
            removeFromSuperview()
            containerView.addSubview(self)
        }

        updatePinnedConstraints(in: containerView)
        applyPinnedButtonStyle()
        setupLayout()
    }

    /// Applies the Library-style left-aligned title while retaining the shared button behavior.
    public func setLargeTitle(_ title: String?) {
        usesHomeTitleLayout = false
        usesLargeTitleLayout = true
        titleLabel.text = title?.local
        titleLabel.font = 28.boldFont
        titleLabel.textAlignment = .left
        setLeadingButton(image: nil)

        if isPinnedToSafeArea, let superview {
            updatePinnedConstraints(in: superview)
        }
        applyPinnedButtonStyle()
        setupLayout()
    }

    /// Shared 44pt title row for the four tab roots.
    public func setHomeTitle(_ title: String) {
        setLargeTitle(title)
        usesHomeTitleLayout = true
        titleLabel.font = 28.boldFont
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.85
        if isPinnedToSafeArea, let superview {
            updatePinnedConstraints(in: superview)
        }
        setupLayout()
    }

    /// Connects the bar to its page's scrolling content for the iOS 26 scroll-edge effect.
    public func attachScrollView(_ scrollView: UIScrollView) {
        guard #available(iOS 26.0, *) else { return }

        interaction?.scrollView = scrollView
        superview?.bringSubviewToFront(self)
    }

    private func updatePinnedConstraints(in containerView: UIView) {
        snp.remakeConstraints { make in
            make.top.equalTo(containerView.safeAreaLayoutGuide.snp.top)
            make.left.right.equalToSuperview()
            make.height.equalTo(usesHomeTitleLayout ? Self.homeTitleBarHeight :
                (usesLargeTitleLayout ? Self.largeTitleBarHeight : Self.barHeight))
        }
    }

    public func setLeadingButton(image: UIImage?, accessibilityLabel: String? = nil) {
        leadingButtonUsesText = false
        backButton.setTitle(nil, for: .normal)
        backButton.setImage(image, for: .normal)
        if var configuration = backButton.configuration {
            configuration.title = nil
            configuration.image = image
            configuration.contentInsets = .zero
            backButton.configuration = configuration
        }
        backButton.accessibilityLabel = accessibilityLabel
        backButton.isHidden = image == nil
        setupLayout()
    }

    /// Configures the leading item as a native glass text action on iOS 26.
    public func setLeadingButton(title: String?, accessibilityLabel: String? = nil) {
        leadingButtonUsesText = title != nil
        backButton.setImage(nil, for: .normal)
        backButton.setTitle(title, for: .normal)
        if var configuration = backButton.configuration {
            configuration.image = nil
            configuration.title = title
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: 20,
                bottom: 0,
                trailing: 20
            )
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = 16.semiboldFont
                return attributes
            }
            backButton.configuration = configuration
        }
        backButton.accessibilityLabel = accessibilityLabel
        backButton.isHidden = title == nil
        setupLayout()
    }

    /// Configures the left item in the trailing button group.
    public func setRightSecondButton(
        title: String?,
        accessibilityLabel: String? = nil
    ) {
        primaryButtonUsesProStyle = false
        rightSecondButton.setTitle(nil, for: .normal)
        rightSecondButton.setImage(nil, for: .normal)
        rightSecondButton.accessibilityLabel = accessibilityLabel
        rightSecondButton.isHidden = title == nil
        rightSecondTextLabel.isHidden = title == nil
        UIView.performWithoutAnimation {
            rightSecondTextLabel.text = title
            setupLayout()
            layoutIfNeeded()
        }
    }

    /// Configures the left item in the trailing button group as an icon action.
    public func setRightSecondButton(image: UIImage?, accessibilityLabel: String? = nil) {
        primaryButtonUsesProStyle = false
        rightSecondTextLabel.text = nil
        rightSecondTextLabel.isHidden = true
        rightSecondButton.setTitle(nil, for: .normal)
        rightSecondButton.setImage(image, for: .normal)
        if var configuration = rightSecondButton.configuration {
            configuration.title = nil
            configuration.image = image
            configuration.imagePadding = 0
            configuration.contentInsets = .zero
            rightSecondButton.configuration = configuration
        }
        rightSecondButton.accessibilityLabel = accessibilityLabel
        rightSecondButton.isHidden = image == nil
        rightSecondButton.contentHorizontalAlignment = .center
        setupLayout()
    }

    /// Configures the left item in the trailing button group as a commercial
    /// pill button, matching the Figma `PRO` control used on the Library page.
    public func setRightSecondButton(
        image: UIImage?,
        title: String?,
        imagePadding: CGFloat = 0,
        accessibilityLabel: String? = nil
    ) {
        primaryButtonUsesProStyle = image != nil && title != nil
        rightSecondTextLabel.text = nil
        rightSecondTextLabel.isHidden = true
        let displayImage = primaryButtonUsesProStyle
            ? image.map { Self.image($0, scaledTo: CGSize(width: 24, height: 24)) }
            : image
        rightSecondButton.setTitle(title, for: .normal)
        rightSecondButton.setImage(displayImage, for: .normal)
        rightSecondButton.titleLabel?.numberOfLines = 1
        rightSecondButton.titleLabel?.lineBreakMode = .byClipping

        if var configuration = rightSecondButton.configuration {
            configuration.title = title
            configuration.image = displayImage
            configuration.imagePadding = primaryButtonUsesProStyle ? imagePadding : 0
            configuration.contentInsets = primaryButtonUsesProStyle
                ? NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 12)
                : .zero
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = 15.mediumFont
                return attributes
            }

            if #unavailable(iOS 26.0) {
                configuration.background.backgroundColor = .white
                configuration.background.cornerRadius = 22
            }
            rightSecondButton.configuration = configuration
        }

        rightSecondButton.accessibilityLabel = accessibilityLabel
        rightSecondButton.isHidden = image == nil && title == nil
        rightSecondButton.contentHorizontalAlignment = .center
        setupLayout()
    }

    private static func image(_ image: UIImage, scaledTo size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Configures the rightmost icon button and its optional primary-action menu.
    public func setSecondaryButton(
        image: UIImage?,
        accessibilityLabel: String? = nil,
        menu: UIMenu? = nil
    ) {
        secondaryButtonUsesText = false
        let displayImage = image.map {
            Self.image($0, aspectFitIn: CGSize(width: 24, height: 24))
        }
        rightButton.setTitle(nil, for: .normal)
        rightButton.setImage(displayImage, for: .normal)
        if var configuration = rightButton.configuration {
            configuration.title = nil
            configuration.image = displayImage
            configuration.contentInsets = .zero
            rightButton.configuration = configuration
        }
        rightButton.accessibilityLabel = accessibilityLabel
        rightButton.menu = menu
        rightButton.showsMenuAsPrimaryAction = menu != nil
        rightButton.isHidden = image == nil
        setupLayout()
    }

    private static func image(_ image: UIImage, aspectFitIn size: CGSize) -> UIImage {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }

        let scale = min(size.width / sourceSize.width, size.height / sourceSize.height)
        let drawSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let origin = CGPoint(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2
        )
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }.withRenderingMode(.alwaysTemplate)
    }

    /// Configures the rightmost button as a text action.
    public func setSecondaryButton(title: String?, accessibilityLabel: String? = nil) {
        secondaryButtonUsesText = title != nil
        rightButton.setImage(nil, for: .normal)
        rightButton.setTitle(title, for: .normal)
        if var configuration = rightButton.configuration {
            configuration.image = nil
            configuration.title = title
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: 20,
                bottom: 0,
                trailing: 20
            )
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = 16.semiboldFont
                return attributes
            }
            rightButton.configuration = configuration
        }
        rightButton.accessibilityLabel = accessibilityLabel
        rightButton.menu = nil
        rightButton.showsMenuAsPrimaryAction = false
        rightButton.isHidden = title == nil
        setupLayout()
    }

    public func setSecondaryMenu(_ menu: UIMenu?) {
        rightButton.menu = menu
        rightButton.showsMenuAsPrimaryAction = menu != nil
    }

    /// Updates the shared title/button foreground color and the pre-iOS 26 button surface.
    public func setContentColor(
        _ color: UIColor,
        buttonBackgroundColor: UIColor = .white
    ) {
        pinnedButtonBackgroundColor = buttonBackgroundColor
        titleLabel.textColor = color

        [backButton, rightButton, rightSecondButton].forEach { button in
            button.tintColor = color
            button.setTitleColor(color, for: .normal)
            if var configuration = button.configuration {
                configuration.baseForegroundColor = color
                button.configuration = configuration
            }
        }
        rightSecondTextLabel.textColor = color

        if isPinnedToSafeArea {
            applyPinnedButtonStyle()
        }
    }
    
    public func setupUI() {
        guard !hasSetupUI else {
            if let titleView, titleView.superview !== contentView {
                contentView.addSubview(titleView)
            }
            return
        }
        hasSetupUI = true

        addSubview(contentView)
        contentView.addSubview(backButton)
        contentView.addSubview(rightButton)
        contentView.addSubview(rightSecondButton)
        contentView.addSubview(rightSecondTextLabel)
        contentView.addSubview(titleLabel)

        if let titleView = titleView {
            contentView.addSubview(titleView)
        }
        
        contentView.addSubview(dashLine)
        
        if #available(iOS 26.0, *), adaptedIos26, interaction == nil {
            self.backgroundColor = .clear
            let int = UIScrollEdgeElementContainerInteraction()
            int.edge = .top
            interaction = int
            addInteraction(interaction ?? int)
        }
    }
    
    public func setupLayout() {
        contentView.snp.remakeConstraints { make in
            if isPinnedToSafeArea {
                if usesHomeTitleLayout {
                    make.top.left.right.equalToSuperview()
                    make.height.equalTo(Self.homeTitleBarHeight)
                } else if usesLargeTitleLayout {
                    make.left.right.bottom.equalToSuperview()
                    make.height.equalTo(Self.barHeight)
                } else {
                    make.edges.equalToSuperview()
                }
            } else {
                make.top.equalToSuperview().offset(kTopSafeHeight).priority(ConstraintPriority(800))
                make.bottom.equalToSuperview()
                make.height.equalTo(50).priority(ConstraintPriority(900))
            }
            make.leading.trailing.equalToSuperview()
        }
        
        backButton.snp.remakeConstraints { make in
            if isPinnedToSafeArea {
                make.left.equalToSuperview().offset(16)
                if leadingButtonUsesText {
                    make.width.greaterThanOrEqualTo(44)
                } else {
                    make.width.equalTo(44)
                }
            } else if #available(iOS 26.0, *), adaptedIos26 {
                make.left.equalToSuperview().offset(16)
                make.width.greaterThanOrEqualTo(44)
            } else {
                make.left.equalToSuperview().offset(6)
            }
            make.centerY.equalToSuperview()
            make.height.equalTo(44)
        }
        
        rightButton.snp.remakeConstraints { make in
            make.right.equalToSuperview().inset(usesLargeTitleLayout ? 14 : 16)
            if secondaryButtonUsesText {
                make.width.greaterThanOrEqualTo(44)
            } else if usesLargeTitleLayout {
                make.width.equalTo(48)
            } else if isPinnedToSafeArea {
                make.width.equalTo(44)
            } else if #available(iOS 26.0, *), adaptedIos26 {
                make.width.greaterThanOrEqualTo(44)
            }
            make.centerY.equalTo(backButton)
            make.height.equalTo(usesLargeTitleLayout ? 48 : 44)
        }
        
        rightSecondButton.snp.remakeConstraints { make in
            make.right.equalTo(rightButton.snp.left).offset(isPinnedToSafeArea ? -10 : -16)
            if isPinnedToSafeArea || primaryButtonUsesProStyle {
                make.width.greaterThanOrEqualTo(44)
            } else if #available(iOS 26.0, *), adaptedIos26 {
                make.width.greaterThanOrEqualTo(44)
            }
            make.centerY.equalTo(backButton)
            make.height.equalTo(44)
        }

        rightSecondTextLabel.snp.remakeConstraints { make in
            make.leading.trailing.equalTo(rightSecondButton).inset(20)
            make.centerY.equalTo(rightSecondButton)
        }
        
        self.titleView?.isHidden = true
        
        titleLabel.snp.remakeConstraints { make in
            make.centerY.equalTo(backButton)
            if usesLargeTitleLayout {
                make.left.equalToSuperview().offset(16)
                make.right.lessThanOrEqualTo(rightSecondButton.snp.left).offset(-12)
            } else {
                make.centerX.equalToSuperview()
			    make.left.greaterThanOrEqualTo(backButton.snp.right).offset(10)
                make.width.greaterThanOrEqualTo(46)
            }
        }
        
        dashLine.snp.remakeConstraints { make in
            make.left.equalTo(titleLabel).offset(-3)
            make.right.equalTo(titleLabel).offset(3)
            make.top.equalTo(titleLabel.snp.bottom).offset(3)
            make.height.equalTo(1)
        }
        
        if let titleView = titleView {
            titleView.isHidden = false
            self.titleLabel.isHidden = true
            titleView.snp.remakeConstraints { make in
                make.centerX.equalToSuperview()
                make.centerY.equalTo(backButton)
                make.size.equalTo(titleView.snp.size)
            }
            
            dashLine.snp.remakeConstraints { make in
                make.left.equalTo(titleView).offset(-3)
                make.right.equalTo(titleView).offset(3)
                make.top.equalTo(titleView.snp.bottom).offset(3)
                make.height.equalTo(1)
            }
        }

        if usesHomeTitleLayout {
            rightButton.snp.remakeConstraints { make in
                make.right.equalToSuperview().inset(16)
                make.centerY.equalToSuperview()
                make.size.equalTo(Self.homeTitleBarHeight)
            }
            rightSecondButton.snp.remakeConstraints { make in
                if rightButton.isHidden {
                    make.right.equalToSuperview().inset(16)
                } else {
                    make.right.equalTo(rightButton.snp.left).offset(-10)
                }
                make.centerY.equalToSuperview()
                make.height.equalTo(Self.homeTitleBarHeight)
                make.width.greaterThanOrEqualTo(Self.homeTitleBarHeight)
            }
            titleLabel.snp.remakeConstraints { make in
                make.left.equalToSuperview().offset(16)
                make.centerY.equalToSuperview()
                if !rightSecondButton.isHidden {
                    make.right.lessThanOrEqualTo(rightSecondButton.snp.left).offset(-12)
                } else if !rightButton.isHidden {
                    make.right.lessThanOrEqualTo(rightButton.snp.left).offset(-12)
                } else {
                    make.right.lessThanOrEqualToSuperview().inset(16)
                }
            }
        }
    }

    private func applyPinnedButtonStyle() {
        [backButton, rightButton, rightSecondButton].forEach { button in
            if #available(iOS 26.0, *), adaptedIos26 {
                button.layer.shadowOpacity = 0
                return
            }
        }
    }
    
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        setupLayout()
        // 当视图加载到窗口时，如果开关是开的，应用样式
        if enableSmartModalAdaptation {
            applyModalStyle()
        }
    }

    open override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setupLayout()
    }
    
    /// 应用模态样式（私有方法）
    private func applyModalStyle() {
        if isUserModalIcon {
            if #available(iOS 26.0, *) {
                backButton.configuration?.image = UIImage(named: closeIconName26)
            } else {
                backButton.configuration?.image = UIImage(named: closeIconName)
            }
            backButton.updateConfiguration()
    
        }
        // 调整布局：直接移除 kTopSafeHeight 偏移
        // 注意：这里不再判断 isFullScreen，只要开关打开，就强制移除偏移
        contentView.snp.remakeConstraints { make in
            make.top.equalToSuperview().priority(ConstraintPriority(800)) // 关键点：直接顶格
            make.bottom.equalToSuperview()
            make.height.equalTo(50).priority(ConstraintPriority(900))
            make.leading.trailing.equalToSuperview()
        }
        
        backButton.snp.remakeConstraints { make in
            if #available(iOS 26.0, *), adaptedIos26 {
                make.top.equalTo(16)
                make.left.equalToSuperview().offset(16)
                make.width.greaterThanOrEqualTo(44)
            } else {
                make.left.equalToSuperview().offset(6)
            }
            make.centerY.equalToSuperview()
            make.height.equalTo(44)
        }
        // 触发布局刷新
        self.layoutIfNeeded()
    }
    
    public override var intrinsicContentSize: CGSize {
        return CGSize(width: rightButton.right + 20, height: self.height)
    }
    
    lazy var dashLine: UIView = {
        let view = UIView()
        let layer = CAShapeLayer()
        layer.lineDashPattern = [3, 3]
        layer.lineWidth = 1
        layer.strokeColor = "#999999".toRGB.cgColor
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -10, y: 0.5))
        path.addLine(to: CGPoint(x: 1000, y: 0.5))
        layer.path = path.cgPath
        view.layer.addSublayer(layer)
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()
}

// MARK: - actions
extension NavigationBar {
    @objc func backButtonAction() {
        if let onLeadingButtonTapped {
            onLeadingButtonTapped()
        } else {
            delegate?.naviBackButtonAction()
        }
    }
    
    @objc func rightButtonAction() {
        if let onSecondaryButtonTapped {
            onSecondaryButtonTapped()
        } else {
            delegate?.naviRightButtonAction()
        }
    }
    
    @objc func rightSecondButtonAction() {
        if let onRightSecondButtonTapped {
            onRightSecondButtonTapped()
        } else {
            delegate?.naviRightSecondButtonAction?()
        }
    }
    
    @objc func midTitleAction() {
        delegate?.naviMidTitleAction?()
    }
}
