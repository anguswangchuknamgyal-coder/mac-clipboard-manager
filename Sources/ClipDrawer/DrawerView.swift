import SwiftUI

// MARK: - 悬浮抽屉（单块玻璃，悬停整体展开）

struct DrawerView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var state: DrawerState

    // 每次展开都让小机器人开心地跳一下：值变化 → PixelRobot 内部触发 hop 动画
    @State private var bopTrigger: Int = 0

    // 顶部「机器人区」高度，要与 AppController.collapsedHeight 保持一致
    private let robotAreaHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 4) {
            ClaudeHandle(state: state, bopTrigger: bopTrigger)
                .frame(height: robotAreaHeight)
            if state.expanded {
                // 玻璃记录卡片：用更厚的材质 + 细描边，桌面再花哨也能清楚看见卡片轮廓和文字。
                // 入场动画：从上方向下滑入 + 淡入（窗帘式揭开）；退场只做淡出。
                ScrollView(.vertical, showsIndicators: true) {
                    RecordsPanel(store: store, state: state)
                }
                .background(
                    .thickMaterial,        // 最厚的磨砂玻璃，无论桌面多花，下方记录文字都能看清
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    // 1px 细描边：让卡片在低对比度桌面（如全黑壁纸）也能看出边界
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.30), radius: 12, y: 5)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -10)),
                    removal: .opacity
                ))
            } else {
                // 折叠态：机器人下方挂一个「说话气泡」，平时显示 Claude 连接状态，
                // 久坐提醒时显示「起来走走」+ 确认按钮。
                SpeechBubble(state: state)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(Color(red: 0.95, green: 0.50, blue: 0.30))           // 整体强调色：珊瑚橙
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: state.expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.breakMode)
        .onChange(of: state.expanded) { _, opened in
            if opened { bopTrigger += 1 }
        }
    }
}

// MARK: - 机器人下方「说话气泡」
// 平时：显示 Claude 连接状态文字（拟人化提示）。久坐提醒：显示起来活动的提示 + 确认按钮。
private struct SpeechBubble: View {
    @ObservedObject var state: DrawerState

    var body: some View {
        VStack(spacing: 7) {
            Text(state.bubbleText)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if state.breakMode {
                Button {
                    state.onBreakConfirm?()
                } label: {
                    Text("我起来走过了 ✓")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // 气泡顶部带一个小尖角指向上方的机器人，像它在说话
        .background(SpeechBubbleShape().fill(.regularMaterial))
        .overlay(
            SpeechBubbleShape().stroke(
                state.breakMode ? Color.orange.opacity(0.45) : Color.primary.opacity(0.12),
                lineWidth: state.breakMode ? 1 : 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
    }
}

// 圆角矩形 + 顶部居中小尖角的「说话框」形状
private struct SpeechBubbleShape: Shape {
    let tailWidth: CGFloat = 13
    let tailHeight: CGFloat = 6
    let radius: CGFloat = 11
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let bodyTop = rect.minY + tailHeight
        let body = CGRect(x: rect.minX, y: bodyTop, width: rect.width, height: rect.height - tailHeight)
        p.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius))
        let cx = rect.midX
        p.move(to: CGPoint(x: cx - tailWidth / 2, y: bodyTop + 0.5))
        p.addLine(to: CGPoint(x: cx, y: rect.minY))
        p.addLine(to: CGPoint(x: cx + tailWidth / 2, y: bodyTop + 0.5))
        p.closeSubpath()
        return p
    }
}

// MARK: - 像素小机器人「拾贴」（完整版）
// 顶上两根天线 / 耳朵；珊瑚色八角形大脑袋；两只黑方眼 + 一条像素嘴；
// 八角形小身子 + 左右两只小手臂；两对像素小脚（4 只）。
// 静止时缓慢呼吸 + 随机眨眼；hover 时站起来一点 + 放大；被点击展开时开心跳一下；
// 处于「活动」状态（hover 或面板已展开）时两对脚轮流抬起，像在原地小走。
private struct PixelRobot: View {
    let size: CGFloat                  // 整体高度（含天线 + 头 + 身 + 腿）
    var walking: Bool = false
    var bopTrigger: Int = 0
    var mood: ClaudeMood = .neutral    // 网络心情：开心 / 平常 / 难过

    @State private var blinkPhase: CGFloat = 1.0
    @State private var legPhase: Int = 0
    @State private var hopOffset: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath: CGFloat = 1.0 + CGFloat(sin(t * 1.05)) * 0.025   // ±2.5%
            character
                .scaleEffect(y: breath, anchor: .bottom)
        }
        .offset(y: hopOffset)
        .task { await blinkLoop() }
        .task { await walkLoop() }
        .onChange(of: bopTrigger) { _, _ in happyHop() }
    }

