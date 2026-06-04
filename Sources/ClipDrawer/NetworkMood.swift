import Foundation
import Network
import SwiftUI

/// 监测「现在能不能顺利用 Claude」，把结果映射成小机器人的心情：
///   - happy：能连上 Anthropic 且延迟低 → 畅通
///   - neutral：能连上但偏慢 → 五五开
///   - sad：没网 / 连不上（如被墙、超时）→ 用不了
///
/// 做法：NWPathMonitor 监听链路通断；有网时定时 HEAD 探测 api.anthropic.com，
/// 任意 HTTP 响应（含 401/403/405）都说明能连到 Anthropic，按延迟分档。
@MainActor
final class ClaudeReachability {
    private let state: DrawerState
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var hasNetwork = true
    private var inflight: URLSessionDataTask?   // 当前探测任务；发起新探测前取消旧的，避免乱序覆盖
    private let probeURL = URL(string: "https://api.anthropic.com/v1/messages")!

    init(state: DrawerState) { self.state = state }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasNetwork = ok
                if ok { self.probe() }
                else { self.setMood(.sad, "没有网络连接") }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        probe()
        // 每 30s 复探一次，跟上网络变化（连/断 VPN、信号波动等）
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func setMood(_ mood: ClaudeMood, _ detail: String) {
        guard state.mood != mood || state.moodDetail != detail else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            state.mood = mood
            state.moodDetail = detail
        }
    }

    private func probe() {
        guard hasNetwork else { setMood(.sad, "没有网络连接"); return }
        inflight?.cancel()              // 取消上一发未完成的探测，确保「最后发起」的结果胜出
        var req = URLRequest(url: probeURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let started = Date()
        let task = URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let elapsed = Date().timeIntervalSince(started)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let urlErr = error as? URLError, urlErr.code == .cancelled { return }  // 被新探测取代，忽略
                if response is HTTPURLResponse {
                    // 能连到 Anthropic（任何 HTTP 状态码都算连通）
                    let ms = Int(elapsed * 1000)
                    if elapsed < 1.0 { self.setMood(.happy, "延迟 \(ms)ms · 畅通") }
                    else { self.setMood(.neutral, "延迟 \(ms)ms · 偏慢") }
                } else {
                    // 用稳定的错误码判断超时（localizedDescription 会随系统语言变化，中文系统下匹配不到 "timed out"）
                    let timedOut = (error as? URLError)?.code == .timedOut
                    self.setMood(.sad, timedOut ? "连接超时" : "无法连接")
                }
            }
        }
        inflight = task
        task.resume()
    }
}
