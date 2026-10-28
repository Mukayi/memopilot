import SwiftUI
import AppKit
import MemoPilotCore

final class ZeroSafeAreaHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated {
            AppDelegate.alignTrafficLights(in: self.window, headerHeight: 46.0)
            DispatchQueue.main.async { [weak self] in
                AppDelegate.alignTrafficLights(in: self?.window, headerHeight: 46.0)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var mainWindow: NSWindow?
    lazy var viewModel = AppViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let themeIdx = CommandLine.arguments.firstIndex(of: "--theme"),
           themeIdx + 1 < CommandLine.arguments.count {
            let arg = CommandLine.arguments[themeIdx + 1]
            switch arg {
            case "warm": viewModel.theme = .warmPaper
            case "white": viewModel.theme = .notesWhite
            case "blue": viewModel.theme = .mistBlue
            case "dark": viewModel.theme = .darkNight
            default: break
            }
        }

        setupAndShowMainWindow()
        viewModel.registerHotKeysAndRemoteListener()

        if let idx = CommandLine.arguments.firstIndex(of: "--render-window"),
           idx + 1 < CommandLine.arguments.count {
            let outputPath = CommandLine.arguments[idx + 1]
            let collapsed = CommandLine.arguments.contains("--collapsed")
            viewModel.isSidebarCollapsed = collapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Self.captureOwnWindow(to: outputPath)
                exit(0)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.bringMainWindowToFront()
        return true
    }

    func setupAndShowMainWindow() {
        if Self.mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MemoPilot"
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = nil
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(red: 0.988, green: 0.982, blue: 0.968, alpha: 1.0)
            window.contentMinSize = NSSize(width: 920, height: 560)

            let hostingView = ZeroSafeAreaHostingView(rootView: MainWorkspaceView(viewModel: viewModel))
            hostingView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 980, height: 580)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.center()
            Self.mainWindow = window
            Self.alignTrafficLights(in: window, headerHeight: 46.0)

            for name in [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didEndLiveResizeNotification
            ] {
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        Self.alignTrafficLights(in: Self.mainWindow, headerHeight: 46.0)
                    }
                }
            }
        }
        Self.bringMainWindowToFront()
    }

    static func alignTrafficLights(in window: NSWindow?, headerHeight: CGFloat = 46.0) {
        guard let window,
              let closeBtn = window.standardWindowButton(.closeButton),
              let miniBtn = window.standardWindowButton(.miniaturizeButton),
              let zoomBtn = window.standardWindowButton(.zoomButton),
              let titlebarView = closeBtn.superview,
              let containerView = titlebarView.superview else {
            return
        }

        let targetContainerY = window.frame.height - headerHeight
        if abs(containerView.frame.height - headerHeight) > 0.5 || abs(containerView.frame.origin.y - targetContainerY) > 0.5 {
            containerView.frame = NSRect(
                x: 0,
                y: targetContainerY,
                width: window.frame.width,
                height: headerHeight
            )
            titlebarView.frame = containerView.bounds
        }

        let btnHeight = closeBtn.frame.height
        let centeredY = round((headerHeight - btnHeight) / 2.0)
        let startX: CGFloat = 16.0
        let spacing: CGFloat = 20.0

        if abs(closeBtn.frame.origin.x - startX) > 0.5 || abs(closeBtn.frame.origin.y - centeredY) > 0.5 {
            closeBtn.setFrameOrigin(NSPoint(x: startX, y: centeredY))
            miniBtn.setFrameOrigin(NSPoint(x: startX + spacing, y: centeredY))
            zoomBtn.setFrameOrigin(NSPoint(x: startX + spacing * 2, y: centeredY))
        }
    }

    static func clearAnyWindowFirstResponder() {
        mainWindow?.makeFirstResponder(nil)
        if let keyWin = NSApp.keyWindow, keyWin !== mainWindow {
            keyWin.makeFirstResponder(nil)
        }
    }

    static func toggleMainWindow() {
        if let window = mainWindow, window.isVisible && window.isKeyWindow && NSApp.isActive {
            window.orderOut(nil)
        } else {
            bringMainWindowToFront()
        }
    }

    static func bringMainWindowToFront() {
        NSApp.activate()
        if mainWindow == nil {
            (NSApp.delegate as? AppDelegate)?.setupAndShowMainWindow()
            return
        }
        if let window = mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            alignTrafficLights(in: window, headerHeight: 46.0)
        }
    }

    static func captureOwnWindow(to outputPath: String) {
        guard let window = mainWindow,
              let contentView = window.contentView else { return }
        let targetView = contentView.superview ?? contentView
        targetView.layoutSubtreeIfNeeded()
        alignTrafficLights(in: window, headerHeight: 46.0)
        let bounds = targetView.bounds
        guard !bounds.isEmpty,
              let rep = targetView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        targetView.cacheDisplay(in: bounds, to: rep)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: outputPath))
        }
    }
}

@main
struct MemoPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let args = CommandLine.arguments
        if let remoteIdx = args.firstIndex(of: "--remote"),
           remoteIdx + 1 < args.count {
            let action = args[remoteIdx + 1]
            let textArg: String? = (remoteIdx + 2 < args.count && !args[remoteIdx + 2].hasPrefix("--")) ? args[remoteIdx + 2] : nil
            var planJSON: String? = nil
            if let pIdx = args.firstIndex(of: "--plan-json"), pIdx + 1 < args.count {
                planJSON = args[pIdx + 1]
            }
            var themeArg: String? = textArg
            if let tIdx = args.firstIndex(of: "--theme"), tIdx + 1 < args.count {
                themeArg = args[tIdx + 1]
            }
            let autoCommit = args.contains("--commit")
            let cmd = RemoteControlCommand(
                action: action,
                text: textArg,
                planJSON: planJSON,
                theme: themeArg,
                autoCommit: autoCommit
            )
            let result = (try? CursorRemoteControl.sendCommand(cmd)) ?? "发送失败"
            print(result)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("MemoPilot", systemImage: "sparkles.rectangle.stack.fill") {
            MenuBarContentView(viewModel: appDelegate.viewModel)
                .frame(width: 420)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(appDelegate.viewModel.isSidebarCollapsed ? "显示历史侧边栏" : "隐藏历史侧边栏") {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        appDelegate.viewModel.isSidebarCollapsed.toggle()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }
}
