import AppKit
import SwiftUI
import Combine

enum PanelMode {
    case floating   // 悬浮可拖拽面板
    case menuBar    // 已停靠到菜单栏
}

/// Claude 网络可用性心情：开心(畅通) / 平常(能用但偏慢) / 难过(连不上)。
enum ClaudeMood {
    case happy, neutral, sad
}

@MainActor
final class DrawerState: ObservableObject {
    @Published var mode: PanelMode = .floating
    /// 悬浮模式下是否展开（铺下来）
    @Published var expanded: Bool = false
    /// 是否显示设置面板
    @Published var showSettings: Bool = false
    /// 当前 Claude 网络心情；由 ClaudeReachability 实时刷新
    @Published var mood: ClaudeMood = .neutral
    /// 心情副文本（延迟 / 原因），显示在状态条
    @Published var moodDetail: String = "正在检测网络…"
    /// 心情主文本
    var moodText: String {
        switch mood {
        case .happy: return "Claude 连接顺畅"
        case .neutral: return "网络一般，能用"
        case .sad: return "连不上 Claude"
        }
    }
    /// 久坐提醒模式：机器人会缓慢随机走动，气泡提示起来活动
    @Published var breakMode: Bool = false
    /// 进入提醒时已连续工作的分钟数
    @Published var workedMinutes: Int = 0
    /// 折叠态机器人下方「说话气泡」要显示的文字
    var bubbleText: String {
        if breakMode {
            return "已经工作 \(workedMinutes) 分钟啦，\n起来走走、喝口水？"
        }
        switch mood {
        case .happy: return "Claude 连接顺畅 😊"
        case .neutral: return "网络一般，能用 😐"
        case .sad: return "连不上 Claude 😢"
        }
    }
    /// 由 AppController 注入：用户点「我起来走过了」确认，重置久坐计时、停止走动
    var onBreakConfirm: (() -> Void)?
    /// 由 AppController 注入：从菜单栏恢复为悬浮窗口
    var onUndock: (() -> Void)?
    /// 由 AppController 注入：点击把手收起展开的面板
    var onCollapse: (() -> Void)?
    /// 由 AppController 注入：折叠状态下点击把手展开（铺下来）
    var onExpand: (() -> Void)?
    /// 由 AppController 注入：把悬浮窗收起到顶部菜单栏（带动画）
    var onDock: (() -> Void)?
    /// 由 AppController 注入：退出软件（带退出动画）
    var onQuit: (() -> Void)?
    /// 由 AppController 注入：切换展开 / 收起（供无障碍 activate 使用）
    var onToggle: (() -> Void)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let store = HistoryStore()
    lazy var monitor = ClipboardMonitor(store: store)
    let state = DrawerState()

    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // 拖拽时记录的目标位置（顶边 Y 与中心 X，按中心锚定，展开/折叠宽度不同也居中对齐）
    private var desiredCenterX: CGFloat = 0
    private var desiredTopY: CGFloat = 0
    // 用计数器而不是 Bool：多段动画叠加时（例如 expand 紧跟 recomputePanelHeight），
    // 任何一段完成都不会把还没结束的 guard 提前清零。
    private var programmaticMoveCounter = 0
    // 退出动画进行中，避免菜单栏「退出」和设置面板「退出」重复触发
    private var isQuitting = false
    // dock() 内部用 DispatchQueue.main.async 延迟读 status item 位置；防止延迟期间被重复入队
    private var dockPending = false

    // 悬停检测（基于鼠标实际位置，避免窗口缩放打断的跟踪丢失）
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    // 鼠标移出面板后多久收起
    private let leaveCollapseDelay: TimeInterval = 0.25
    // 手动收起后，鼠标仍停在顶部把手上时，先别立刻重新展开；等鼠标离开一次再说
    private var suppressExpandUntilExit = false
    // 即使别的 app 在前台，也能实时拿到鼠标移动；定时器轮询可能拿到陈旧位置
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    // 拖拽时显示"抓手"光标
    private var grabPushed = false
    private var lastPanelOrigin: CGPoint = .zero

