import UIKit
import SnapKit

/// 长截图预览：可缩放、可分享。分享由用户主动触发，App 不自动保存。
final class LongScreenshotViewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "长截图"
        view.backgroundColor = .secondarySystemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
                present(share, animated: true)
            }
        )
        scrollView.delegate = self
        scrollView.maximumZoomScale = 3
        scrollView.minimumZoomScale = 1
        imageView.image = image
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        let aspect = image.size.height / max(image.size.width, 1)
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.bottom.equalToSuperview()
        }
        imageView.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.width.equalTo(scrollView.frameLayoutGuide)
            make.height.equalTo(imageView.snp.width).multipliedBy(aspect)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
