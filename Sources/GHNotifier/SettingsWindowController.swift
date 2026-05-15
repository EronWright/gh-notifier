import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GH Notifier Settings"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.window?.center()
        }
    }
}

private struct PollOption {
    let label: String
    let seconds: Double
}

private struct SettingsView: View {
    @AppStorage(UserSettings.pollIntervalKey) private var pollInterval: Double = 15 * 60
    @AppStorage(UserSettings.bannerCapKey)    private var bannerCap: Int = 5
    @AppStorage(UserSettings.maxPagesKey)     private var maxPages: Int = 5

    private let pollChoices: [PollOption] = [
        PollOption(label: "5 minutes",  seconds: 5  * 60),
        PollOption(label: "15 minutes", seconds: 15 * 60),
        PollOption(label: "30 minutes", seconds: 30 * 60),
        PollOption(label: "1 hour",     seconds:  1 * 3600),
        PollOption(label: "2 hours",    seconds:  2 * 3600),
        PollOption(label: "6 hours",    seconds:  6 * 3600),
        PollOption(label: "12 hours",   seconds: 12 * 3600),
        PollOption(label: "24 hours",   seconds: 24 * 3600),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Poll interval") {
                Picker("", selection: $pollInterval) {
                    ForEach(pollChoices, id: \.seconds) { opt in
                        Text(opt.label).tag(opt.seconds)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Divider()

            row("Banner cap") {
                HStack(spacing: 4) {
                    TextField("", value: $bannerCap, format: .number)
                        .frame(width: 36)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { bannerCap = max(0, min(20, bannerCap)) }
                    Stepper("", value: $bannerCap, in: 0...20)
                        .labelsHidden()
                    Text("per poll")
                        .foregroundColor(.secondary)
                }
            }

            row("Max pages") {
                HStack(spacing: 4) {
                    TextField("", value: $maxPages, format: .number)
                        .frame(width: 36)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { maxPages = max(1, min(10, maxPages)) }
                    Stepper("", value: $maxPages, in: 1...10)
                        .labelsHidden()
                    Text("per poll")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 100, alignment: .trailing)
            content()
        }
    }
}
