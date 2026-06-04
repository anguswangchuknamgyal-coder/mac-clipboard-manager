import Cocoa

// 用法:
//   swift verify.swift                自动跑完整展开/收起序列，逐步打印高度并给 PASS/FAIL
//   swift verify.swift list           仅列出 ClipDrawer 窗口及尺寸
//   swift verify.swift expand         鼠标移到顶部把手区，再读尺寸
//   swift verify.swift away           鼠标移到屏幕中央，再读尺寸

func screenInfo() -> (width: CGFloat, fullHeight: CGFloat, menuBarHeight: CGFloat) {
    let s = NSScreen.main!
    let menuBar = s.frame.height - s.visibleFrame.maxY
    return (s.frame.width, s.frame.height, menuBar)
}

func warp(toCG x: CGFloat, _ y: CGFloat) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
}

// 单次 CGWarp 偶尔不会立刻被轮询捕获（不像真实鼠标会持续产生事件）。
// 抖动几下，制造连续的位置变化，确保 app 的 0.08s 悬停轮询能稳定命中。
func warpSettle(toCG x: CGFloat, _ y: CGFloat) {
    for dx in [CGFloat(0), 2, -2, 1, 0] {
        warp(toCG: x + dx, y)
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// 在 CG 顶左坐标处合成一次真实左键单击（用于测试「点击面板外即收起」）。
// 注意：CGEvent.post 合成点击可能需要「辅助功能/输入监控」权限，无权限时事件不会送达。
func clickCG(toCG x: CGFloat, _ y: CGFloat) {
    let pt = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

// 读取 ClipDrawer 窗口的尺寸（找不到返回 nil）
func clipSize() -> (w: CGFloat, h: CGFloat)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list {
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner.contains("ClipDrawer") || owner.contains("剪贴板") || owner.contains("拾贴") else { continue }
        let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (b["Width"] ?? -1, b["Height"] ?? -1)
    }
    return nil
}

// 读取 ClipDrawer 窗口的完整 frame（CG 顶左坐标；找不到返回 nil）
func clipFrame() -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list {
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner.contains("ClipDrawer") || owner.contains("剪贴板") || owner.contains("拾贴") else { continue }
        let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return (b["X"] ?? -1, b["Y"] ?? -1, b["Width"] ?? -1, b["Height"] ?? -1)
    }
    return nil
}

// 在机器人上合成一次「按下 → 往下拖 → 松手」，测试拖动是否真的挪动了窗口。
// 注意：合成拖动需「辅助功能」权限，无权限时事件不会送达 → 窗口不动（属环境问题，非代码 bug）。
func dragCG(fromCG x: CGFloat, _ y: CGFloat, dx: CGFloat, dy: CGFloat, steps: Int = 12) {
    let src = CGEventSource(stateID: .hidSystemState)
    let start = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: x + dx * t, y: y + dy * t)
        let e = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
        e?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
    }
    let end = CGPoint(x: x + dx, y: y + dy)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
}

func clipHeight() -> CGFloat? { clipSize()?.h }

