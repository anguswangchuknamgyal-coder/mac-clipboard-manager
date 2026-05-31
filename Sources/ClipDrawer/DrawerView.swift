import SwiftUI

// MARK: - 悬浮抽屉（单块玻璃，悬停整体展开）

struct DrawerView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var state: DrawerState

    var body: some View {
        VStack(spacing: 0) {
            grabber
            if state.expanded {
                RecordsPanel(store: store, state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.expanded)
    }

    private var grabber: some View {
        // 把手 + 展开/收起按钮整体「居中固定」：窗口按中心锚定，宽度在折叠(140)/展开(400)
        // 之间变化时，居中的把手在屏幕上的横坐标保持不变，按钮不会随窗口大小左右乱跳。
        VStack(spacing: 2) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 46, height: 5)
            Button {
                if state.expanded { state.onCollapse?() } else { state.onExpand?() }
            } label: {
                Image(systemName: state.expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.expanded ? "收起" : "展开")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
    }
}

// MARK: - 菜单栏弹出内容

struct MenuBarContentView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var state: DrawerState

    var body: some View {
        RecordsPanel(store: store, state: state)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if state.showSettings {
                settingsPanel
            } else if store.items.isEmpty {
                emptyView
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("剪贴板历史")
                .font(.headline)
            Spacer()
            Text("\(store.items.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
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
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
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
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("还没有复制记录")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("复制任意文字或图片，就会出现在这里")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
}
