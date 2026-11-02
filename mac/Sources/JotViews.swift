// Jot panel UI: unlock screen, editor + top/bottom bars, ⌘K switcher, connections sidebar, [[ autocomplete. macOS only.
import AppKit
import SwiftUI

struct Blur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// progressive blur of the window content behind it: strongest at the top edge, none at the bottom.
/// Uses Core Animation's backdrop layer + "variableBlur" filter (what system bars use; not public API) —
/// if either is missing it falls back to a plain material fading out the same way.
struct VariableBlur: NSViewRepresentable {
    var radius: CGFloat
    var fromTop = true                              // strongest at the top edge (false: at the bottom edge)
    func makeNSView(context: Context) -> NSView {
        if let v = BackdropBlurView(radius: radius, fromTop: fromTop) { return v }
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .withinWindow; v.state = .active
        v.alphaValue = 0.15                        // material blur is strong; only a hint of it
        v.maskImage = NSImage(size: NSSize(width: 1, height: 64), flipped: true) { r in
            NSGradient(starting: .black, ending: .clear)?.draw(in: r, angle: fromTop ? 90 : -90); return true
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

final class BackdropBlurView: NSView {
    init?(radius: CGFloat, fromTop: Bool) {
        guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              filterType.responds(to: NSSelectorFromString("filterWithType:")),
              let filter = filterType.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        super.init(frame: .zero)
        // mask: opaque (full blur) at the top row, transparent (no blur) at the bottom
        let h = 64
        guard let ctx = CGContext(data: nil, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        for y in 0..<h {                       // CG rows count up from the bottom, so row h-1 is the top
            let t = fromTop ? CGFloat(y) / CGFloat(h - 1) : 1 - CGFloat(y) / CGFloat(h - 1)
            ctx.setFillColor(gray: 0, alpha: t * t * (3 - 2 * t))
            ctx.fill(CGRect(x: 0, y: y, width: 1, height: 1))
        }
        guard let mask = ctx.makeImage() else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        let backdrop = layerType.init()
        backdrop.filters = [filter]
        layer = backdrop
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

/// light progressive blur + dark fade along the top or bottom window edge (content scrolls under it)
struct EdgeShade: View {
    let top: Bool
    var body: some View {
        ZStack {
            VariableBlur(radius: 1.5, fromTop: top)
            LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top)
        }
        .frame(height: TopBar.height + 14)                          // fades out a little past the bar
        .allowsHitTesting(false)
    }
}

/// empty top-bar space drags the window (the content under it would otherwise get the click). Own drag loop instead
/// of performDrag: the system drag keeps the window (with its 30 pt shadow margin) well below the menu bar, and
/// first mouse lets an inactive panel be dragged straight away
/// turns off rubber-banding on the enclosing scroll view (scrolling past the top made the ⌘K list jitter)
struct NoBounce: NSViewRepresentable {
    final class V: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.enclosingScrollView?.verticalScrollElasticity = .none }
            }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct WindowDragArea: NSViewRepresentable {
    final class V: NSView {
        override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            w.makeKey()
            let start = NSEvent.mouseLocation, origin = w.frame.origin
            while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), ev.type == .leftMouseDragged {
                let p = NSEvent.mouseLocation
                var o = NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)
                // only the top is limited: the card may go up to the menu bar (the screen top when it auto-hides)
                if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? w.screen {
                    o.y = min(o.y, s.visibleFrame.maxY + FloatingPanel.margin - w.frame.height)
                }
                w.setFrameOrigin(o)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()          // darker than the plain blur (the panel's NSVisualEffectView)
            if model.unlocked { MainView() } else { UnlockView() }
        }
        .clipShape(RoundedRectangle(cornerRadius: FloatingPanel.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FloatingPanel.radius, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .frame(minWidth: 380, minHeight: 300)
    }
}

// MARK: - unlock

struct UnlockView: View {
    @EnvironmentObject var model: AppModel
    @State private var pass = ""
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil").font(.system(size: 34, weight: .semibold)).foregroundStyle(.tint)
            Text("Jot").font(.system(size: 26, weight: .bold))
            Text("Enter your Jot passphrase. The first device you unlock creates it. It encrypts your notes before they leave this Mac and **can't be recovered**.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            SecureField("Passphrase", text: $pass).textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { model.unlock(passphrase: pass) }
            Button(model.busy ? "Unlocking…" : "Unlock") { model.unlock(passphrase: pass) }
                .keyboardShortcut(.defaultAction).disabled(model.busy || pass.isEmpty)
            if let e = model.unlockError { Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 320) }
        }
        .padding(30)
    }
}

// MARK: - main

struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                EditorView(model: model)
                if model.showConnections {
                    Divider().opacity(0.4)
                    ConnectionsView().frame(width: 230)
                }
            }
            .mask {      // content fades out as it scrolls under the bar to the top edge, and to the bottom edge
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: TopBar.height)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: TopBar.height)
                }
            }
            TopBar()       // floats over the content, which scrolls up under it to the window edge
            let showFormat = model.autocomplete.isEmpty
            FormatBar(muted: !model.panelActive)          // always there; icons muted while another window is active
                .padding(.bottom, 14).frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(showFormat ? 1 : 0).allowsHitTesting(showFormat)
                .animation(.easeOut(duration: 0.15), value: showFormat)
                .animation(.easeOut(duration: 0.2), value: model.panelActive)
            if !model.autocomplete.isEmpty {
                AutocompleteList().padding(10).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .overlay {
            if model.showSwitcher {
                SwitcherView().transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: model.showSwitcher)
        // ⌘⌫: confirmation card in the panel (SwiftUI alerts don't show on this borderless panel)
        .overlay {
            if model.confirmDelete {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.confirmDelete = false }
                    VStack(spacing: 10) {
                        Text("Delete this note?").font(.system(size: 14, weight: .semibold))
                        Text("It's removed from all your devices.").font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Cancel") { model.confirmDelete = false }.buttonStyle(.plain)
                                .frame(width: 90, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                            Button("Delete") { model.confirmDelete = false; model.deleteCurrent() }.buttonStyle(.plain)
                                .foregroundStyle(.white).font(.system(size: 13, weight: .semibold))
                                .frame(width: 90, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.85)))
                        }
                        .padding(.top, 4)
                    }
                    .padding(18)
                    .modifier(GlassPanel(radius: 14))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.confirmDelete)
        // "Adding image…" / upload errors, under the top bar; a click hides it
        .overlay(alignment: .top) {
            if let n = model.notice {
                Text(n).font(.system(size: 12, weight: .medium)).lineLimit(3).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .modifier(GlassPanel(radius: 10))
                    .padding(.top, TopBar.height + 2).padding(.horizontal, 20)
                    .onTapGesture { model.tell(nil) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.notice)
    }
}

