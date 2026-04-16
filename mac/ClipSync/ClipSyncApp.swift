import AppKit
import Combine
import IOKit.pwr_mgt
import SwiftUI

@main
struct ClipSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var pairingManager = PairingManager.shared

    init() {
        UserDefaults.standard.register(defaults: [
            "syncToMac": true,
            "syncFromMac": true
        ])

        DirectLinkServer.shared.startIfNeeded()
        PairingManager.shared.restorePairing()

        if PairingManager.shared.isPaired, ServerConfiguration.shared.hasConfiguration {
            ClipboardManager.shared.startMonitoring()
            ClipboardManager.shared.listenForAndroidClipboard()
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .background(WindowConfigurator { window in
                    window.identifier = NSUserInterfaceItemIdentifier("mainWindow")
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.styleMask.insert(.fullSizeContentView)
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.toolbar?.showsBaselineSeparator = false
                    window.isMovableByWindowBackground = true
                })
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: Set(arrayLiteral: "main"))
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .defaultSize(width: 590, height: 590)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    init(_ configure: @escaping (NSWindow) -> Void) {
        self.configure = configure
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let window = nsView?.window {
                configure(window)
            }
        }
    }
}

#if canImport(HotSwiftUI)
@_exported import HotSwiftUI
#elseif canImport(Inject)
@_exported import Inject
#else
#if DEBUG
import Combine

public class InjectionObserver: ObservableObject {
    public static let shared = InjectionObserver()
    @Published var injectionNumber = 0
    var cancellable: AnyCancellable? = nil
    let publisher = PassthroughSubject<Void, Never>()

    init() {
        cancellable = NotificationCenter.default.publisher(for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"))
            .sink { [weak self] _ in
                self?.injectionNumber += 1
                self?.publisher.send()
            }
    }
}

extension SwiftUI.View {
    public func eraseToAnyView() -> some SwiftUI.View { AnyView(self) }
    public func enableInjection() -> some SwiftUI.View { eraseToAnyView() }
    public func onInjection(bumpState: @escaping () -> Void) -> some SwiftUI.View {
        onReceive(InjectionObserver.shared.publisher, perform: bumpState).eraseToAnyView()
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
@propertyWrapper
public struct ObserveInjection: DynamicProperty {
    @ObservedObject private var observer = InjectionObserver.shared

    public init() {}
    public private(set) var wrappedValue: Int {
        get { 0 }
        set {}
    }
}
#else
extension SwiftUI.View {
    @inline(__always) public func eraseToAnyView() -> some SwiftUI.View { self }
    @inline(__always) public func enableInjection() -> some SwiftUI.View { self }
    @inline(__always) public func onInjection(bumpState: @escaping () -> Void) -> some SwiftUI.View { self }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
@propertyWrapper
public struct ObserveInjection {
    public init() {}
    public private(set) var wrappedValue: Int {
        get { 0 }
        set {}
    }
}
#endif
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, OTPNotificationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var cancellables = Set<AnyCancellable>()
    var assertionID: IOPMAssertionID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover

        OTPNotificationManager.shared.delegate = self

        PairingManager.shared.$isPaired
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paired in
                self?.updateMenuBarState(show: paired)
                self?.updateDockPolicy()

                if paired {
                    OTPNotificationManager.shared.startListening()
                } else {
                    OTPNotificationManager.shared.stopListening()
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        OTPNotificationManager.shared.stopListening()
        DirectLinkServer.shared.stop()
    }

    func updateDockPolicy() {
        if PairingManager.shared.isPaired {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }

            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func updateMenuBarState(show: Bool) {
        if show {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipSync")
                    button.action = #selector(togglePopover(_:))
                }
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if OTPNotificationManager.shared.hasRecentOTP {
            OTPNotificationManager.shared.reshowLastBubble()
            return
        }

        guard let button = statusItem?.button, let popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func preventAppSleep() {
        let reason = "ClipSync needs to monitor clipboard" as CFString
        _ = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