    @ViewBuilder
    private var character: some View {
        VStack(spacing: 0) {
            antennas
                .frame(height: size * 0.08)
            head
                .frame(width: size * 0.78, height: size * 0.40)
            torso
                .frame(height: size * 0.22)
                .offset(y: -size * 0.020)
            legs
                .frame(height: size * 0.20)
                .offset(y: -size * 0.040)
        }
    }

    // 天线 / 耳朵：两根小黑方块直立在头顶两侧
    private var antennas: some View {
        HStack(spacing: size * 0.30) {
            Rectangle()
                .fill(dark)
                .frame(width: size * 0.07, height: size * 0.08)
            Rectangle()
                .fill(dark)
                .frame(width: size * 0.07, height: size * 0.08)
        }
    }

    // 头：八角形珊瑚 + 两只方眼 + 随心情变化的嘴；难过时还会掉眼泪
    private var head: some View {
        ZStack {
            ChamferRect(chamfer: size * 0.055)
                .fill(coral)
                .frame(width: size * 0.78, height: size * 0.40)
            // 眼睛：稍稍偏上
            HStack(spacing: size * 0.16) {
                eye
                eye
            }
            .offset(y: -size * 0.035)
            // 嘴：开心上扬(∪) / 平常平直 / 难过下撇(∩)
            MouthShape(curve: mouthCurve)
                .stroke(dark.opacity(0.85),
                        style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                .frame(width: size * 0.18, height: size * 0.10)
                .offset(y: size * 0.10)
                .animation(.easeInOut(duration: 0.4), value: mood)
            // 难过时：两滴眼泪从眼睛下方往下掉（左右错开节奏，更自然）
            if mood == .sad {
                HStack(spacing: size * 0.16) {
                    Teardrop(size: size, delay: 0)
                    Teardrop(size: size, delay: 0.45)
                }
                .offset(y: size * 0.02)
            }
        }
    }

    /// 嘴的弯曲量：>0 控制点在下方 → 笑(∪)；0 平直；<0 控制点在上方 → 哭(∩)
    private var mouthCurve: CGFloat {
        switch mood {
        case .happy: return size * 0.05
        case .neutral: return 0
        case .sad: return -size * 0.05
        }
    }

    private var eye: some View {
        Rectangle()
            .fill(dark)
            .frame(width: size * 0.10, height: size * 0.135 * blinkPhase)
            .animation(.easeInOut(duration: 0.10), value: blinkPhase)
    }

    // 身子 + 两只手臂：八角形小身体居中，黑色方块小手臂从两侧探出
    private var torso: some View {
        HStack(alignment: .center, spacing: size * 0.020) {
            Rectangle()
                .fill(dark)
                .frame(width: size * 0.055, height: size * 0.155)
            ChamferRect(chamfer: size * 0.022)
                .fill(coral)
                .frame(width: size * 0.50, height: size * 0.20)
            Rectangle()
                .fill(dark)
                .frame(width: size * 0.055, height: size * 0.155)
        }
    }

    // 4 只脚：两对像素方块；走路时左右对交替抬起
    private var legs: some View {
        HStack(spacing: 0) {
            legPair(raised: walking && legPhase == 0)
            Spacer().frame(width: size * 0.13)
            legPair(raised: walking && legPhase == 1)
        }
    }

    private func legPair(raised: Bool) -> some View {
        HStack(spacing: size * 0.03) {
            foot(raised: raised)
            foot(raised: raised)
        }
    }

    private func foot(raised: Bool) -> some View {
        Rectangle()
            .fill(dark)
            .frame(width: size * 0.07, height: size * 0.17)
            .offset(y: raised ? -size * 0.04 : 0)
            .animation(.easeInOut(duration: 0.22), value: raised)
    }

    // 角色配色固定，不跟随系统主题——保持「拾贴」官方珊瑚 + 近黑像素的统一形象。
    private var coral: Color { Color(red: 0.83, green: 0.51, blue: 0.40) }
    private var dark: Color { Color(red: 0.07, green: 0.07, blue: 0.09) }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5.5)))
            blinkPhase = 0.06
            try? await Task.sleep(for: .milliseconds(115))
            blinkPhase = 1.0
            if Double.random(in: 0...1) < 0.18 {                  // 偶尔双眨
                try? await Task.sleep(for: .milliseconds(150))
                blinkPhase = 0.06
                try? await Task.sleep(for: .milliseconds(110))
                blinkPhase = 1.0
            }
        }
    }

    private func walkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(280))
            legPhase = (legPhase + 1) % 2
        }
    }

    private func happyHop() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
            hopOffset = -size * 0.10
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                hopOffset = 0
            }
        }
    }
}