func printClipWindows() {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var found = 0
    for info in list {
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        guard owner.contains("ClipDrawer") || owner.contains("剪贴板") || owner.contains("拾贴") else { continue }
        let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let w = b["Width"] ?? 0, h = b["Height"] ?? 0, x = b["X"] ?? 0, y = b["Y"] ?? 0
        print("MATCH owner=\(owner) layer=\(layer) frame=(x:\(x), y:\(y), w:\(w), h:\(h))")
        found += 1
    }
    if found == 0 {
        print("NO ClipDrawer window found. 全部窗口 owner 列表:")
        var owners = Set<String>()
        for info in list { owners.insert(info[kCGWindowOwnerName as String] as? String ?? "?") }
        print(owners.sorted().joined(separator: ", "))
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cycle"
let (w, fullH, menu) = screenInfo()
print("screen width=\(w) fullHeight=\(fullH) menuBarHeight=\(menu) mouseNow(bl)=\(NSEvent.mouseLocation)")

// 把手中央（CG 顶左坐标）
let handleX = w / 2
let handleY = menu + 10

switch mode {
case "expand":
    warp(toCG: handleX, handleY)
    Thread.sleep(forTimeInterval: 0.8)
    printClipWindows()

case "away":
    warp(toCG: w / 2, fullH / 2)
    Thread.sleep(forTimeInterval: 1.0)
    printClipWindows()

case "activate":
    // 展开 → 用 osascript 激活 Finder（等同于用户点击别的 app）→ 应立即收起
    warpSettle(toCG: handleX, handleY)
    Thread.sleep(forTimeInterval: 0.8)
    let before = clipHeight() ?? -1
    print("展开后 h=\(before)\(before > 200 ? " (已展开)" : " ⚠️未展开，后续无意义")")
    let proc = Process()
    proc.launchPath = "/usr/bin/osascript"
    proc.arguments = ["-e", "tell application \"Finder\" to activate"]
    try? proc.run()
    proc.waitUntilExit()
    var aSamples: [CGFloat] = []
    for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.1); aSamples.append(clipHeight() ?? -1) }
    let aAfter = aSamples.last ?? -1
    let aOK = before > 200 && aAfter <= 200
    print("激活 Finder 后 h 轨迹=[\(aSamples.map { String(format: "%.0f", $0) }.joined(separator: ","))]")
    print(aOK ? "PASS ✅ 切到别的 app → 已收起" : "FAIL ❌ 切到别的 app → 未收起")

case "clickout":
    // 展开 → 在屏幕中央（面板外）合成一次真实单击 → 应立即收起
    warpSettle(toCG: handleX, handleY)
    Thread.sleep(forTimeInterval: 0.8)
    let before = clipHeight() ?? -1
    print("展开后 h=\(before)\(before > 200 ? " (已展开)" : " ⚠️未展开，后续无意义")")
    clickCG(toCG: w / 2, fullH / 2)        // 面板外（屏幕正中）单击
    var samples: [CGFloat] = []
    for _ in 0..<8 { Thread.sleep(forTimeInterval: 0.1); samples.append(clipHeight() ?? -1) }
    let after = samples.last ?? -1
    let ok = before > 200 && after <= 200
    print("点击面板外后 h 轨迹=[\(samples.map { String(format: "%.0f", $0) }.joined(separator: ","))]")
    print(ok ? "PASS ✅ 点击外部已收起" : "FAIL ❌ 点击外部未收起（或合成点击无权限未送达）")

case "clickrobot":
    // 直接在机器人当前位置合成一次单击，验证「合成事件能否送达 + mouseDown→onClick 是否展开」。
    warpSettle(toCG: w / 2, fullH / 2)
    Thread.sleep(forTimeInterval: 0.5)
    guard let f0 = clipFrame() else { print("FAIL ❌ 找不到窗口"); break }
    print("点击前 frame=(x:\(f0.x), y:\(f0.y), w:\(f0.w), h:\(f0.h))")
    let rx = f0.x + f0.w / 2, ry = f0.y + 40
    print("在机器人中心合成单击 @CG(\(Int(rx)),\(Int(ry)))")
    clickCG(toCG: rx, ry)
    var hs: [CGFloat] = []
    for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.12); hs.append(clipHeight() ?? -1) }
    let expanded = hs.contains { $0 > 200 }
    print("点击后 h 轨迹=[\(hs.map { String(format: "%.0f", $0) }.joined(separator: ","))]")
    print(expanded ? "PASS ✅ 合成单击送达且 mouseDown→展开生效（→ 若拖动仍不动，是拖动循环的问题）"
                   : "FAIL ❌ 点击无反应（合成事件未送达 / mouseDown 未触发）")

case "drag":
    // 在机器人上按住往下拖 ~180px，验证折叠面板被真正挪动（拖动功能）。
    warpSettle(toCG: w / 2, fullH / 2)        // 先把鼠标移开，保证是折叠态
    Thread.sleep(forTimeInterval: 0.6)
    guard let before = clipFrame() else { print("FAIL ❌ 找不到 ClipDrawer 窗口"); break }
    print("拖动前 frame=(x:\(before.x), y:\(before.y), w:\(before.w), h:\(before.h))")
    // 机器人在折叠面板顶部 80pt 区域中央
    let robotX = before.x + before.w / 2
    let robotY = before.y + 40
    dragCG(fromCG: robotX, robotY, dx: 0, dy: 180)
    Thread.sleep(forTimeInterval: 0.4)
    guard let after = clipFrame() else { print("FAIL ❌ 拖动后找不到窗口"); break }
    print("拖动后 frame=(x:\(after.x), y:\(after.y), w:\(after.w), h:\(after.h))")
    let movedY = after.y - before.y
    print("纵向位移 = \(String(format: "%.0f", movedY)) px（期望 ≈180）")
    let ok = movedY > 100
    print(ok ? "PASS ✅ 机器人可拖动移动窗口"
             : "FAIL ❌ 窗口没动（拖动失效，或合成拖动无辅助功能权限未送达）")

case "list":
    printClipWindows()

