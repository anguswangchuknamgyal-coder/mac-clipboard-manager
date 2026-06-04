import AppKit
import ServiceManagement

// 命令行开关：管理「开机自动启动」而不打开 GUI。
//   ClipDrawer --disable-autostart   关闭开机自启
//   ClipDrawer --enable-autostart    开启开机自启
//   ClipDrawer --autostart-status    打印当前状态
// 注意：SMAppService.mainApp 按「当前进程的 Bundle 身份」操作；必须用 .app 内的可执行文件运行
// （拾贴.app/Contents/MacOS/ClipDrawer），裸二进制没有 bundle id 会静默操作到错误身份。
let cliArgs = CommandLine.arguments
let autostartFlags: Set<String> = ["--disable-autostart", "--enable-autostart", "--autostart-status"]
if cliArgs.contains(where: autostartFlags.contains) {
    guard Bundle.main.bundleIdentifier != nil else {
        FileHandle.standardError.write(Data(
            "拾贴: 管理开机自启必须运行 .app 内的可执行文件（如 /Applications/拾贴.app/Contents/MacOS/ClipDrawer --disable-autostart），裸二进制无效。\n".utf8))
        exit(2)
    }
    if cliArgs.contains("--disable-autostart") {
        do { try SMAppService.mainApp.unregister() } catch { print("unregister failed: \(error)") }
        print("autostart disabled; status=\(SMAppService.mainApp.status.rawValue) (0=notRegistered)")
    } else if cliArgs.contains("--enable-autostart") {
        do { try SMAppService.mainApp.register() } catch { print("register failed: \(error)") }
        print("autostart enabled; status=\(SMAppService.mainApp.status.rawValue) (1=enabled)")
    } else {
        print("autostart status=\(SMAppService.mainApp.status.rawValue) (0=notRegistered 1=enabled)")
    }
    exit(0)
}

// 单实例守卫：已有一个拾贴在跑就不要再开第二个——两只机器人会同时轮询鼠标、
// 抢同一份 history.json，还会让人以为「拖不动」（其实在拖另一个实例）。
let myBundleID = Bundle.main.bundleIdentifier ?? "com.wangchuknamgyal.clipdrawer"
let myPID = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
    .filter { $0.processIdentifier != myPID }
if !others.isEmpty {
    others.first?.activate(options: [])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = 无 Dock 图标、无菜单栏标题的后台代理应用
app.setActivationPolicy(.accessory)
app.run()
