// Jot for macOS: menu-bar app with a floating notes panel on a global hotkey (like Raycast Notes) and a graph window.
// Built on the Mac by install.sh: swiftc JotCore.swift JotModel.swift JotEditor.swift JotMedia.swift JotViews.swift JotGraph.swift JotApp.swift
import AppKit
import Carbon
import SwiftUI

@main
enum JotMain {
    static var delegate: AppDelegate?
    static func main() {
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        let app = NSApplication.shared
        MainActor.assumeIsolated {
            let d = AppDelegate()
            delegate = d
            app.delegate = d
        }
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - global hotkey (Carbon; needs no Accessibility permission)

final class HotKey {
    struct Choice { let name: String; let code: UInt32; let mods: UInt32 }
    static let choices = [
        Choice(name: "⌥ N", code: UInt32(kVK_ANSI_N), mods: UInt32(optionKey)),     // default (takes the ⌥N ñ dead key)
        Choice(name: "⌥ J", code: UInt32(kVK_ANSI_J), mods: UInt32(optionKey)),
        Choice(name: "⌥ Space", code: UInt32(kVK_Space), mods: UInt32(optionKey)),
        Choice(name: "⌃ Space", code: UInt32(kVK_Space), mods: UInt32(controlKey)),
        Choice(name: "⌃⌥ Space", code: UInt32(kVK_Space), mods: UInt32(controlKey | optionKey)),
        Choice(name: "⌘⇧ J", code: UInt32(kVK_ANSI_J), mods: UInt32(cmdKey | shiftKey)),
        Choice(name: "⌃⌥ N", code: UInt32(kVK_ANSI_N), mods: UInt32(controlKey | optionKey)),
    ]
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    /// false when another app already owns this shortcut
    func register(_ c: Choice) -> Bool {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
                guard let ctx = ctx else { return OSStatus(noErr) }
                let me = Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async { me.action?() }
                return OSStatus(noErr)
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4A4F5421), id: 1)      // 'JOT!'
        return RegisterEventHotKey(c.code, c.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - floating panel

/// the panel's blur background; reports the mouse entering / leaving anywhere in the window (even over the editor)
final class HoverBlur: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }

    /// stronger blur than the material's own: scale the backdrop layer's gaussian radius (the system may reset it,
    /// so it's re-applied on each layout; a missing layer/filter just leaves the stock blur)
    static let blurBoost: CGFloat = 1.5
    private var boosted: [ObjectIdentifier: CGFloat] = [:]
    override func layout() { super.layout(); boostBlur() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); boostBlur() }
    private func boostBlur() {
        guard let root = layer else { return }
        var stack = [root]
        while let l = stack.popLast() {
            stack += l.sublayers ?? []
            guard NSStringFromClass(type(of: l)).contains("Backdrop"), let filters = l.filters as? [NSObject] else { continue }
            for f in filters where f.responds(to: NSSelectorFromString("name")) && (f.value(forKey: "name") as? String) == "gaussianBlur" {
                guard let r = (f.value(forKey: "inputRadius") as? NSNumber).map({ CGFloat($0.doubleValue) }), r > 0 else { continue }
                let id = ObjectIdentifier(l)
                if let t = boosted[id], abs(t - r) < 0.01 { continue }
                boosted[id] = r * Self.blurBoost
                l.setValue(r * Self.blurBoost, forKeyPath: "filters.gaussianBlur.inputRadius")
            }
        }
    }
}