    // 拖动机器人移动面板：手势开始时的窗口原点 + 开始前的「停留锚点」。
    // 若这次拖动最终把面板甩到顶部停靠，恢复悬浮时要回到「拖动前」的停留位，而不是顶部。
    // 拖动用「拖动前的停留位」——停靠到菜单栏后，恢复悬浮飞回这里（而非顶部）
    private var dragRestCenterX: CGFloat = 0
    private var dragRestTopY: CGFloat = 0
    // 顶边越过可视区顶部多少点才算「拖到菜单栏」触发停靠
    private let menuBarDockOvershoot: CGFloat = 6
    // 上次停靠时菜单栏图标的屏幕位置——undock 用它作动画起点，保证「从哪儿收上去、就从哪儿放下来」
    private var lastDockIconRect: NSRect?
    // 网络可用性监测（Claude 能不能用 → 小机器人心情）
    private lazy var reachability = ClaudeReachability(state: state)

    // 尺寸常量
    private let panelWidth: CGFloat = 400        // 展开宽度
    private let robotZoneHeight: CGFloat = 80     // 顶部「机器人区」高度（悬停热区）
    private let collapsedHeight: CGFloat = 80     // = robotZoneHeight，旧名沿用（容器 / 热区 / chrome 计算）
    private let expandedHeight: CGFloat = 620     // 展开时高度上限——含顶部 80pt 机器人区域

    // 折叠态面板尺寸：机器人 + 下方说话气泡。气泡内容（心情 / 久坐提醒）不同，尺寸也不同。
    private var collapsedPanelWidth: CGFloat { state.breakMode ? 250 : 184 }
    private var collapsedPanelHeight: CGFloat { robotZoneHeight + (state.breakMode ? 92 : 46) }

    // 展开时面板的当前高度——会随条数 / 状态变化自然增减，封顶在 expandedHeight。
    private var currentExpandedHeight: CGFloat = 620
    // 订阅 store / state 变化，自动重算面板高度
    private var contentSubscriptions = Set<AnyCancellable>()

    // 久坐提醒
    private var workStartTime = Date()           // 本段连续工作的开始时间
    private var breakCheckTimer: Timer?          // 每分钟检查是否该提醒
    private var wanderTimer: Timer?              // 提醒模式下每隔几秒挪一个随机位置
    private let workThreshold: TimeInterval = 50 * 60   // 连续工作 50 分钟触发提醒

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.onUndock = { [weak self] in self?.undock() }
        state.onCollapse = { [weak self] in self?.collapse() }
        state.onExpand = { [weak self] in self?.expand() }
        state.onDock = { [weak self] in self?.dock() }
        state.onToggle = { [weak self] in self?.toggleExpand() }
        state.onQuit = { [weak self] in self?.quitApp() }
        state.onBreakConfirm = { [weak self] in self?.confirmBreak() }

