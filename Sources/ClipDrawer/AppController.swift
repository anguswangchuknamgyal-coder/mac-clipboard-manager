import AppKit
import SwiftUI
import Combine

enum PanelMode {
    case floating   // 悬浮可拖拽面板
    case menuBar    // 已停靠到菜单栏
}

@MainActor
final class DrawerState: ObservableObject {
    @Published var mode: PanelMode = .floating
    /// 悬浮模式下是否展开（铺下来）
    @Published var expanded: Bool = false
    /// 是否显示设置面板
    @Published var showSettings: Bool = false
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = HistoryStore()
    lazy var monitor = ClipboardMonitor(store: store)
    let state = DrawerState()

    private var panel: NSPanel!
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // 拖拽时记录的目标位置（顶边 Y 与中心 X，按中心锚定，展开/折叠宽度不同也居中对齐）
    private var desiredCenterX: CGFloat = 0
    private var desiredTopY: CGFloat = 0
    private var isProgrammaticMove = false

    // 悬停检测（基于鼠标实际位置，避免窗口缩放打断的跟踪丢失）
    private var hoverTimer: Timer?
    private var outsideSince: Date?
    // 最近一次「用户真在操作面板」的时间（鼠标在面板内移动/点击/滚动）。
    // 鼠标停在面板上但长时间无操作，就视为「不再操作软件」，自动收起。
    private var lastPanelActivity = Date()
    // 鼠标移出面板后多久收起
    private let leaveCollapseDelay: TimeInterval = 0.25
    // 鼠标停在面板上但无任何操作多久后收起
    private let idleCollapseDelay: TimeInterval = 2.0
    // 手动收起后，鼠标仍停在顶部把手上时，先别立刻重新展开；等鼠标离开一次再说
    private var suppressExpandUntilExit = false
    // 即使别的 app 在前台，也能实时拿到鼠标移动；定时器轮询可能拿到陈旧位置
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    // 拖拽时显示"抓手"光标
    private var grabPushed = false
    private var lastPanelOrigin: CGPoint = .zero