/// floating formatting pill at the bottom of the window (shown on hover); actions go to the editor (Coordinator.format)
struct FormatBar: View {
    var muted = false
    func act(_ a: String) { NotificationCenter.default.post(name: .jotFormat, object: a) }
    var body: some View {
        HStack(spacing: 2) {
            FormatMenu(label: AnyView(Text("H").font(.system(size: 14, weight: .bold))), help: "Heading", items: [
                ("Heading 1", "h1"), ("Heading 2", "h2"), ("Heading 3", "h3")], act: act)
            FormatMenu(label: AnyView(Image(systemName: "textformat")), help: "Format", items: [
                ("Bold  ⌘B", "bold"), ("Italic  ⌘I", "italic"), ("Strikethrough  ⌘S", "strike"), ("Underline  ⌘U", "underline")], act: act)
            divider
            FormatButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Code") { act("code") }
            FormatButton(symbol: "curlybraces", help: "Code block") { act("codeblock") }
            FormatButton(symbol: "text.quote", help: "Blockquote") { act("quote") }
            divider
            FormatMenu(label: AnyView(Image(systemName: "list.bullet")), help: "List", items: [
                ("Ordered List", "ol"), ("Bullet List", "ul"), ("Task List", "task")], act: act)
        }
        .opacity(muted ? 0.4 : 1)                         // only the icons; the blurred pill stays as is
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
    var divider: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 3) }
}

