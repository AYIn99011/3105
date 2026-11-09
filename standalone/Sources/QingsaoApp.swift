import SwiftUI
import UIKit

@main
struct QingsaoApp: App {
    init() {
        setupLogCapture()
        log("app: Qingsao launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                CleanerView()
                    .tabItem { Label("清理", systemImage: "trash") }

                LogView()
                    .tabItem { Label("日志", systemImage: "doc.text") }
            }
            .environment(\.appLanguage, .simplifiedChinese)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
    }
}