    // 尺寸常量
    private let panelWidth: CGFloat = 400        // 展开宽度
    private let collapsedWidth: CGFloat = 140     // 折叠宽度（约展开的 1/3）
    private let collapsedHeight: CGFloat = 26
    private let expandedHeight: CGFloat = 560

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.onUndock = { [weak self] in self?.undock() }
        state.onCollapse = { [weak self] in self?.collapse() }
        state.onExpand = { [weak self] in self?.expand() }
        state.onDock = { [weak self] in self?.dock() }
        state.onQuit = { [weak self] in self?.quitApp() }

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
           app.bundleIdentifier == Bundle.main.bundleIdentifier { return }   // 是我们自己被激活，忽略
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
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true   // 可拖拽
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        // 用 NSVisualEffectView 做真正会模糊背景、随明暗自适应的玻璃底
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let root = DrawerView(store: store, state: state)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        panel.contentView = effect
        self.panel = panel
    }

    private func setPanelFrame(animated: Bool, expanded: Bool) {
        let h = expanded ? expandedHeight : collapsedHeight
        let w = expanded ? panelWidth : collapsedWidth
        let frame = NSRect(x: desiredCenterX - w / 2, y: desiredTopY - h, width: w, height: h)
        isProgrammaticMove = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.isProgrammaticMove = false }
            })
        } else {
            panel.setFrame(frame, display: true)
            isProgrammaticMove = false
        }
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
            if inside {
                lastPanelActivity = Date()
            } else if isClick && state.expanded {
                collapse()
                return
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
            if frame.insetBy(dx: -6, dy: -6).contains(mouse) {
                outsideSince = nil
                // 鼠标虽在面板上，但长时间没有任何操作 → 视为「不再操作软件」，自动收起
                if Date().timeIntervalSince(lastPanelActivity) > idleCollapseDelay {
                    collapse()
                }
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
        suppressExpandUntilExit = false
        lastPanelActivity = Date()   // 刚展开，重置空闲计时，别立刻又收起
        state.showSettings = false
        state.expanded = true
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

    // MARK: - 拖拽 & 停靠检测

    func windowDidMove(_ notification: Notification) {
        guard state.mode == .floating, !isProgrammaticMove else { return }
        // 只有用户真正按住左键拖动时才更新位置/判断停靠；
        // 展开/折叠等程序性动画也会触发 windowDidMove，必须忽略，否则会把
        // 动画中途的瞬时帧当成"目标位置"导致面板漂移、甚至被误判为拖到顶而停靠。
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        desiredCenterX = panel.frame.midX
        desiredTopY = panel.frame.maxY
        // 拖到菜单栏区域（顶边越过可视区顶部）→ 停靠
        if panel.frame.maxY > vf.maxY + 6 {
            dock()
        }
    }

    // MARK: - 停靠到菜单栏

    private func dock() {
        guard state.mode == .floating else { return }   // 已经在菜单栏了就别再来一遍
        state.expanded = false
        state.showSettings = false
        state.mode = .menuBar
        ensureStatusItem()

        // 刚创建的 status item，其 button.window.frame 常常还是 (0,0,0,0)——菜单栏布局还没完成。
        // 立刻读会把动画飞向屏幕原点（Cocoa 的左下角）。等一个 runloop tick 再读就稳了。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.runDockAnimation() }
        }
    }

    private func runDockAnimation() {
        let screen = panel.screen ?? NSScreen.main
        let targetRect: NSRect = {
            if let bf = statusItem?.button?.window?.frame,
               bf.width > 8, bf.height > 8,
               let s = screen, bf.midY > s.frame.midY {       // 必须落在屏幕「上半部」(菜单栏在顶部)
                return NSRect(x: bf.midX - 14, y: bf.midY - 4, width: 28, height: 8)
            }
            if let s = screen {                                // 兜底：屏幕右上角（菜单栏右侧）
                return NSRect(x: s.frame.maxX - 80, y: s.frame.maxY - 16, width: 28, height: 8)
            }
            return panel.frame
        }()

        // 拖拽过程触发的 dock：把 isMovableByWindowBackground 暂时关掉，避免拖拽位置
        // 持续覆盖动画设置的 frame
        panel.isMovableByWindowBackground = false
        isProgrammaticMove = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetRect, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1.0
                self.panel.isMovableByWindowBackground = true
                self.isProgrammaticMove = false
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

    // MARK: - 恢复为悬浮窗口

    @objc private func undock() {
        // 取菜单栏图标位置作为动画「起点」——必须在 removeStatusItem 之前读到
        let screen = panel.screen ?? NSScreen.main
        let startRect: NSRect = {
            if let bf = statusItem?.button?.window?.frame,
               bf.width > 8, bf.height > 8,
               let s = screen, bf.midY > s.frame.midY {
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

        // 关键：不要重置 desiredCenterX/Y，保留用户最后一次把面板放下的桌面位置——
        // 拖到哪里收上去的，恢复时就回到那里。仅当从未设置过才兜底到屏幕顶部中央。
        if desiredCenterX == 0 && desiredTopY == 0, let vf = screen?.visibleFrame {
            desiredCenterX = vf.midX
            desiredTopY = vf.maxY
        }
        let endRect = NSRect(
            x: desiredCenterX - collapsedWidth / 2,
            y: desiredTopY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )

        // 从菜单栏图标位置「飞出来」到正中央折叠位置；fade in。
        isProgrammaticMove = true
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
            MainActor.assumeIsolated { self?.isProgrammaticMove = false }
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
        guard state.mode == .floating, panel.isVisible else {
            NSApp.terminate(nil)
            return
        }
        panel.isMovableByWindowBackground = false
        isProgrammaticMove = true
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
