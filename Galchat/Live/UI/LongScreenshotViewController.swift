import UIKit

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        let aspect = image.size.height / max(image.size.width, 1)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: aspect)
        ])
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}