// 嘴形：一条二次贝塞尔曲线，控制点上下偏移决定笑 / 平 / 哭
private struct MouthShape: Shape {
    var curve: CGFloat
    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                       control: CGPoint(x: rect.midX, y: rect.midY + curve))
        return p
    }
}

// 一滴眼泪：从眼下出现 → 下落 → 淡出，循环；delay 让左右两滴错开节奏
private struct Teardrop: View {
    let size: CGFloat
    var delay: Double = 0
    @State private var phase: CGFloat = 0
    var body: some View {
        Circle()
            .fill(Color(red: 0.45, green: 0.70, blue: 0.96))
            .frame(width: size * 0.05, height: size * 0.075)
            .offset(y: phase * size * 0.13)
            .opacity(Double(1 - phase))
            .onAppear {
                phase = 0
                withAnimation(.easeIn(duration: 0.9).repeatForever(autoreverses: false).delay(delay)) {
                    phase = 1
                }
            }
    }
}

// 八角形「chamfer」矩形：用来当机器人脑袋
private struct ChamferRect: Shape {
    let chamfer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = min(chamfer, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        p.closeSubpath()
        return p
    }
}

// MARK: - 桌面把手：整个面板就是这只小机器人
// 机器人是纯视觉层（下面 `.allowsHitTesting(false)`）：鼠标命中让给底下的 NSHostingView，
// 于是落在机器人上的拖动由面板的 `isMovableByWindowBackground` 接管来移动整窗——和拖卡片区
// 一样。**不**在这里加 SwiftUI 手势/按钮，否则会拦住命中、反而拖不动。
// 展开 / 收起由 AppController 的鼠标悬停轮询驱动；心情(mood)随网络变化。
private struct ClaudeHandle: View {
    @ObservedObject var state: DrawerState
    let bopTrigger: Int