struct FormatButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(hover ? .primary : .secondary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

/// a bar button that pops up a menu of format actions just above itself
struct FormatMenu: View {
    let label: AnyView
    let help: String
    let items: [(String, String)]
    let act: (String) -> Void
    @State private var hover = false
    var body: some View {
        Button { popUp() } label: {
            HStack(spacing: 3) {
                label.font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(hover ? .primary : .secondary)
            .frame(height: 26).padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
    func popUp() {
        let menu = NSMenu()
        let targets = items.map { item in MenuTarget { act(item.1) } }
        for (item, t) in zip(items, targets) {
            let mi = NSMenuItem(title: item.0, action: #selector(MenuTarget.run), keyEquivalent: "")
            mi.target = t
            menu.addItem(mi)
        }
        let p = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: p.x - 12, y: p.y + 14), in: nil)   // blocks until closed
        withExtendedLifetime(targets) {}
    }
}

final class MenuTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func run() { f() }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var on = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 32, height: 30)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(hover ? .primary : .secondary))
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.16 : 0.09)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

/// the macOS close button (the panel is borderless, so it draws its own): gray, red with × when hovered. Hides the panel.
struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(hover ? Color(red: 1, green: 0.37, blue: 0.34) : Color.white.opacity(0.22))
                Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                if hover { Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(Color.black.opacity(0.55)) }
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help("Close  ⌘W")
    }
}

/// just the note title; while the mouse is over the panel (even when another window is active), the close button on the left and new / all notes / graph on the right
struct TopBar: View {
    static let height: CGFloat = 54
    @EnvironmentObject var model: AppModel
    var body: some View {
        let controls = model.panelHover
        let title = Logic.title(model.text)
        ZStack {
            Text(title.isEmpty ? "New note" : title)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(title.isEmpty ? .tertiary : .secondary)
                .padding(.horizontal, 124)
            WindowDragArea()                                        // above the title, below the buttons
            HStack(spacing: 6) {
                CloseButton { model.commit(); model.onHide?() }.padding(.leading, 8)
                Spacer(minLength: 0)
                IconButton(symbol: "circle.hexagongrid", help: "Graph  ⌘G") { model.onGraph?() }
                IconButton(symbol: "rectangle.stack", help: "All notes  ⌘K") { model.openSwitcher() }
                IconButton(symbol: "plus", help: "New note  ⌘N") { model.newNote() }
            }
            .opacity(controls ? 1 : 0).allowsHitTesting(controls)
        }
        .padding(.horizontal, 14).padding(.top, 6).frame(height: TopBar.height)
        .background { EdgeShade(top: true).frame(maxHeight: .infinity, alignment: .top) }
        .animation(.easeOut(duration: 0.15), value: controls)
    }
}

// MARK: - [[ autocomplete

struct AutocompleteList: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.autocomplete.enumerated()), id: \.offset) { i, t in
                HStack {
                    Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(t).lineLimit(1)
                    Spacer()
                    if i == model.acSel { Text("↩").foregroundStyle(.tertiary) }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(i == model.acSel ? Color.accentColor.opacity(0.25) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.acSel = i; NotificationCenter.default.post(name: .jotAcceptLink, object: t) }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial).shadow(radius: 8, y: 2))
        .frame(maxWidth: 360)
    }
}

// MARK: - ⌘K switcher

/// NSTextField that reports ↑ ↓ ↩ ⌘↩ Esc (SwiftUI's TextField can't on macOS 13)
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommand: (String) -> Void       // "up", "down", "enter", "cmdEnter", "esc"

    func makeCoordinator() -> C { MainActor.assumeIsolated { C(self) } }
    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: 17)
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        MainActor.assumeIsolated { context.coordinator.parent = self }
        if f.stringValue != text { f.stringValue = text }
    }
    final class C: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        init(_ p: CommandField) { parent = p }
        func controlTextDidChange(_ n: Notification) { if let f = n.object as? NSTextField { parent.text = f.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onCommand("up"); return true
            case #selector(NSResponder.moveDown(_:)): parent.onCommand("down"); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommand(NSApp.currentEvent?.modifierFlags.contains(.command) == true ? "cmdEnter" : "enter"); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCommand("esc"); return true
            default: return false
            }
        }
    }
}

