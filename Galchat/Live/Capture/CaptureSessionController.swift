import UIKit
import VisynCapture

/// 采集与 PiP 跟随应用会话，切换 Tab 或退出设置不会释放它们。
@MainActor
final class CaptureSessionController {
    static let shared = CaptureSessionController()

    private var capture: VisynCaptureController?
    private weak var host: UIView?
    private let live = LiveChatCoordinator.shared
    private var observers: [UUID: () -> Void] = [:]
    private var lastPickerRequest = Date.distantPast
    private(set) var errorMessage: String?
    private(set) var frameDescription = "等待屏幕数据"
    private var receivedFrames = 0

    var isPrepared: Bool { capture != nil }
    var state: VisynBroadcastState { capture?.state ?? .stopped }
    var isPictureInPictureActive: Bool { capture?.isPictureInPictureActive == true }
    var contentSize: CGSize {
        capture?.pictureInPictureContentSize ?? VisynPictureInPictureSize.load() ?? VisynPictureInPictureSize.landscape
    }
    var statusDescription: String {
        switch state {
        case .broadcasting: return "正在采集屏幕"
        case .paused: return "录屏已暂停"
        case .stopped: return isPrepared ? "录屏已停止" : "准备就绪"
        }
    }

    private init() {}

    func attachHost(_ host: UIView) { self.host = host }

    @discardableResult
    func prepareIfNeeded() -> Bool {
        if capture != nil { return true }
        guard let host, host.window != nil else {
            report("页面尚未准备好，请稍后重试。")
            return false
        }
        errorMessage = nil
        do {
            let controller = try VisynCaptureController(
                configuration: .load(), pictureInPictureContent: live.makePiPContent(),
                pictureInPictureContentSize: contentSize,
                pictureInPictureFramesPerSecond: 15
            )
            capture = controller
            live.pictureInPictureContentSizeDidChange(controller.pictureInPictureContentSize)
            controller.onStateChange = { [weak self] state in
                guard let self else { return }
                live.captureStateChanged(state)
                if state == .stopped {
                    receivedFrames = 0
                    frameDescription = "等待屏幕数据"
                }
                notify()
            }
            controller.onFrame = { [weak self] frame in
                guard let self else { return }
                receivedFrames += 1
                frameDescription = "已收到 \(receivedFrames) 帧 · \(frame.width) × \(frame.height)"
                live.receive(frame)
                notify()
            }
            controller.onPictureInPictureChange = { [weak self] _ in self?.notify() }
            controller.onError = { [weak self] error in self?.report(error.localizedDescription) }
            controller.prepare(on: host)
            // prepare 的同步失败必须允许下次重新初始化。
            if errorMessage != nil {
                capture = nil
                notify()
                return false
            }
            notify()
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    /// 返回 true 表示已有录屏（含暂停），由入口展示停止方法；不改变录屏或画中画状态。
    @discardableResult
    func quickStart() -> Bool {
        guard prepareIfNeeded(), let capture else { return false }
        errorMessage = nil
        if capture.state != .stopped {
            notify()
            return true
        }
        showBroadcastPicker()
        return false
    }

    func showBroadcastPicker() {
        guard prepareIfNeeded(), let capture, let host, host.window != nil,
              host.window?.windowScene?.activationState == .foregroundActive,
              Date().timeIntervalSince(lastPickerRequest) > 1 else { return }
        // ReplayKit 没有取消回调，仅防连点，不用永久 pending 状态锁住重试。
        lastPickerRequest = Date()
        errorMessage = nil
        capture.showBroadcastPicker(on: host)
        notify()
    }

    func togglePictureInPicture() {
        guard prepareIfNeeded() else { return }
        errorMessage = nil
        capture?.togglePictureInPicture()
        notify()
    }

    func applyContentSize(_ size: CGSize) {
        guard prepareIfNeeded(), let capture else { return }
        do {
            try capture.setPictureInPictureContentSize(size)
            live.pictureInPictureContentSizeDidChange(capture.pictureInPictureContentSize)
            try VisynPictureInPictureSize.save(capture.pictureInPictureContentSize)
            errorMessage = nil
            notify()
        } catch {
            report("画中画尺寸设置失败：\(error.localizedDescription)")
        }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func report(_ message: String) {
        errorMessage = message
        notify()
    }

    private func notify() { Array(observers.values).forEach { $0() } }
}