    var body: some View {
        ZStack {
            PixelRobot(
                size: 72,
                walking: state.expanded,
                bopTrigger: bopTrigger,
                mood: state.mood
            )
            .frame(width: 60, height: 64)
            .compositingGroup()
            // 双层阴影：浅色 halo 让深色像素在暗桌面上仍能辨认；深色 drop shadow 在浅色桌面给立体感
            .shadow(color: .white.opacity(0.55), radius: 1.6)
            .shadow(color: .white.opacity(0.40), radius: 0.8)
            .shadow(color: .black.opacity(0.40), radius: 6, y: 3)
            // 悬停显示网络状态文字 + 操作说明
            .help("\(state.moodText) · \(state.moodDetail) · 拖动移动 · 悬停展开")
            // 无障碍：补按钮语义 + 切换动作（鼠标交互走背景拖动 + 悬停）
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("拾贴")
            .accessibilityValue("\(state.expanded ? "已展开" : "已收起") · \(state.moodText)")
            .accessibilityHint("展开或收起剪贴板历史")
            .accessibilityAction { state.onToggle?() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 让出鼠标命中：交给底下的 NSHostingView，机器人区因此能靠 isMovableByWindowBackground
        // 被拖动（和卡片区一致）；SwiftUI 不拦截。
        .allowsHitTesting(false)
    }
}

// MARK: - 菜单栏弹出内容

struct MenuBarContentView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var state: DrawerState

    var body: some View {
        // 菜单栏弹出层是固定尺寸，超出就滚动；外面包 ScrollView 即可（RecordsPanel
        // 自身已经不带 ScrollView，需要在这里补一个）。
        ScrollView(.vertical, showsIndicators: true) {
            RecordsPanel(store: store, state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 记录面板（复用）

struct RecordsPanel: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var state: DrawerState

    @State private var copiedID: UUID?
    @State private var showClearConfirm = false
    @State private var showQuitConfirm = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            statusBanner            // 网络 / Claude 可用性文字提示
            if state.showSettings {
                settingsPanel
            } else if store.items.isEmpty {
                emptyView
            } else {
                list
            }
        }
    }

    // 网络状态条：彩色圆点 + 主文案 + 副文案(延迟/原因) + 表情，跟小机器人心情一致
    private var statusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(state.moodText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Text(state.moodDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(statusEmoji)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(statusColor.opacity(0.10))
        .animation(.easeInOut(duration: 0.35), value: state.mood)
    }

    private var statusColor: Color {
        switch state.mood {
        case .happy: return .green
        case .neutral: return .orange
        case .sad: return .red
        }
    }
    private var statusEmoji: String {
        switch state.mood {
        case .happy: return "😊"
        case .neutral: return "😐"
        case .sad: return "😢"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 小一号的拾贴机器人，作为「品牌锚点」陪在标题边，会持续呼吸 + 偶尔眨眼
            PixelRobot(size: 26, walking: false, mood: state.mood)
                .frame(width: 22, height: 24)
                .compositingGroup()
                .shadow(color: .white.opacity(0.45), radius: 0.6)
            Text("剪贴板历史")
                .font(.headline)
            Spacer()
            Text("\(store.items.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: store.items.count)
            if state.mode == .menuBar {
                Button {
                    state.onUndock?()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help("恢复悬浮窗口")
            } else {
                Button {
                    state.onDock?()
                } label: {
                    Image(systemName: "arrow.up.to.line")
                }
                .buttonStyle(.plain)
                .help("收起到菜单栏")
            }
            Button {
                withAnimation { state.showSettings.toggle() }
            } label: {
                Image(systemName: state.showSettings ? "list.bullet" : "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help(state.showSettings ? "返回列表" : "设置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        // 不再自带 ScrollView——外层 DrawerView 已经包了一层；这里 LazyVStack 把自身
        // 的「自然高度」交给上层 GeometryReader 测出来，方便面板按内容大小自适应。
        LazyVStack(spacing: 8) {
            ForEach(store.items) { item in
                row(item)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func row(_ item: ClipItem) -> some View {
        Button {
            store.copyToPasteboard(item)
            copiedID = item.id
            Task {
                try? await Task.sleep(for: .seconds(1))
                if copiedID == item.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: 10) {
                preview(item)
                Spacer(minLength: 4)
                if copiedID == item.id {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(item.date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 用 .primary（系统色）+ 较高透明度：浅色模式下出现浅黑底，深色模式下出现浅白底，
            // 两种主题、各种桌面背景下行的边界都清晰。
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("写入剪贴板") { store.copyToPasteboard(item) }
            Button("删除", role: .destructive) { store.delete(item) }
        }
    }

    @ViewBuilder
    private func preview(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        case .image:
            HStack(spacing: 10) {
                if let img = store.image(for: item) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo")
                        .frame(width: 64, height: 48)
                }
                Text("图片")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            // 大号像素机器人：呼吸、眨眼、原地小走两步，让空状态也有「活物」感
            PixelRobot(size: 96, walking: true, mood: state.mood)
                .frame(width: 80, height: 88)
                .compositingGroup()
                .shadow(color: .white.opacity(0.5), radius: 1.6)
                .shadow(color: .black.opacity(0.20), radius: 4, y: 2)
            Text("还是一片空白")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.85))
            Text("复制点什么试试，我帮你记着")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("最多保留记录数")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach([20, 50, 100, 200], id: \.self) { n in
                        Button {
                            store.maxItems = n
                        } label: {
                            Text("\(n)")
                                .font(.callout)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    store.maxItems == n ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                                .foregroundStyle(store.maxItems == n ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Stepper("自定义：\(store.maxItems) 条", value: $store.maxItems, in: 5...500, step: 5)
                    .font(.callout)
            }

            launchAtLoginRow

            Divider().opacity(0.4)

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空全部历史", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .alert("确认清空全部历史？", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.30)) { store.clear() }
                }
            } message: {
                Text("当前所有剪贴板记录将被删除，且无法恢复。")
            }

            Button {
                showQuitConfirm = true
            } label: {
                Label("退出拾贴", systemImage: "power")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .alert("确认退出拾贴？", isPresented: $showQuitConfirm) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) { state.onQuit?() }
            } message: {
                Text("退出后不会再记录新的剪贴板内容。")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「开机自动启动」开关：开关本身是原生 SwiftUI Toggle（自带滑块动画），
    /// 左侧带一个状态图标——开时弹起、着色、轻微旋转回正；关时变灰、内缩，副标题文字也跟着切换。
    private var launchAtLoginRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(launchAtLogin ? Color.accentColor.opacity(0.20) : Color.white.opacity(0.06))
                    .frame(width: 32, height: 32)
                    .scaleEffect(launchAtLogin ? 1.0 : 0.92)
                Image(systemName: launchAtLogin ? "power.circle.fill" : "power")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(launchAtLogin ? Color.accentColor : .secondary)
                    .rotationEffect(.degrees(launchAtLogin ? 0 : -30))
                    .scaleEffect(launchAtLogin ? 1.05 : 0.92)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("开机自动启动")
                    .font(.callout)
                Text(launchAtLogin ? "登录时自动打开拾贴" : "需要手动启动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Toggle("", isOn: $launchAtLogin)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: launchAtLogin)
        .onChange(of: launchAtLogin) { _, newValue in
            // 系统可能拒绝注册（签名问题、待审批等）；失败时回滚 UI 状态以保持一致。
            if !LaunchAtLogin.setEnabled(newValue) {
                launchAtLogin = LaunchAtLogin.isEnabled()
            }
        }
    }
}