/// ⌘K: search notes (titles and text) in a small glass panel; pin / delete from the list
struct SwitcherView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete: String?           // row asking "Delete?" (alerts don't show on the borderless panel)
    var body: some View {
        let rows = model.switcherRows()
        // section titles (Pinned / Reading List & Ideas / Notes) where the section changes; only without a search,
        // and not when everything is a plain note
        let grouped = model.query.trimmingCharacters(in: .whitespaces).isEmpty && rows.contains { $0.section < 2 }
        let titleAt = grouped ? rows.indices.filter { $0 == 0 || rows[$0].section != rows[$0 - 1].section } : []
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { model.showSwitcher = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    CommandField(text: $model.query, placeholder: "Search notes") { cmd in
                        switch cmd {
                        case "up": model.switcherSel = max(0, model.switcherSel - 1)
                        case "down": model.switcherSel = min(max(rows.count - 1, 0), model.switcherSel + 1)
                        case "enter", "cmdEnter": if model.switcherSel < rows.count { model.open(rows[model.switcherSel].id) }
                        default: model.showSwitcher = false
                        }
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {         // not lazy: estimated row heights jittered on overscroll
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                if titleAt.contains(i) { SectionTitle(NoteRow.sections[r.section]) }
                                SwitcherRow(row: r, opened: model.opened[r.id], current: r.id == model.currentId, selected: i == model.switcherSel,
                                            confirming: confirmDelete == r.id,
                                            pin: { model.togglePin(r.id) }, reading: { model.toggleReading(r.id) }, delete: { confirmDelete = r.id },
                                            confirm: { confirmDelete = nil; model.deleteNote(r.id) }, cancel: { confirmDelete = nil })
                                    .id(i)
                                    .onTapGesture { if confirmDelete != r.id { model.open(r.id) } }
                            }
                            if rows.isEmpty {
                                Text(model.query.isEmpty ? "No notes yet" : "No matching notes")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                            }
                        }
                        .padding(5)
                        .background(NoBounce())
                    }
                    .frame(maxHeight: .infinity, alignment: .top)                  // reaches down to the bottom of the window
                    .onChange(of: model.switcherSel) { i in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i) } }
                    .onChange(of: model.query) { _ in model.switcherSel = 0 }
                }
            }
            .frame(maxWidth: 360)
            .modifier(GlassPanel(radius: 14))
            .padding(.horizontal, 20).padding(.top, 96).padding(.bottom, 20)
        }
    }
}

