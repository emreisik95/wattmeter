import Foundation
import AppKit

/// Registers a `wattmeter://` URL scheme handler with the AppleEvent manager.
///
/// IMPORTANT: callers MUST invoke `URLSchemeHandler.register(actions:)` from
/// `applicationWillFinishLaunching(_:)` — NOT `applicationDidFinishLaunching`.
/// macOS dispatches the launch URL AppleEvent between those two callbacks,
/// so a handler registered in `didFinish` misses URLs from `open wattmeter://…`
/// on first launch.
///
/// URL grammar:
///   wattmeter://<action>[?<query>]
/// `action` is matched against the keys in `actions`. Query parameters are
/// passed to the closure as a `[String: String]`. Unknown actions are logged.
enum URLSchemeHandler {

    /// Action callback. Receives parsed query parameters (may be empty).
    typealias Action = ([String: String]) -> Void

    /// Backing storage so we keep the singleton bridge alive for the
    /// AppleEvent manager.
    private static var bridge: URLSchemeBridge?

    /// Register the given actions and start listening for `wattmeter://` URLs.
    /// Safe to call multiple times — subsequent calls replace the action table.
    /// - Parameter actions: map from action name → closure. Closures must be
    ///   safe to call on the main thread; the handler dispatches to main.
    static func register(actions: [String: Action]) {
        let b = bridge ?? URLSchemeBridge()
        b.actions = actions
        if bridge == nil {
            bridge = b
            NSAppleEventManager.shared().setEventHandler(
                b,
                andSelector: #selector(URLSchemeBridge.handle(event:replyEvent:)),
                forEventClass: AEEventClass(kInternetEventClass),
                andEventID: AEEventID(kAEGetURL)
            )
        }
    }

    /// Convenience: dispatch a raw URL into the registered action table.
    /// Exposed so a SwiftUI `onOpenURL` modifier or unit tests can drive the
    /// same code path without going through AppleEvents.
    static func dispatch(_ url: URL) {
        bridge?.dispatch(url)
    }

    /// List of registered action names (sorted). Used by Help menus / tests.
    static var registeredActions: [String] {
        (bridge?.actions.keys).map { Array($0).sorted() } ?? []
    }
}

@objc final class URLSchemeBridge: NSObject {
    var actions: [String: URLSchemeHandler.Action] = [:]

    @objc func handle(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw) else { return }
        dispatch(url)
    }

    func dispatch(_ url: URL) {
        guard url.scheme?.lowercased() == "wattmeter" else { return }
        // `host` is the action for wattmeter://refresh?foo=bar style;
        // fall back to first path component for wattmeter:///refresh.
        let action = (url.host?.isEmpty == false ? url.host : url.pathComponents.first { $0 != "/" }) ?? ""
        var params: [String: String] = [:]
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items where item.value != nil {
                params[item.name] = item.value
            }
        }
        guard let cb = actions[action] else {
            #if DEBUG
            NSLog("[URLSchemeHandler] unknown action: \(action)")
            #endif
            return
        }
        if Thread.isMainThread {
            cb(params)
        } else {
            DispatchQueue.main.async { cb(params) }
        }
    }
}
