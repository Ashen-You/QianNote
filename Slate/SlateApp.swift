import SwiftUI
import UIKit

@main
struct SlateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore()
    @StateObject private var opener = DocumentOpenCoordinator()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(opener)
                .tint(Theme.accent)
                // 「文件」→ 分享 → Slate、其它 app「用 Slate 打开」都会走到这里
                .onOpenURL { url in
                    opener.open([url], store: store)
                }
        }
    }
}

/// 只干一件事：把主屏快捷操作接进来。文档打开走 SwiftUI 的 onOpenURL，不需要 AppDelegate。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 冷启动：长按图标点了快捷操作时，快捷项挂在连接选项里
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            ShortcutInbox.put(item.type)
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// App 已在运行时又点了一次快捷操作
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        ShortcutInbox.put(shortcutItem.type)
        NotificationCenter.default.post(name: .slateShortcutTriggered, object: nil)
        completionHandler(true)
    }
}
