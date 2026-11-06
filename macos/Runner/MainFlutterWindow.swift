import Cocoa
import FlutterMacOS
import window
import LaunchAtLogin
import SystemConfiguration

class MainFlutterWindow: NSWindow {
    private let networkEvents = HostNetworkEvents()

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        FlutterEventChannel(
            name: "com.follow.clash/network-events",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        ).setStreamHandler(networkEvents)
        
        FlutterMethodChannel(
            name: "launch_at_startup", binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                result(LaunchAtLogin.isEnabled)
            case "launchAtStartupSetEnabled":
                if let arguments = call.arguments as? [String: Any] {
                    LaunchAtLogin.isEnabled = arguments["setEnabledValue"] as! Bool
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        RegisterGeneratedPlugins(registry: flutterViewController)
        super.awakeFromNib()
    }
    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }
}

final class HostNetworkEvents: NSObject, FlutterStreamHandler {
    private var observer: NSObjectProtocol?
    private var networkStore: SCDynamicStore?
    private var networkSource: CFRunLoopSource?
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        stop()
        eventSink = events
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in events("wake") }
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        networkStore = SCDynamicStoreCreate(nil, "FlClashNetwork" as CFString, { _, keys, info in
            guard let info else { return }
            let owner = Unmanaged<HostNetworkEvents>.fromOpaque(info).takeUnretainedValue()
            let physicalChange = (keys as! [String]).contains { key in
                let interface = key.split(separator: "/")[3]
                return interface != "lo0" && !interface.hasPrefix("utun")
            }
            if physicalChange { owner.eventSink?("network") }
        }, &context)
        if let networkStore {
            SCDynamicStoreSetNotificationKeys(
                networkStore, nil,
                ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6"] as CFArray
            )
            networkSource = SCDynamicStoreCreateRunLoopSource(nil, networkStore, 0)
            if let networkSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), networkSource, .commonModes)
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stop()
        return nil
    }

    private func stop() {
        if let networkSource {
            CFRunLoopSourceInvalidate(networkSource)
            self.networkSource = nil
        }
        networkStore = nil
        eventSink = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        stop()
    }
}
