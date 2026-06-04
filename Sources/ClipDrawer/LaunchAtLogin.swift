import ServiceManagement

/// 登录时自动启动拾贴。基于 macOS 13+ 的 `SMAppService.mainApp`——
/// 系统记录的是「当前 app 二进制路径」，所以建议先把 .app 拖进 /Applications 再开启，
/// 否则下次开机会去启动你当时所在的开发目录里的那个 .app。
enum LaunchAtLogin {
    /// 当前是否已注册为登录启动项
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 注册 / 反注册。返回实际生效结果（系统可能因签名 / 沙盒 / 待审批等理由拒绝）。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, .enabled):
                break
            case (true, _):
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            case (false, _):
                break
            }
        } catch {
            return false
        }
        return (SMAppService.mainApp.status == .enabled) == enabled
    }
}
