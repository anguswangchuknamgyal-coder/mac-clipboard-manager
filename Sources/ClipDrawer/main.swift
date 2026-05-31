import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = 无 Dock 图标、无菜单栏标题的后台代理应用
app.setActivationPolicy(.accessory)
app.run()