/// the panel's own drop shadow (the window is bigger than the card by `margin` on each side so there's room for it):
/// a tight contact shadow + a soft ambient one, plus a hairline outline like system windows. Drawn only outside the
/// card (masked container), so the translucent blur isn't darkened. The ambient shadow grows while the panel is key.
final class ShadowView: NSView {
    private let clip = CALayer(), cutout = CAShapeLayer(), contact = CALayer(), ambient = CALayer(), outline = CAShapeLayer()
    var card: NSRect = .zero { didSet { needsLayout = true } }
    var active = false { didSet { if active != oldValue { applyShadow(animated: true) } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [contact, ambient] { l.shadowColor = NSColor.black.cgColor; clip.addSublayer(l) }
        contact.shadowRadius = 2.5; contact.shadowOpacity = 0.35; contact.shadowOffset = CGSize(width: 0, height: -1)
        cutout.fillRule = .evenOdd
        clip.mask = cutout
        outline.fillColor = nil
        outline.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
        outline.lineWidth = 1
        layer?.addSublayer(clip)
        layer?.addSublayer(outline)
        applyShadow(animated: false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v === self ? nil : v          // the shadow never takes clicks itself
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shape = { (r: NSRect) in RoundedRectangle(cornerRadius: FloatingPanel.radius, style: .continuous).path(in: r).cgPath }
        let path = shape(card)
        for l in [clip, cutout, contact, ambient, outline] as [CALayer] { l.frame = bounds }
        contact.shadowPath = path
        ambient.shadowPath = path
        outline.path = path
        // cut out slightly inside the card edge so no light seam shows between card and shadow
        let m = CGMutablePath(); m.addRect(bounds); m.addPath(shape(card.insetBy(dx: 1, dy: 1)))
        cutout.path = m
        CATransaction.commit()
    }
    private func applyShadow(animated: Bool) {
        // ambient (radius, opacity, drop) — idle vs active
        let (r, o, y): (CGFloat, Float, CGFloat) = active ? (14, 0.55, 6) : (7, 0.22, 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            for (key, to) in [("shadowRadius", r as Any), ("shadowOpacity", o as Any), ("shadowOffset", CGSize(width: 0, height: -y) as Any)] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = ambient.presentation()?.value(forKey: key) ?? ambient.value(forKey: key)
                a.toValue = to
                a.duration = 0.25
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ambient.add(a, forKey: key)
            }
        }
        ambient.shadowRadius = r
        ambient.shadowOpacity = o
        ambient.shadowOffset = CGSize(width: 0, height: -y)
        CATransaction.commit()
    }
}

/// drag zones along the card's edges for resizing (the window edge is out in the shadow margin, so the system's
/// own resize edges would be in the wrong place)
final class ResizeEdges: NSView {
    var card: NSRect = .zero { didSet { window?.invalidateCursorRects(for: self); needsDisplay = true } }
    private let outside: CGFloat = 10, inside: CGFloat = 6     // generous grab band straddling the visible edge
    private var edges: (l: Bool, r: Bool, b: Bool, t: Bool) = (false, false, false, false)
    private var start: (mouse: NSPoint, frame: NSRect) = (.zero, .zero)
    private func zones(_ p: NSPoint) -> (l: Bool, r: Bool, b: Bool, t: Bool)? {
        let outer = card.insetBy(dx: -outside, dy: -outside), inner = card.insetBy(dx: inside, dy: inside)
        guard outer.contains(p), !inner.contains(p) else { return nil }
        let c: CGFloat = 24                               // corners grab both edges
        return (p.x < inner.minX || (p.x < card.minX + c && (p.y < inner.minY || p.y > inner.maxY)),
                p.x > inner.maxX || (p.x > card.maxX - c && (p.y < inner.minY || p.y > inner.maxY)),
                p.y < inner.minY || (p.y < card.minY + c && (p.x < inner.minX || p.x > inner.maxX)),
                p.y > inner.maxY || (p.y > card.maxY - c && (p.x < inner.minX || p.x > inner.maxX)))
    }
    // the window server sends clicks on fully transparent pixels to the window behind, so the grab band just outside
    // the card (where the shadow is near zero, mostly left/right) gets an invisible 1% fill to stay clickable
    override func draw(_ dirty: NSRect) {
        let ring = NSBezierPath(rect: card.insetBy(dx: -outside, dy: -outside))
        ring.append(NSBezierPath(rect: card))
        ring.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.01).setFill()
        ring.fill()
    }
    // a non-opaque view lets the window be dragged by it, which fought the resize (window shook / moved)
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let sp = superview else { return nil }
        return zones(convert(p, from: sp)) != nil ? self : nil
    }
    override func resetCursorRects() {
        let o = outside, i = inside
        addCursorRect(NSRect(x: card.minX - o, y: card.minY, width: o + i, height: card.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: card.maxX - i, y: card.minY, width: o + i, height: card.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: card.minX, y: card.minY - o, width: card.width, height: o + i), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: card.minX, y: card.maxY - i, width: card.width, height: o + i), cursor: .resizeUpDown)
    }
    override func mouseDown(with e: NSEvent) {
        edges = zones(convert(e.locationInWindow, from: nil)) ?? (false, false, false, false)
        start = (NSEvent.mouseLocation, window?.frame ?? .zero)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window else { return }
        let p = NSEvent.mouseLocation, dx = p.x - start.mouse.x, dy = p.y - start.mouse.y
        var f = start.frame
        let minW = w.minSize.width, minH = w.minSize.height
        if edges.r { f.size.width = max(minW, start.frame.width + dx) }
        if edges.l { let wdt = max(minW, start.frame.width - dx); f.origin.x = start.frame.maxX - wdt; f.size.width = wdt }
        if edges.t { f.size.height = max(minH, start.frame.height + dy) }
        if edges.b { let h = max(minH, start.frame.height - dy); f.origin.y = start.frame.maxY - h; f.size.height = h }
        w.setFrame(f, display: true)
    }
}