/// translucent "liquid glass" panel: the system Liquid Glass on macOS 26+, else a thin blurred material with a
/// light rim and sheen
struct GlassPanel: ViewModifier {
    let radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            fallback(content, shape)
        }
        #else
        fallback(content, shape)
        #endif
    }
    func fallback(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(shape.fill(.ultraThinMaterial))
            .background(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// a note in the switcher: blue dot = the open note, title with when it was last opened beneath, pin / delete
struct SwitcherRow: View {
    let row: NoteRow
    let opened: Double?
    let current: Bool
    let selected: Bool
    var confirming = false
    let pin: () -> Void
    let reading: () -> Void
    let delete: () -> Void
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}
    @State private var hover = false
    var body: some View {
        if confirming { confirmBody } else { normalBody }
    }
    /// inline "Delete?" with Cancel / Delete (red)
    var confirmBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Delete “\(row.title.isEmpty ? "Untitled" : row.title)”?").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text("Removed from all your devices").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Button("Cancel", action: cancel).buttonStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            Button("Delete", action: confirm).buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.85)))
        }
        .padding(.horizontal, 10).frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.12)))
        .contentShape(Rectangle())
    }
    var normalBody: some View {
        HStack(spacing: 8) {
            Circle().fill(current ? Color.accentColor : .clear).frame(width: 6, height: 6).padding(.trailing, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title.isEmpty ? "Untitled" : row.title)
                    .font(.system(size: 13, weight: current ? .semibold : .regular)).lineLimit(1)
                Text(Self.when(opened ?? Double(row.updated) / 1000)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            RowAction(symbol: row.reading ? "books.vertical.fill" : "books.vertical",
                      help: row.reading ? "Remove from Reading List & Ideas" : "Move to Reading List & Ideas", on: row.reading, action: reading)
            RowAction(symbol: row.pinned ? "pin.fill" : "pin", help: row.pinned ? "Unpin" : "Pin", on: row.pinned, action: pin)
            RowAction(symbol: "trash", help: "Delete", action: delete)
        }
        .padding(.horizontal, 10).frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hover ? Color.white.opacity(0.05) : .clear))         // only hover; no selected-row highlight
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button(row.pinned ? "Unpin" : "Pin", action: pin)
            Button(row.reading ? "Remove from Reading List & Ideas" : "Move to Reading List & Ideas", action: reading)
            Button("Delete…", role: .destructive, action: delete)
        }
    }
    static func when(_ secs: Double) -> String {
        let d = Date(timeIntervalSince1970: secs), cal = Calendar.current
        if cal.isDateInToday(d) { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }
}

struct RowAction: View {
    let symbol: String
    let help: String
    var on = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

struct SectionTitle: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }
}

struct NoteRowView: View {
    let row: NoteRow
    var selected = false
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if row.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tint) }
                Text(row.title).font(.system(size: compact ? 12 : 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if !compact { Text(Self.when(row.updated)).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            if !row.snippet.isEmpty {
                Text(row.snippet).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, compact ? 5 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
    }
    static func when(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }
}

// MARK: - connections sidebar

struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let out = model.outgoing, back = model.backlinkRows, men = model.mentionRows, rel = model.relatedRows, tags = model.currentTags
                if !out.isEmpty {
                    SectionTitle("Links")
                    ForEach(Array(out.enumerated()), id: \.offset) { _, l in
                        HStack(spacing: 6) {
                            Image(systemName: l.id == nil ? "plus.circle" : "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(l.name).font(.system(size: 12)).lineLimit(1).foregroundStyle(l.id == nil ? .secondary : .primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4).contentShape(Rectangle())
                        .onTapGesture { model.openLink(l.name) }
                        .help(l.id == nil ? "Not created yet: click to create it" : "Open")
                    }
                }
                SectionTitle("Backlinks")
                if back.isEmpty { Empty("No notes link here yet. Type [[ in another note.") }
                ForEach(back) { r in NoteRowView(row: r, compact: true).onTapGesture { model.open(r.id) } }
                if !men.isEmpty {
                    SectionTitle("Mentioned in")
                    ForEach(men) { r in NoteRowView(row: r, compact: true).onTapGesture { model.open(r.id) } }
                }
                SectionTitle("Related")
                if rel.isEmpty { Empty("Nothing similar yet.") }
                ForEach(rel) { r in NoteRowView(row: r, compact: true).onTapGesture { model.open(r.id) } }
                if !tags.isEmpty {
                    SectionTitle("Tags")
                    FlowTags(tags: tags) { model.openSwitcher("#" + $0) }.padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: TopBar.height) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: TopBar.height) }
    }
}
struct Empty: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 3) }
}
struct FlowTags: View {
    let tags: [String]
    let tap: (String) -> Void
    var body: some View {
        // simple wrapping: rows of up to 3
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: tags.count, by: 3)), id: \.self) { i in
                HStack(spacing: 4) {
                    ForEach(tags[i..<min(i + 3, tags.count)], id: \.self) { t in
                        Text("#" + t).font(.system(size: 11)).foregroundStyle(Color.purple)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.purple.opacity(0.13)))
                            .onTapGesture { tap(t) }
                    }
                }
            }
        }
    }
}

extension Notification.Name { static let jotAcceptLink = Notification.Name("jotAcceptLink") }
