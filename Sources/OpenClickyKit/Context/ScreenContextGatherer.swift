import AppKit
import CoreGraphics
import Foundation

/// Keeps track of the app the user was last working in, skipping OpenClicky itself (its settings window or chat
/// can be frontmost when the user asks something about the app behind it).
public final class FrontAppTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last: FrontAppInfo?
    private let ignoredBundleIdentifiers: Set<String>
    private var observer: NSObjectProtocol?

    public init(ignoring bundleIdentifiers: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 })) {
        ignoredBundleIdentifiers = bundleIdentifiers
        update(NSWorkspace.shared.frontmostApplication)
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Start following app activations (call once, from the app).
    public func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                     queue: nil) { [weak self] notification in
            self?.update(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    /// The last app other than the ignored ones to come to the front. Off the main thread this is the value the
    /// activation observer last saw (NSWorkspace updates `frontmostApplication` on the main thread).
    public var current: FrontAppInfo? {
        if Thread.isMainThread { update(NSWorkspace.shared.frontmostApplication) }
        return lock.withLock { last }
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app, let info = Self.info(app), !ignoredBundleIdentifiers.contains(info.bundleIdentifier ?? "") else { return }
        lock.withLock { last = info }
    }

    static func info(_ app: NSRunningApplication) -> FrontAppInfo? {
        FrontAppInfo(name: app.localizedName, bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }
}

public struct ScreenContextOptions: Sendable {
    public var includeFocus: Bool
    public var includeDocument: Bool
    public var document: ActiveDocumentOptions
    /// Characters of an editable field's value included as a preview.
    public var valuePreviewCharacters: Int

    public init(includeFocus: Bool = true, includeDocument: Bool = true, document: ActiveDocumentOptions = ActiveDocumentOptions(),
                valuePreviewCharacters: Int = 400) {
        self.includeFocus = includeFocus
        self.includeDocument = includeDocument
        self.document = document
        self.valuePreviewCharacters = valuePreviewCharacters
    }
}

/// Gathers everything about the user's screen except pixels. Needs no Screen Recording permission; Accessibility
/// unlocks the window title, focus, selection and files, and Automation unlocks browser pages.
public struct ScreenContextGatherer: Sendable {
    public var accessibility: any AccessibilityContextSource
    public var documents: ActiveDocumentReader
    public var layout: @Sendable () -> DesktopLayout
    public var cursor: @Sendable (DesktopLayout) -> CGPoint
    public var frontApp: @Sendable () -> FrontAppInfo?
    public var permissions: @Sendable () -> ContextPermissions

    public init(accessibility: any AccessibilityContextSource, documents: ActiveDocumentReader,
                layout: @escaping @Sendable () -> DesktopLayout, cursor: @escaping @Sendable (DesktopLayout) -> CGPoint,
                frontApp: @escaping @Sendable () -> FrontAppInfo?, permissions: @escaping @Sendable () -> ContextPermissions) {
        self.accessibility = accessibility
        self.documents = documents
        self.layout = layout
        self.cursor = cursor
        self.frontApp = frontApp
        self.permissions = permissions
    }

    /// The real thing: live Accessibility, browser scripting, the disk, Core Graphics and NSWorkspace.
    public static func live(frontApps: FrontAppTracker = FrontAppTracker(), ledger: GuardedFolderLedger = GuardedFolderLedger()) -> ScreenContextGatherer {
        let accessibility = LiveAccessibilityContext()
        return ScreenContextGatherer(
            accessibility: accessibility,
            documents: ActiveDocumentReader(accessibility: accessibility, ledger: ledger),
            layout: { DesktopLayout.current() },
            cursor: { DesktopLayout.currentCursorLocation(in: $0) },
            frontApp: { frontApps.current },
            permissions: { ContextPermissions.current })
    }

    public func gather(_ options: ScreenContextOptions = ScreenContextOptions()) async -> ScreenContext {
        let layout = layout()
        let permissions = permissions()
        var context = ScreenContext(layout: layout, cursor: cursor(layout), permissions: permissions)
        if !permissions.accessibility {
            context.notes.append("Accessibility permission is off: no window title, focused control, selection or open file.")
        }
        guard let app = frontApp() else {
            context.notes.append("Couldn't tell which app is in front.")
            return context
        }
        context.frontApp = app
        context.window = accessibility.focusedWindow(pid: app.processIdentifier, layout: layout)
        if permissions.accessibility, context.window?.source == .windowList {
            context.notes.append("Accessibility gave no window for \(app.name ?? "the app") (is the screen locked?); using the window list"
                                 + (permissions.screenRecording ? "." : ", which has no titles without Screen Recording."))
        }
        if options.includeFocus {
            context.focus = accessibility.focusedElement(pid: app.processIdentifier, layout: layout, valuePreviewCharacters: options.valuePreviewCharacters)
        }
        if options.includeDocument {
            let result = await documents.read(app: app, window: context.window, options: options.document)
            context.document = result.document
            context.notes += result.notes.filter { !$0.isEmpty }
        }
        return context
    }
}
