import CoreGraphics
import Foundation
import SeeU

/// 调试用：把真正送进 SeeU 的帧和当时的遮挡结果写到 Documents/SeeUReplay，
/// 供 SeeU `ReplayTests` 按原时间顺序回放、复现真实场景里的识别和拼接问题。
///
/// 只在用户在实时会话页手动打开时录制；文件可通过“文件”App 或 Finder 导出。
/// 截图包含聊天内容，仅用于本机调试，不会上传。
nonisolated final class FrameRecorder: @unchecked Sendable {
    static let shared = FrameRecorder()
    static let enabledKey = "Galchat.debug.recordFrames"
    /// 单次录屏最多保存的帧数（每帧约 100–200 KB）。
    static let frameLimit = 1500

    struct Sidecar: Codable {
        let index: Int
        let frameID: UUID
        let sessionID: UUID
        /// 采集时间（Unix 秒，保留毫秒）。
        let capturedAt: Double
        var keyboardTop: Double?
        var occluders: [[Double]]
    }

    private let queue = DispatchQueue(label: "galchat.frame-recorder", qos: .utility)
    private var directory: URL?
    private var sessionID: UUID?
    private var count = 0
    private var indices: [UUID: Int] = [:]

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { queue.async { self.directory = nil; self.sessionID = nil } }
        }
    }

    static var rootURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SeeUReplay", isDirectory: true)
    }

    /// 在送进 SeeU 之前调用：写入 JPEG 与基础信息。
    func record(jpeg: Data, frameID: UUID, sessionID: UUID, capturedAt: Date) {
        guard isEnabled else { return }
        queue.async {
            if self.sessionID != sessionID || self.directory == nil {
                self.startDirectory(for: sessionID, at: capturedAt)
            }
            guard let directory = self.directory, self.count < Self.frameLimit else { return }
            let index = self.count
            self.count += 1
            self.indices[frameID] = index
            let name = String(format: "%05d", index)
            try? jpeg.write(to: directory.appendingPathComponent("\(name).jpg"))
            self.write(Sidecar(index: index, frameID: frameID, sessionID: sessionID,
                               capturedAt: capturedAt.timeIntervalSince1970,
                               keyboardTop: nil, occluders: []), to: directory, name: name)
        }
    }

    /// 在宿主遮挡策略算出结果后调用（OCR 队列上），补全键盘顶部和画中画遮挡区域。
    func recordExclusion(_ exclusion: FrameExclusion, frameID: UUID, sessionID: UUID, capturedAt: Date) {
        guard isEnabled else { return }
        queue.async {
            guard let directory = self.directory, self.sessionID == sessionID,
                  let index = self.indices.removeValue(forKey: frameID) else { return }
            let sidecar = Sidecar(
                index: index, frameID: frameID, sessionID: sessionID, capturedAt: capturedAt.timeIntervalSince1970,
                keyboardTop: exclusion.keyboardTop.map(Double.init),
                occluders: exclusion.occluders.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
            )
            self.write(sidecar, to: directory, name: String(format: "%05d", index))
        }
    }

    /// 包一层遮挡策略，让录制拿到与识别完全相同的遮挡结果。
    func wrap(_ policy: @escaping @Sendable ([OCRLine], CGSize) -> FrameExclusion,
              frameID: UUID, sessionID: UUID, capturedAt: Date) -> FrameExclusionPolicy {
        guard isEnabled else { return FrameExclusionPolicy(policy) }
        return FrameExclusionPolicy { [self] lines, size in
            let result = policy(lines, size)
            recordExclusion(result, frameID: frameID, sessionID: sessionID, capturedAt: capturedAt)
            return result
        }
    }

    private func startDirectory(for sessionID: UUID, at date: Date) {
        guard let root = Self.rootURL else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        self.sessionID = sessionID
        count = 0
        indices = [:]
    }

    private func write(_ sidecar: Sidecar, to directory: URL, name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sidecar) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).json"))
    }
}