/// holds the card (blur + SwiftUI) inset by the shadow margin, the shadow behind it and the resize edges on top
final class PanelRoot: NSView {
    let shadowView = ShadowView(), card: HoverBlur, edges = ResizeEdges()
    init(card: HoverBlur) {
        self.card = card
        super.init(frame: .zero)
        for v in [shadowView, card, edges] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let m = FloatingPanel.margin
        let c = bounds.insetBy(dx: m, dy: m)
        card.frame = c
        shadowView.frame = bounds; shadowView.card = c
        edges.frame = bounds; edges.card = c
    }
}

final class FloatingPanel: NSPanel {
    static let radius: CGFloat = 24
    static let margin: CGFloat = 30                 // transparent room around the card for the shadow
    var onKey: ((NSEvent) -> Bool)?
    let root: PanelRoot
    var onHover: ((Bool) -> Void)? {
        get { root.card.onHover }
        set { root.card.onHover = newValue }
    }
    static let frameKey = "panelFrame"
    let frameKey: String?                           // the main window's frame is kept here; extra windows are saved by AppDelegate
    var onFrameChange: (() -> Void)?
    func rememberFrame() {
        if let k = frameKey { UserDefaults.standard.set(NSStringFromRect(frame), forKey: k) }
        onFrameChange?()
    }
    /// the visible card, in screen coordinates
    var cardFrame: NSRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }
    init(content: NSView, frameKey: String? = FloatingPanel.frameKey) {
        self.frameKey = frameKey
        let m = Self.margin
        // dark blur clipped to big rounded corners
        let blur = HoverBlur()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = FloatingPanel.roundedMask(FloatingPanel.radius)
        content.frame = blur.bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        root = PanelRoot(card: blur)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560 + 2 * m, height: 640 + 2 * m),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                               // ShadowView draws it (adjustable, bigger when active)
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 380 + 2 * m, height: 300 + 2 * m)
        contentView = root
        // frame kept by hand: AppKit's frame autosave restores only the position of a window without .resizable
        // (resizing here is done by ResizeEdges), so the size reset on every launch
        if let k = frameKey {
            let saved = UserDefaults.standard.string(forKey: k).map(NSRectFromString) ?? .zero
            if !restore(saved) && !setFrameUsingName("JotPanel3") { center() }    // JotPanel3: position from the older autosave
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rememberFrame() }
            }
        }
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.root.shadowView.active = key }
            }
        }
    }
    /// puts the window at a saved frame if it still fits on a screen
    @discardableResult func restore(_ saved: NSRect) -> Bool {
        guard saved.width >= minSize.width, saved.height >= minSize.height,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) else { return false }
        setFrame(saved, display: false)
        return true
    }
    /// squircle mask ("corner smoothing", like SwiftUI's .continuous / iOS icons). The smoothed curve reaches ~1.53 r
    /// from each edge, so the stretchable caps are 1.6 r.
    static func roundedMask(_ r: CGFloat) -> NSImage {
        let cap = (r * 1.6).rounded(.up)
        let edge = 2 * cap + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        img.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        img.resizingMode = .stretch
        return img
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // AppKit keeps the whole frame below the menu bar on every move, and the frame includes the transparent shadow
    // margin, so the card stopped `margin` short: only the card has to stay below it
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect {
        guard let s = screen else { return r }
        var f = r
        f.origin.y = min(f.origin.y, s.visibleFrame.maxY + Self.margin - f.height)
        return f
    }
    // the panel doesn't activate the app, so the app's menu never sees shortcuts: handle them here
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if onKey?(e) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
    var onCancel: (() -> Void)?                     // Esc nobody else took: hide (main) / close (extra window)
    override func cancelOperation(_ sender: Any?) { if let c = onCancel { c() } else { orderOut(nil) } }
    // a video playing over the note / on its thumbnail stops when its panel hides
    var onHidden: (() -> Void)?                     // the panel was hidden (AppDelegate saves which windows show)
    override func orderOut(_ sender: Any?) {
        if let v = MediaViewer.current, v.window === self { v.close() }
        if let v = InlineVideo.current, v.window === self { v.stop() }
        super.orderOut(sender)
        onHidden?()
    }
}