default: // "cycle" 完整自动序列
    var fails = 0
    // 展开/收起都是「持续悬停」行为，单次快照可能正好卡在触发前的空档。
    // 因此在 ~1.2s 内多次采样，把每个样本都打出来（不藏 stuck 状态）：
    //   - 期望展开：只要悬停期间任一刻到了 >200 就算 PASS（之后会保持）
    //   - 期望收起：要求最终稳定到 <200
    func step(_ name: String, warpX: CGFloat, warpY: CGFloat, expectExpanded: Bool) {
        warpSettle(toCG: warpX, warpY)
        var samples: [(w: CGFloat, h: CGFloat)] = []
        for _ in 0..<12 {                       // 12 × 0.1s = 1.2s
            Thread.sleep(forTimeInterval: 0.1)
            samples.append(clipSize() ?? (-1, -1))
        }
        let everExpanded = samples.contains { $0.h > 200 }   // 200 作展开/收起分界
        let everWide = samples.contains { $0.w > 300 }       // 展开宽≈400，折叠宽≈140
        let final = samples.last ?? (-1, -1)
        // 期望展开：悬停期间确实变到过「全尺寸」(高>200 且 宽>300) 即算成功；
        //          （真机上偶有外部鼠标抖动把光标带离把手而自动收起，属正确行为，不算失败）
        // 期望收起：必须最终稳定到「小尺寸」(高≤200 且 宽<200)
        let ok = expectExpanded
            ? (everExpanded && everWide)
            : (final.h <= 200 && final.w < 200)
        if !ok { fails += 1 }
        let trace = samples.map { String(format: "%.0f", $0.h) }.joined(separator: ",")
        print(String(format: "%@  finalW=%.0f finalH=%.0f  everExpanded=%@  expect=%@  -> %@   h[%@]",
                     name, final.w, final.h,
                     everExpanded ? "YES" : "no",
                     expectExpanded ? "YES" : "no",
                     ok ? "PASS" : "FAIL", trace))
    }

    print("=== 初始状态 ===")
    print("start height=\(clipHeight().map { String(format: "%.0f", $0) } ?? "n/a")")

    print("=== 三轮: 顶部悬停展开 → 不同方向移开收起 ===")
    // 第一轮：移到「屏幕下边附近」(原本是 fullH/2，但屏幕只有 1117 高时，展开面板的底部
    // 已经覆盖到 NS y≈524，CG y≈558 的中点恰好落在面板内部 → 不会收起。这里改成更靠下的点
    // 以确保在任意常见分辨率下都落在面板外。)
    step("1a hover-top  -> expand", warpX: handleX, warpY: handleY, expectExpanded: true)
    step("1b far-below  -> collapse", warpX: w / 2, warpY: fullH - 60, expectExpanded: false)
    // 第二轮：移到面板右侧外（贴着面板右边一点点，模拟随手挪开）
    step("2a hover-top  -> expand", warpX: handleX, warpY: handleY, expectExpanded: true)
    step("2b just-right -> collapse", warpX: handleX + 260, warpY: menu + 120, expectExpanded: false)
    // 第三轮：移到面板正下方外（展开高约 560，往下越过它一点）
    step("3a hover-top  -> expand", warpX: handleX, warpY: handleY, expectExpanded: true)
    step("3b just-below -> collapse", warpX: handleX, warpY: menu + 700, expectExpanded: false)

    // 第四轮：展开后把鼠标停在「面板内部」且不再移动 → 应「保持展开」（不再有空闲自动收起）。
    // 历史上这里测的是「2s 后自动收起」，现已移除——用户阅读列表/设置时不再被强行打断。
    print("=== 第四轮: 展开后鼠标停在面板内不动 → 应保持展开 ===")
    warpSettle(toCG: handleX, handleY)            // 先悬停顶部展开
    Thread.sleep(forTimeInterval: 0.6)
    warpSettle(toCG: handleX, menu + 220)         // 移到面板内部（展开高~560，220 在面板内）
    // 停住不动，采样 ~3.4s：所有采样都应是展开状态
    var idle: [(w: CGFloat, h: CGFloat)] = []
    for _ in 0..<34 { Thread.sleep(forTimeInterval: 0.1); idle.append(clipSize() ?? (-1, -1)) }
    let collapsedSample = idle.first { $0.h <= 200 || $0.w < 200 }
    let finalIdle = idle.last ?? (-1, -1)
    let idleOK = collapsedSample == nil && finalIdle.h > 200 && finalIdle.w > 200
    if !idleOK { fails += 1 }
    let idleTrace = idle.map { String(format: "%.0f", $0.h) }.joined(separator: ",")
    print(String(format: "4 idle-on-panel -> stays expanded  finalH=%.0f finalW=%.0f -> %@   h[%@]",
                 finalIdle.h, finalIdle.w,
                 idleOK ? "PASS" : "FAIL", idleTrace))

    print("=== 结果 ===")
    print(fails == 0 ? "ALL PASS ✅" : "FAILED ❌ (\(fails) 步未通过)")
    printClipWindows()
}
