import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: StudioModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.state == .maintaining else { return true }
        model?.notice = "设备维护仍在进行。请等待完成，或先在设备工具中中止操作。"
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.state != .disconnected else { return .terminateNow }
        if model.state == .connecting || model.state == .stopping || model.state == .maintaining { return .terminateCancel }
        model.stop(disconnect: true) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct MotorStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = StudioModel()
    var body: some Scene {
        Window("Motor Studio", id: "studio") {
            StudioView().environment(model)
                .preferredColorScheme(.dark)
                .onAppear { delegate.model = model }
                .background(WindowDelegateReader(delegate: delegate))
        }
        .defaultSize(width: 1360, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .commands { MotorCommands(model: model) }
    }
}

private struct WindowDelegateReader: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> NSView { ReaderView(delegate: delegate) }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.delegate = delegate }
    private final class ReaderView: NSView {
        weak var owner: AppDelegate?
        init(delegate: AppDelegate) { owner = delegate; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.delegate = owner; window?.minSize = NSSize(width: 1180, height: 780) }
    }
}

private struct MotorCommands: Commands {
    let model: StudioModel
    var body: some Commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("电机") {
                Button("停止所有受控电机") { model.stop() }.keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.connected || model.state == .stopping || model.state == .maintaining)
                Button("导出 CSV…") { model.exportCSV() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.hasRecording)
            }
        }
}