// MARK: - app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// a Jot window: its panel and the model of the note open in it
    final class Window { let panel: FloatingPanel, model: AppModel; init(_ p: FloatingPanel, _ m: AppModel) { panel = p; model = m } }
    let store: NotesStore
    let hotKey = HotKey()
    var windows: [Window] = []                      // [0] is the main window (hidden, never closed); the others are extras
    var lastKey: Window?                            // the window used last (⌥N focuses it, the graph opens notes in it)
    var main: Window { windows[0] }
    var model: AppModel { main.model }
    var panel: FloatingPanel { main.panel }
    var current: Window { lastKey ?? main }
    static let extrasKey = "extraWindows"            // [{note, frame, shown}] of the extra windows
    static let mainNoteKey = "mainNote", mainShownKey = "mainShown", keyWindowKey = "keyWindow"
    var restoring = true                             // launch: windows are being rebuilt, nothing is saved yet
    var terminating = false                          // quitting: windows hiding now must not be saved as hidden
    var graph: NSWindow?
    var status: NSStatusItem!
    var updateTimer: Timer?
    var updating = false
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }
    var choice: HotKey.Choice {
        let name = UserDefaults.standard.string(forKey: "hotkey") ?? HotKey.choices[0].name
        return HotKey.choices.first { $0.name == name } ?? HotKey.choices[0]
    }
    override init() { store = NotesStore(); super.init() }

    func applicationDidFinishLaunching(_ n: Notification) {
        // the windows as they were when Jot last ended: each with its note and frame, shown or hidden, the front one focused
        let d = UserDefaults.standard
        let extras = d.array(forKey: Self.extrasKey) as? [[String: String]] ?? []
        let saved = d.object(forKey: Self.mainShownKey) != nil         // nothing saved yet (first launch / before 1.97)
        var shown = [saved ? d.bool(forKey: Self.mainShownKey) : true] + extras.map { saved ? $0["shown"] == "1" : true }
        lastKey = makeWindow(AppModel(store: store, note: d.string(forKey: Self.mainNoteKey)), frameKey: FloatingPanel.frameKey)
        for e in extras {
            let w = makeWindow(AppModel(store: store, note: e["note"]), frameKey: nil)
            if !w.panel.restore(NSRectFromString(e["frame"] ?? "")) { cascade(w.panel) }
        }
        let k = d.integer(forKey: Self.keyWindowKey)
        if k > 0, k < windows.count { lastKey = windows[k] }
        store.onLock = { [weak self] in                 // extras hide while locked (their notes are kept); ⌥N brings them back after unlocking
            guard let self = self else { return }
            self.saveWindows()
            for w in self.windows.dropFirst() { w.panel.orderOut(nil) }
        }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Jot")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        hotKey.action = { [weak self] in self?.toggle() }
        if !UserDefaults.standard.bool(forKey: "hotkeyN") {     // 1.66: move everyone to the new default ⌥N once
            UserDefaults.standard.set("⌥ N", forKey: "hotkey")
            UserDefaults.standard.set(true, forKey: "hotkeyN")
        }
        if !hotKey.register(choice) { warnHotkey() }

        NotificationCenter.default.addObserver(forName: .jotShowPanel, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let w = self.current
                if let id = n.object as? String { w.model.open(id) }
                self.show(w)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.events.restart(); self?.store.syncSoon(2) }
        }
        if !store.unlocked { shown = [true] + shown.dropFirst().map { _ in false } }   // locked: just the unlock screen
        if !shown[windows.firstIndex { $0 === current } ?? 0] {          // the front window was hidden: focus a shown one
            lastKey = windows.indices.first { shown[$0] }.map { windows[$0] } ?? main
        }
        for (i, w) in windows.enumerated() where shown[i] && w !== current { w.panel.orderFront(nil) }
        if shown.contains(true) { show(current) }
        restoring = false
        saveWindows()
        if let f = UserDefaults.standard.string(forKey: "updateFailed"), !AppDelegate.newer(f, than: AppDelegate.version) {
            UserDefaults.standard.removeObject(forKey: "updateFailed")     // that version (or a later one) is installed now
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUpdate(manual: false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.checkUpdate(manual: false) }
    }
    func applicationWillTerminate(_ n: Notification) { panel.rememberFrame(); saveWindows(); terminating = true; commitAll(); store.repo.save() }

    // status menu, rebuilt each time it opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult func item(_ t: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.target = self; menu.addItem(i); return i
        }
        item("Show Jot   \(choice.name)", #selector(toggleMenu))
        item("New Note", #selector(newNoteMenu))
        item("New Window   ⌘⇧N", #selector(newWindowMenu))
        item("Graph", #selector(graphMenu))
        menu.addItem(.separator())
        let sub = NSMenu()
        for c in HotKey.choices {
            let i = NSMenuItem(title: c.name, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.name; i.state = c.name == choice.name ? .on : .off
            sub.addItem(i)
        }
        let hk = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: ""); hk.submenu = sub; menu.addItem(hk)
        let s: String
        switch store.sync { case .live: s = "Synced with \(AppModel.origin.host ?? "the server")"; case .syncing, .idle: s = "Syncing…"; case .offline(let w): s = "Offline: \(w.prefix(60))" }
        let st = NSMenuItem(title: s, action: nil, keyEquivalent: ""); st.isEnabled = false; menu.addItem(st)
        if store.unlocked { item("Lock Jot on this Mac…", #selector(lockMenu)) }
        menu.addItem(.separator())
        let v = NSMenuItem(title: updating ? "Updating Jot…" : "Jot \(AppDelegate.version)", action: nil, keyEquivalent: ""); v.isEnabled = false; menu.addItem(v)
        if let failed = UserDefaults.standard.string(forKey: "updateFailed") {
            let f = NSMenuItem(title: "Update to \(failed) failed: see ~/Library/Logs/Jot-update.log", action: nil, keyEquivalent: ""); f.isEnabled = false; menu.addItem(f)
        }
        item("Check for Updates…", #selector(checkMenu)).isEnabled = !updating
        item("Update Automatically", #selector(toggleAuto)).state = autoUpdate ? .on : .off
        menu.addItem(.separator())
        item("Quit Jot", #selector(quit), "q")
    }
    @objc func toggleMenu() { showAll() }
    @objc func newNoteMenu() { show(current); current.model.newNote() }
    @objc func newWindowMenu() { newWindow() }
    @objc func graphMenu() { showGraph() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func checkMenu() { checkUpdate(manual: true) }
    @objc func toggleAuto() { autoUpdate.toggle() }
    @objc func pickHotkey(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let c = HotKey.choices.first(where: { $0.name == name }) else { return }
        UserDefaults.standard.set(name, forKey: "hotkey")
        if !hotKey.register(c) { warnHotkey() }
    }
    @objc func lockMenu() {
        let a = NSAlert()
        a.messageText = "Lock Jot on this Mac?"
        a.informativeText = "Removes the key and the local copy of your notes from this Mac. Your notes stay on your other devices and the server; unlock again with your passphrase."
        a.addButton(withTitle: "Lock"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { store.lock(); show(main) }
    }
    func warnHotkey() {
        let a = NSAlert()
        a.messageText = "\(choice.name) is already used by another app"
        a.informativeText = "Pick another shortcut from the Jot menu-bar icon → Shortcut."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: updates (install.sh rebuilds from the published source, then restarts Jot through launchd)

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
    func checkUpdate(manual: Bool) {
        guard !updating, let url = URL(string: AppModel.origin.absoluteString + "/mac/version.txt") else { return }
        var r = URLRequest(url: url); r.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: r) { [weak self] d, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let v = ok ? d.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.gotVersion(v, manual: manual) } }
        }.resume()
    }
    private func gotVersion(_ v: String, manual: Bool) {
        if v.isEmpty { if manual { tell("Couldn't check for updates", "\(AppModel.origin.host ?? "The notes server") isn't reachable.") }; return }
        guard AppDelegate.newer(v, than: AppDelegate.version) else { if manual { tell("Jot is up to date", "You have version \(AppDelegate.version).") }; return }
        if !manual {
            if !autoUpdate || UserDefaults.standard.string(forKey: "updateFailed") == v { return }
            // don't restart while you're writing: try again in 10 minutes
            if windows.contains(where: { $0.panel.isVisible && $0.panel.isKeyWindow }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.checkUpdate(manual: false) }
                return
            }
        }
        runUpdate(v)
    }
    private func runUpdate(_ v: String) {
        updating = true
        saveWindows(); commitAll(); store.repo.save()
        let handed = Keychain.handOff()
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jot-update.log").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "echo \"== $(date) updating to \(v)\" >> '\(log)'; curl -fsSL \(AppModel.origin.absoluteString)/mac/install.sh | JOT_AUTO=1 bash >> '\(log)' 2>&1"]
        // on success install.sh restarts Jot (this process ends); still running here means it failed
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self = self else { return }
                if handed { Keychain.takeHandoff() }
                self.updating = false
                UserDefaults.standard.set(v, forKey: "updateFailed")
            } }
        }
        do { try p.run() } catch {
            if handed { Keychain.takeHandoff() }
            updating = false
        }
    }
    private func tell(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: windows

    @discardableResult func makeWindow(_ model: AppModel, frameKey: String?) -> Window {
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        let panel = FloatingPanel(content: host, frameKey: frameKey)
        let w = Window(panel, model)
        panel.onKey = { [weak self, weak w] e in w.map { self?.shortcut(e, in: $0) ?? false } ?? false }
        // Esc / the close button: the main window hides, an extra window closes for good
        model.onHide = { [weak self, weak panel, weak w] in
            if frameKey == nil, let w = w { self?.close(w) } else { panel?.orderOut(nil) }
        }
        panel.onCancel = { [weak model] in model?.commit(); model?.onHide?() }
        model.onGraph = { [weak self] in self?.showGraph() }
        panel.onHover = { [weak model] h in model?.panelHover = h }
        if frameKey == nil { panel.onFrameChange = { [weak self] in self?.saveWindows() } }
        model.onNoteChange = { [weak self] in self?.saveWindows() }
        panel.onHidden = { [weak self] in self?.saveWindows() }
        for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak w] _ in
                MainActor.assumeIsolated {
                    guard let w = w else { return }
                    let m = w.model
                    m.panelActive = key
                    if key { self?.lastKey = w; self?.saveWindows() }
                    if !key && m.showSwitcher {               // another window took focus: close the note search at once
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { m.showSwitcher = false }
                    }
                }
            }
        }
        windows.append(w)
        return w
    }
    /// ⌘⇧N: another window with a new note, a little down and right of the current one
    func newWindow() {
        guard store.unlocked else { show(main); return }
        let w = makeWindow(AppModel(store: store, fresh: true), frameKey: nil)
        cascade(w.panel)
        show(w)
    }
    func cascade(_ p: FloatingPanel) {
        let from = current.panel.frame
        p.setFrame(from, display: false)
        p.setFrameTopLeftPoint(NSPoint(x: from.minX + 30, y: from.maxY - 30))
    }
    /// ⌘W on an extra window: it goes for good (the main window only hides)
    func close(_ w: Window) {
        guard w !== main else { w.model.commit(); w.panel.orderOut(nil); return }
        w.model.commit()
        w.panel.orderOut(nil)
        windows.removeAll { $0 === w }
        if lastKey === w { lastKey = windows.last(where: { $0.panel.isVisible }) ?? main }
        saveWindows()
    }
    /// the windows for the next launch: main note + shown, extras (note, frame, shown), the front one. Saved on every
    /// change, since an auto-update restart (launchctl kickstart -k) ends Jot without applicationWillTerminate
    func saveWindows() {
        guard !restoring, !terminating, !windows.isEmpty else { return }
        let d = UserDefaults.standard
        let list = windows.dropFirst().map { ["note": $0.model.currentId, "frame": NSStringFromRect($0.panel.frame), "shown": $0.panel.isVisible ? "1" : "0"] }
        d.set(list, forKey: Self.extrasKey)
        if store.unlocked { d.set(main.model.currentId, forKey: Self.mainNoteKey) }
        d.set(main.panel.isVisible, forKey: Self.mainShownKey)
        d.set(windows.firstIndex { $0 === current } ?? 0, forKey: Self.keyWindowKey)
    }
    func commitAll() { for w in windows { w.model.commit() } }

    /// ⌥N: hide every window if Jot is in front, else bring them all back with the last-used one focused
    func toggle() {
        if windows.contains(where: { $0.panel.isVisible && $0.panel.isKeyWindow }) {
            commitAll()
            for w in windows { w.panel.orderOut(nil) }
        } else { showAll() }
    }
    func showAll() {
        let focus = store.unlocked ? current : main
        if store.unlocked { for w in windows where w !== focus { w.panel.orderFront(nil) } }
        show(focus)
    }
    func show(_ w: Window) {
        w.panel.makeKeyAndOrderFront(nil)
        saveWindows()
        w.model.panelHover = w.panel.cardFrame.contains(NSEvent.mouseLocation)   // no mouseEntered if it opens under the pointer
        NotificationCenter.default.post(name: .jotFocusEditor, object: w.panel)
    }
    func showGraph() {
        if graph == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Jot Graph"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: GraphView().environmentObject(model))
            w.center()
            w.setFrameAutosaveName("JotGraph")
            graph = w
        }
        NSApp.activate(ignoringOtherApps: true)
        graph?.makeKeyAndOrderFront(nil)
    }

    /// shortcuts while a Jot window is key; false = let the text field / view handle it
    func shortcut(_ e: NSEvent, in w: Window) -> Bool {
        guard e.type == .keyDown else { return false }
        let model = w.model, panel = w.panel
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let send = { (sel: String) -> Bool in NSApp.sendAction(Selector(sel), to: nil, from: self) }
        if mods == .command {
            switch key {
            case "x": return send("cut:")
            case "c": return send("copy:")
            case "v": return send("paste:")
            case "a": return send("selectAll:")
            case "z": panel.firstResponder?.undoManager?.undo(); return true
            case "n": guard model.unlocked else { return false }; model.newNote(); return true
            case "k", "f", "o": guard model.unlocked else { return false }; model.openSwitcher(); return true
            case "[": model.goBack(); return true
            case "]": model.goForward(); return true
            case "j": model.showConnections.toggle(); return true
            case "g": guard model.unlocked else { return false }; showGraph(); return true
            case "b": NotificationCenter.default.post(name: .jotFormat, object: "bold"); return true
            case "i": NotificationCenter.default.post(name: .jotFormat, object: "italic"); return true
            case "u": NotificationCenter.default.post(name: .jotFormat, object: "underline"); return true
            case "s": NotificationCenter.default.post(name: .jotFormat, object: "strike"); return true
            case "w": close(w); return true
            case "q": NSApp.terminate(nil); return true
            case "\u{7f}", "\u{8}": guard model.unlocked, model.repo.content(model.currentId) != nil else { return false }; model.confirmDelete = true; return true
            default: return false
            }
        }
        if mods == [.command, .shift] {
            switch key {
            case "z": panel.firstResponder?.undoManager?.redo(); return true
            case "n": newWindow(); return true
            case "p": model.togglePin(); return true
            case "r": model.toggleReading(); return true
            default: return false
            }
        }
        return false
    }
}