        // 条数变化 / 设置页切换都会改变内容高度，订阅起来自动重算面板高度。
        store.$items
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recomputePanelHeight() }
            }
            .store(in: &contentSubscriptions)
        state.$showSettings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recomputePanelHeight() }
            }
            .store(in: &contentSubscriptions)
        // 进入 / 退出久坐提醒会改变折叠态尺寸（要容下提醒气泡 + 按钮）→ 折叠时同步面板大小
        state.$breakMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self, self.state.mode == .floating, !self.state.expanded else { return }
                    self.setPanelFrame(animated: true, expanded: false)
                }
            }
            .store(in: &contentSubscriptions)

        buildPanel()

        if let vf = NSScreen.main?.visibleFrame {
            desiredCenterX = vf.midX
            desiredTopY = vf.maxY
        }
        setPanelFrame(animated: false, expanded: false)
        panel.orderFrontRegardless()
        monitor.start()
        startHoverMonitor()
        startMouseMonitors()
        reachability.start()   // 开始监测 Claude 网络可用性 → 驱动小机器人心情
        startBreakMonitor()    // 久坐提醒：连续工作够久 → 机器人走动提醒起来活动

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 用户切到别的 app（点击别的窗口、桌面、Dock 等通常都会触发别的 app 激活）→ 收起
        // 这是「点击面板外即收起」的可靠兜底：全局鼠标监听在新版 macOS 上有时会被
        // 隐私策略静默拦截，但 NSWorkspace 的应用激活通知不受影响。
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func otherAppActivated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }   // 是我们自己被激活，忽略
        // 有模态 / sheet 在前（清空历史、退出确认等）时不要自动收起：sheet 在某些流程下被认为是"别的 app"
        if NSApp.modalWindow != nil || NSApp.keyWindow?.isSheet == true { return }
        // 切到别的 app：悬浮面板收起，菜单栏 popover 也关掉
        if state.mode == .floating, state.expanded { collapse() }
        if let pop = popover, pop.isShown { pop.performClose(nil) }
    }

    @objc private func screenChanged() {
        if state.mode == .floating { setPanelFrame(animated: false, expanded: state.expanded) }
    }

    // MARK: - 面板构建

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                    // 不要 AppKit 整体阴影：SwiftUI 内部按机器人 / 记录面板分别加阴影
        panel.hidesOnDeactivate = false
        // 整个面板可按背景拖动来移动：机器人区 + 展开后的卡片区都靠它。
        // （历史教训：曾在机器人上盖一层 AppKit `WindowDragView` 想单独接管拖动/点击，
        //  但它会拦截事件却又没能可靠移动窗口，反而把机器人变成「点了没反应、拖不动」，
        //  还和背景拖动竞态。最终去掉那层，机器人和卡片一样统一走 isMovableByWindowBackground，
        //  展开/收起改由悬停驱动。）列表行 / 按钮等控件不受影响，仍可正常点击。
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        // 不再用 NSVisualEffectView 包整个面板——「玻璃底」只出现在展开后的记录区域，
        // 由 SwiftUI 里 `.background(.thickMaterial)` 渲染。折叠时整个面板透明，只看见小机器人。
        // 用一个普通 NSView 容器当 contentView + 面板 .resizable：彻底切断 NSHostingView「按 SwiftUI
        // 内容贴合尺寸去改窗口大小」的行为（否则折叠窗口会被缩成机器人那么大 72×73 且无法展开）。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight))
        container.autoresizesSubviews = true
        let root = DrawerView(store: store, state: state)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        panel.contentView = container
        self.panel = panel
    }

    private func setPanelFrame(animated: Bool, expanded: Bool) {
        let h = expanded ? currentExpandedHeight : collapsedPanelHeight
        let w = expanded ? panelWidth : collapsedPanelWidth
        // 校验目标 frame 落在当前真实存在的屏幕上，否则会把面板甩到已断开的显示器、菜单栏之上等。
        let baseRect = NSRect(x: desiredCenterX - w / 2, y: desiredTopY - h, width: w, height: h)
        let frame = clampedRectOnScreen(baseRect)
        // 夹回屏幕后把锚点同步成实际落点，否则下次再 setPanelFrame 会从过期(越界)锚点重算而跳位。
        desiredCenterX = frame.midX
        desiredTopY = frame.maxY
        programmaticMoveCounter += 1
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.programmaticMoveCounter -= 1 }
            })
        } else {
            panel.setFrame(frame, display: true)
            programmaticMoveCounter -= 1
        }
    }

    /// 把目标 rect 夹紧到当前存在的某块屏幕的 visibleFrame 内：
    /// 若与所有屏幕都不相交（例如用户从已断开的高分屏拖下来），重置到主屏中央顶端。
    /// 同时把 X 钳到该屏 visibleFrame 的左右边界内，避免漂出屏幕。
    private func clampedRectOnScreen(_ rect: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let target = screens.first(where: { $0.visibleFrame.intersects(rect) })
            ?? NSScreen.main
        guard let s = target else { return rect }
        let vf = s.visibleFrame
        var r = rect
        // 若与任何屏幕都不相交，desiredCenterX/Y 已经过期：回到主屏中央顶端
        if !screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
            desiredCenterX = vf.midX
            desiredTopY = vf.maxY
            r.origin.x = vf.midX - rect.width / 2
            r.origin.y = vf.maxY - rect.height
        }
        if r.minX < vf.minX { r.origin.x = vf.minX }
        if r.maxX > vf.maxX { r.origin.x = vf.maxX - r.width }
        if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height }
        return r
    }

    /// 面板当前所在屏幕。`panel.screen` 在面板正好落在多显示器之间的空隙时会返回 nil，
    /// 此时按面板中心点找一块包含它的屏幕，最后才退回主屏——避免停靠/恢复飞向另一块屏。
    private func currentScreen() -> NSScreen? {
        if let s = panel.screen { return s }
        let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main
    }

    // MARK: - 悬停展开 / 收起（轮询鼠标位置）

    private func startHoverMonitor() {
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHover() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    /// 事件驱动的兜底：定时器轮询在别的 app 前台时可能拿到陈旧的鼠标位置，
    /// 全局/本地 mouseMoved 监听能保证鼠标一移出面板就立刻被发现并收起。
    private func startMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .leftMouseUp,
            .leftMouseDown, .rightMouseDown, .scrollWheel
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.onUserInput(event) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.onUserInput(event) }
        }
    }

    /// 真实用户输入（鼠标移动/点击/滚动）触发。
    /// - 鼠标在面板内：记为「正在操作」，刷新活跃时间，避免被当成空闲而收起。
    /// - 展开状态下，在面板**以外**任何地方按下鼠标：立即收起（点哪都收）。
    private func onUserInput(_ event: NSEvent) {
        if state.mode == .floating {
            let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
            let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown
            // 在面板内按下左键：记下「拖动前的停留位」（卡片背景拖动也走这条），供停靠后恢复飞回
            if event.type == .leftMouseDown, inside {
                dragRestCenterX = panel.frame.midX
                dragRestTopY = panel.frame.maxY
            }
            if !inside, isClick, state.expanded {
                // 当 SwiftUI .alert（清空历史 / 退出确认）等模态/sheet 在前时，alert 窗口
                // 在 panel.frame 之外，点击其按钮会被误判为「点击面板外」而收起。让模态吞掉这次点击。
                guard NSApp.modalWindow == nil && NSApp.keyWindow?.isSheet != true else { return }
                collapse()
                return
            }
            // 久坐提醒中拖完面板松手 → 过 1.5s 继续随机漫游（拖动期间 windowDidMove 已 stopWander）
            if event.type == .leftMouseUp, state.breakMode, state.mode == .floating, wanderTimer == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, self.state.breakMode, self.state.mode == .floating,
                              self.wanderTimer == nil else { return }
                        self.startWander()
                    }
                }
            }
        }
        checkHover()
    }

    private func checkHover() {
        guard state.mode == .floating else {
            if grabPushed { NSCursor.pop(); grabPushed = false }
            return
        }

        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let leftDown = NSEvent.pressedMouseButtons & 0x1 != 0

        // 拖拽时显示"抓手"光标：按住左键且窗口正在移动 → 提示已抓住、可挪动
        updateDragCursor(leftDown: leftDown, frame: frame, mouse: mouse)

        // 拖拽过程中不触发展开/收起
        if leftDown { return }

        if state.expanded {
            // 鼠标在面板上就保持展开；不再以「鼠标停着不动」为由自动收起——
            // 用户可能正在静止地阅读列表/浏览设置，不应该把他甩开。其余收起途径仍生效：
            // 离开面板 0.25s、点击面板外、切到别的 app。
            if frame.insetBy(dx: -6, dy: -6).contains(mouse) {
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) > leaveCollapseDelay { collapse() }
            } else {
                outsideSince = Date()
            }
        } else {
            // 收起时，把手就是窗口顶部那条；稍微放宽命中范围方便触发
            let hot = NSRect(x: frame.minX - 2,
                             y: frame.maxY - collapsedHeight - 3,
                             width: frame.width + 4,
                             height: collapsedHeight + 5)
            if hot.contains(mouse) {
                // 刚手动收起、鼠标还压在把手上时，先不要立刻又弹开
                if suppressExpandUntilExit { return }
                outsideSince = nil
                expand()
            } else {
                // 鼠标已经离开把手，解除抑制，下次悬停可正常展开
                suppressExpandUntilExit = false
            }
        }
    }

    /// 按住左键且窗口正在被拖动时，把光标换成"抓手"，提示已经抓住面板、可以挪动。
    private func updateDragCursor(leftDown: Bool, frame: NSRect, mouse: NSPoint) {
        let origin = frame.origin
        let moved = abs(origin.x - lastPanelOrigin.x) > 0.5 || abs(origin.y - lastPanelOrigin.y) > 0.5
        lastPanelOrigin = origin

        let overPanel = frame.insetBy(dx: -4, dy: -4).contains(mouse)
        let dragging = leftDown && overPanel && (moved || grabPushed)

        if dragging {
            if !grabPushed { NSCursor.closedHand.push(); grabPushed = true }
        } else if grabPushed && !leftDown {
            // 松开左键才复位；拖动途中短暂停顿不复位，避免光标闪烁
            NSCursor.pop()
            grabPushed = false
        }
    }

    private func expand() {
        guard !state.expanded else { return }
        // 久坐提醒进行中：不展开记录列表（让提醒气泡 + 走动一直可见）。机器人飘到光标下也不会误展开。
        guard !state.breakMode else { return }
        suppressExpandUntilExit = false
        state.showSettings = false
        currentExpandedHeight = desiredExpandedHeight()   // 按当前条数/状态算好高度再开
        state.expanded = true
        setPanelFrame(animated: true, expanded: true)
    }

    /// 按目前的「条数 + 是否在设置页 + 是否为空」算出展开时面板应有的总高度。
    /// 内容能多大就开多大，封顶在 expandedHeight；超过上限的，外层 ScrollView 走滚轮。
    private func desiredExpandedHeight() -> CGFloat {
        // 面板「装饰区」高度：机器人区域 + 间隔 + 记录面板的 header + Divider + 网络状态条
        let chrome: CGFloat = collapsedHeight + 4 + 50 + 1 + 30
        let contentH: CGFloat
        if state.showSettings {
            contentH = 360    // 设置面板：条数选择 + 开机自启 + 清空 + 退出 + 内边距
        } else if store.items.isEmpty {
            contentH = 200    // 空状态视图：大号机器人 + 两行文案 + 内边距
        } else {
            // 列表：上下 padding 12+12 = 24，加各行高 + 行间距 8
            var h: CGFloat = 24
            for (i, item) in store.items.enumerated() {
                if i > 0 { h += 8 }
                h += item.kind == .image ? 78 : 54   // 图片缩略图 48 + padding；文本最多 2 行
            }
            contentH = h
        }
        return min(chrome + contentH, expandedHeight)
    }

    /// 条数 / 设置页 / 清空等任何能改变内容高度的变化，都让面板「平滑长 / 缩」到新高度。
    private func recomputePanelHeight() {
        let desired = desiredExpandedHeight()
        guard state.mode == .floating, state.expanded else {
            currentExpandedHeight = desired       // 不在展开状态就只更新缓存，等下次 expand 用
            return
        }
        if abs(currentExpandedHeight - desired) < 2 { return }   // 抖动阈值
        // 缩高时，原本悬停在面板底部的鼠标会"突然在面板外"，下一拍 outsideSince 触发会立刻收起；
        // 在动画开始前重置离开计时，避免面板从光标下被一把抽走。
        if desired < currentExpandedHeight,
           panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
            outsideSince = nil
        }
        currentExpandedHeight = desired
        setPanelFrame(animated: true, expanded: true)
    }

    private func collapse() {
        guard state.expanded else { return }
        outsideSince = nil
        suppressExpandUntilExit = true
        state.showSettings = false
        state.expanded = false
        setPanelFrame(animated: true, expanded: false)
    }

    // MARK: - 切换展开 / 收起（供无障碍 activate 使用；鼠标交互由悬停驱动）

    private func toggleExpand() {
        guard state.mode == .floating else { return }
        if state.expanded { collapse() } else { expand() }
    }

    // MARK: - 拖动移动面板 & 停靠检测（机器人区 + 卡片区都走 isMovableByWindowBackground → windowDidMove）

    func windowDidMove(_ notification: Notification) {
        // 程序性动画（展开/收起/漫游/停靠飞行）也会触发 windowDidMove，靠计数器忽略，
        // 只处理用户真正用手拖动窗口背景的那批移动。
        guard state.mode == .floating, programmaticMoveCounter == 0 else { return }
        // 只有用户真正按住左键拖动时才更新位置 / 判断停靠
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
        // 久坐提醒漫游中被用户抓住拖动 → 停下漫游，免得漫游动画跟拖动抢着改窗口位置而抖动；
        // 松手后由 onUserInput 的 leftMouseUp 过一会儿重启漫游。
        if state.breakMode { stopWander() }
        guard let vf = currentScreen()?.visibleFrame else { return }
        // 拖到菜单栏区域（顶边越过可视区顶部）→ 停靠；恢复时回到拖动前的停留位
        if panel.frame.maxY > vf.maxY + menuBarDockOvershoot {
            desiredCenterX = dragRestCenterX
            desiredTopY = dragRestTopY
            dock()
        } else {
            desiredCenterX = panel.frame.midX
            desiredTopY = panel.frame.maxY
        }
    }

    // MARK: - 停靠到菜单栏

    private func dock() {
        guard state.mode == .floating else { return }   // 已经在菜单栏了就别再来一遍
        guard !dockPending else { return }              // 延迟动画还没跑就别重复入队
        exitBreakMode()                                 // 收进菜单栏 = 这次起身：清掉久坐提醒 + 停走动
        dockPending = true
        state.expanded = false
        state.showSettings = false
        state.mode = .menuBar
        ensureStatusItem()

        // 关键：菜单栏图标刚创建时 button.window.frame 还没布局好（width/height=0），
        // 直接读会拿到 0 → 动画飞向屏幕角落。这里轮询重试，直到读到真实图标位置，
        // 才让面板「飞向那个点」收缩——保证收到菜单栏里图标真正所在的位置。
        runDockAnimation(retriesLeft: 40)   // 最多 ~2s 等图标布局好，确保飞向真实图标点而非角落
    }

    /// 轮询等 status item 的窗口 frame 布局完成，拿到真实图标屏幕位置再播放收缩动画。
    private func runDockAnimation(retriesLeft: Int) {
        // 关键：轮询期间用户若已经把面板拖回悬浮（undock 把 mode 翻回 .floating / 清掉 dockPending），
        // 这条重试链必须立刻作废——否则等会儿会对着「已经恢复的悬浮窗」播放收缩动画把它飞走藏掉。
        guard state.mode == .menuBar, dockPending else { dockPending = false; return }
        if let icon = statusIconScreenRect() {
            lastDockIconRect = icon          // 记下，供 undock 对称飞回 & 下次兜底
            animateDockFlight(to: icon)
        } else if retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.runDockAnimation(retriesLeft: retriesLeft - 1) }
            }
        } else {
            // 实在读不到（极少见）：优先用上次成功拿到的图标位置（比右上角准），再退而求其次到右上角。
            let fallback: NSRect = lastDockIconRect ?? (currentScreen() ?? NSScreen.main).map {
                NSRect(x: $0.frame.maxX - 80, y: $0.frame.maxY - 16, width: 28, height: 8)
            } ?? panel.frame
            animateDockFlight(to: fallback)
        }
    }

    /// 读取菜单栏图标在屏幕上的小矩形；布局未完成时返回 nil 让上层重试。
    private func statusIconScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let win = button.window else { return nil }
        let f = win.frame
        guard f.width > 8, f.height > 8 else { return nil }
        // 用图标自己所在的屏幕判断「是否在顶部」——而非面板所在屏幕，否则多显示器上下错位时会误判。
        let iconScreen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main
        guard let s = iconScreen, f.midY > s.frame.midY else { return nil }
        return NSRect(x: f.midX - 14, y: f.midY - 4, width: 28, height: 8)
    }

    private func animateDockFlight(to targetRect: NSRect) {
        // 已被 undock 抢先：别再起飞（否则会把已恢复的悬浮窗飞走并淡成透明）
        guard state.mode == .menuBar else { dockPending = false; panel.alphaValue = 1.0; return }
        programmaticMoveCounter += 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetRect, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.programmaticMoveCounter -= 1
                self.dockPending = false
                if self.state.mode == .menuBar {
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1.0
                } else {
                    // 动画途中被 undock 接管：别 orderOut，但务必把 alpha 复位，
                    // 否则恢复的悬浮窗会停在透明状态看不见。
                    self.panel.alphaValue = 1.0
                }
            }
        })
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "拾贴")
            button.image?.isTemplate = true
            button.action = #selector(statusAction)
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusAction() {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showStatusMenu()
        case .leftMouseDown:
            trackStatusDrag()
        default:
            toggleMenuBarPopover()
        }
    }

    /// 在菜单栏图标上按下后跟踪鼠标：向下拖动超过阈值 → 脱离菜单栏、变回悬浮窗（"拖下来"）；
    /// 只是普通点击（没有明显下拖）→ 弹出历史列表。
    private func trackStatusDrag() {
        let startY = NSEvent.mouseLocation.y
        var draggedDown = false
        trackLoop: while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                                 until: .distantFuture,
                                                 inMode: .eventTracking,
                                                 dequeue: true) {
            switch e.type {
            case .leftMouseUp:
                break trackLoop
            case .leftMouseDragged:
                if startY - NSEvent.mouseLocation.y > 12 {
                    draggedDown = true
                    break trackLoop
                }
            default:
                break
            }
        }
        statusItem?.button?.isHighlighted = false
        if draggedDown {
            undock()
        } else {
            toggleMenuBarPopover()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let restore = NSMenuItem(title: "恢复悬浮窗口", action: #selector(undock), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出拾贴", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 6),
                   in: button)
    }

    private func toggleMenuBarPopover() {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self                       // 收到 popoverDidClose 后把自己 hide 回 accessory 状态
        pop.contentSize = NSSize(width: panelWidth, height: expandedHeight)
        let content = MenuBarContentView(store: store, state: state)
            .frame(width: panelWidth, height: expandedHeight)
        pop.contentViewController = NSHostingController(rootView: content)
        // LSUIElement(accessory) app 下 NSPopover.transient 默认不会在点击外部时消失——
        // 系统依赖「正常 active app」语义来判定外部点击。短暂把自己激活，让 .transient
        // 按预期工作；用户点击别的窗口/桌面时 popover 会自动收起。
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
    }

    /// LSUIElement app 在 `NSApp.activate` 后会一直「保持激活」直到显式 hide——
    /// popover 关闭后立即把自己 hide 回去，光标焦点交还给前一个 app。
    /// 但如果是 undock 流程顺手关掉 popover（此时 mode 已切回 floating），不要 hide：
    /// 悬浮窗即将出现，hide 会把它一起藏掉。
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        guard state.mode == .menuBar else { return }
        NSApp.hide(nil)
    }

    // MARK: - 恢复为悬浮窗口

    @objc private func undock() {
        // 抢先作废任何还在轮询 / 待播放的停靠动画：mode 即将变回 .floating，
        // dockPending 清零后，残留的 runDockAnimation 重试链会在自己的 guard 处自动退出。
        dockPending = false
        // 动画「起点」优先用停靠时记录的图标位置，保证「从哪儿收上去、就从哪儿放下来」；
        // 没有记录时再实时读图标，最后兜底屏幕右上角。
        let screen = currentScreen()
        let startRect: NSRect = lastDockIconRect ?? {
            if let bf = statusItem?.button?.window?.frame,
               bf.width > 8, bf.height > 8,
               let s = NSScreen.screens.first(where: { $0.frame.intersects(bf) }) ?? screen,
               bf.midY > s.frame.midY {
                return NSRect(x: bf.midX - 14, y: bf.midY - 4, width: 28, height: 8)
            }
            if let s = screen {
                return NSRect(x: s.frame.maxX - 80, y: s.frame.maxY - 16, width: 28, height: 8)
            }
            return panel.frame
        }()

        popover?.performClose(nil)
        popover = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        state.mode = .floating
        state.expanded = false
        state.showSettings = false
        workStartTime = Date()   // 从菜单栏恢复 = 新一段连续工作开始，避免恢复后立刻又被久坐提醒

        // 关键：不要重置 desiredCenterX/Y，保留用户最后一次把面板放下的桌面位置——
        // 拖到哪里收上去的，恢复时就回到那里。仅当从未设置过才兜底到屏幕顶部中央。
        if desiredCenterX == 0 && desiredTopY == 0, let vf = screen?.visibleFrame {
            desiredCenterX = vf.midX
            desiredTopY = vf.maxY
        }
        let cw = collapsedPanelWidth, ch = collapsedPanelHeight
        var endRect = NSRect(
            x: desiredCenterX - cw / 2,
            y: desiredTopY - ch,
            width: cw,
            height: ch
        )
        // 若 desiredCenter/Top 是从一台已断开/已换的显示器残留下来的，落点可能与所有屏幕都不相交。
        // 此时退回当前主屏中央顶端；并把 X 钳到当前屏可视区内，避免菜单栏被覆盖或漂出屏幕外。
        let landingScreens = NSScreen.screens
        if !landingScreens.contains(where: { $0.visibleFrame.intersects(endRect) }) {
            if let s = NSScreen.main {
                desiredCenterX = s.visibleFrame.midX
                desiredTopY = s.visibleFrame.maxY
                endRect = NSRect(
                    x: desiredCenterX - cw / 2,
                    y: desiredTopY - ch,
                    width: cw,
                    height: ch
                )
            }
        }
        if let s = landingScreens.first(where: { $0.visibleFrame.intersects(endRect) }) ?? NSScreen.main {
            let vf = s.visibleFrame
            if endRect.minX < vf.minX { endRect.origin.x = vf.minX }
            if endRect.maxX > vf.maxX { endRect.origin.x = vf.maxX - endRect.width }
            if endRect.maxY > vf.maxY { endRect.origin.y = vf.maxY - endRect.height }
        }

        // 从菜单栏图标位置「飞出来」到正中央折叠位置；fade in。
        programmaticMoveCounter += 1
        suppressExpandUntilExit = true   // 动画进行中别因为鼠标偶然飘到落点而自动展开
        panel.alphaValue = 0
        panel.setFrame(startRect, display: true)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(endRect, display: true)
            panel.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticMoveCounter -= 1 }
        })
    }

    // MARK: - 久坐提醒（机器人随机走动 + 气泡提示）

    private func startBreakMonitor() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWorkDuration() }
        }
        RunLoop.main.add(t, forMode: .common)
        breakCheckTimer = t
    }

    private func checkWorkDuration() {
        guard !state.breakMode else { return }
        // 只在悬浮模式提醒（停靠到菜单栏时面板不可见，无意义）
        guard state.mode == .floating else { return }
        if Date().timeIntervalSince(workStartTime) >= workThreshold {
            enterBreakMode()
        }
    }

    private func enterBreakMode() {
        state.workedMinutes = Int(Date().timeIntervalSince(workStartTime) / 60)
        // 先收起记录列表，让机器人 + 提醒气泡露出来
        state.showSettings = false
        state.expanded = false
        state.breakMode = true               // 触发 $breakMode 订阅 → 折叠面板收成含气泡+按钮的尺寸
        // 等「收成提醒气泡尺寸」的动画基本结束，再开始第一步漫游——避免收起动画与漫游动画打架。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.state.breakMode, self.state.mode == .floating else { return }
                self.startWander()
            }
        }
    }

    /// 统一收尾久坐提醒：停走动、清状态、把「连续工作」计时归零（视作一次起身）。
    private func exitBreakMode() {
        guard state.breakMode else { return }
        stopWander()
        state.breakMode = false
        workStartTime = Date()
    }

    /// 用户点「我起来走过了」：退出提醒、重置计时、停止走动、回到顶部中央。
    private func confirmBreak() {
        exitBreakMode()
        // 回到当前屏顶部中央，结束随机漫游
        if let vf = currentScreen()?.visibleFrame {
            desiredCenterX = vf.midX
            desiredTopY = vf.maxY
        }
        setPanelFrame(animated: true, expanded: false)
    }

    private func startWander() {
        stopWander()
        wanderStep()   // 立刻挪一次
        let t = Timer(timeInterval: 6.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.wanderStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        wanderTimer = t
    }

    private func stopWander() {
        wanderTimer?.invalidate()
        wanderTimer = nil
    }

    /// 缓慢飘到屏幕可视区内一个随机位置（保持完全在屏内）。
    private func wanderStep() {
        guard state.breakMode, state.mode == .floating,
              let vf = currentScreen()?.visibleFrame else { return }
        // 鼠标正凑近面板（八成是想点「我走过了」）→ 这一拍先别动，免得按钮跑掉
        if panel.frame.insetBy(dx: -50, dy: -50).contains(NSEvent.mouseLocation) { return }
        let w = collapsedPanelWidth, h = collapsedPanelHeight
        let minCx = vf.minX + w / 2, maxCx = vf.maxX - w / 2
        let minTop = vf.minY + h, maxTop = vf.maxY
        guard maxCx > minCx, maxTop > minTop else { return }
        desiredCenterX = CGFloat.random(in: minCx...maxCx)
        desiredTopY = CGFloat.random(in: minTop...maxTop)
        let target = NSRect(x: desiredCenterX - w / 2, y: desiredTopY - h, width: w, height: h)
        programmaticMoveCounter += 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 3.4                       // 慢慢飘过去
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticMoveCounter -= 1 }
        })
    }

    /// 菜单栏 "退出拾贴" 走的入口：先弹原生确认弹窗，再走带动画的真退出。
    @objc private func quitFromMenu() {
        let alert = NSAlert()
        alert.messageText = "确认退出拾贴？"
        alert.informativeText = "退出后不会再记录新的剪贴板内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { quitApp() }
    }

    /// 退出软件：若悬浮窗可见，先做一个「缩到中心 + 淡出」的小动画，再 terminate。
    /// 菜单栏模式下面板不可见，直接退出即可。
    private func quitApp() {
        // 重入保护：菜单栏「退出」与设置面板「退出」快速连点不会叠加两段动画 / 两次 terminate。
        guard !isQuitting else { return }
        isQuitting = true
        guard state.mode == .floating, panel.isVisible else {
            NSApp.terminate(nil)
            return
        }
        panel.isMovableByWindowBackground = false
        programmaticMoveCounter += 1
        let f = panel.frame
        let target = NSRect(x: f.midX - 18, y: f.midY - 9, width: 36, height: 18)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        })
    }
}
