// Jot media: images / videos in notes (`![alt](jot-media:<id>)` on a line of its own, see Media in JotCore).
// Thumbnails are fetched sealed, kept sealed on disk and opened in memory only; a click opens MediaViewer;
// pasted / dropped images are downscaled to JPEG, sealed and uploaded (MediaImport). macOS only.
import AppKit
import AVKit
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

extension Style {
    static let mediaHeight: CGFloat = 160            // thumbnail height in the note
    static let mediaMaxWidth: CGFloat = 320
    static let mediaRadius: CGFloat = 10
    static let mediaGap: CGFloat = 8                 // room above the media line = mediaHeight + mediaGap (4 above, 4 below)
}

extension NSAttributedString.Key {
    static let jotMedia = NSAttributedString.Key("jotMedia")      // a media line's text (from "!"); value = MediaAttr
}

extension Notification.Name {
    static let jotMediaLoaded = Notification.Name("jotMediaLoaded")   // object: the media id whose thumbnail arrived (or failed)
}

/// the media a line shows (value of .jotMedia)
final class MediaAttr: NSObject {
    let id: String
    let video: Bool
    let duration: String
    init(_ m: Media.Item) { id = m.id; video = m.kind == "video"; duration = m.duration }
}

/// where JotLayoutManager last drew a thumbnail (view coordinates): `rect` = the picture, `area` = all the room it may take
struct MediaHit { let rect: NSRect; let area: NSRect; let media: MediaAttr }

/// thumbnails: GET the sealed "thumb" part, keep it sealed in ~/Library/Caches/app.jot.mac/media, open in memory.
/// Main thread only (like Highlighter); loads run in the background and post .jotMediaLoaded.
final class MediaStore {
    static let shared = MediaStore()
    enum Thumb { case loading, ready(NSImage), failed }
    private(set) var api: JotAPI?
    private(set) var key: SymmetricKey?
    private var images: [String: NSImage] = [:], order: [String] = []
    private var failed: [String: Date] = [:]          // tried again after 30 s
    private var loading: Set<String> = []
    static var dir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.jot.mac/media") }
    /// videos being played (decrypted): deleted when the viewer closes, and at launch in case Jot quit meanwhile
    static var playDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.jot.mac/play") }

    init() { try? FileManager.default.removeItem(at: MediaStore.playDir) }

    func use(api: JotAPI, key: SymmetricKey?) {
        if key == nil && self.key != nil { images = [:]; order = []; failed = [:] }
        self.api = api; self.key = key
    }
    /// Lock: forget everything, including the (sealed) disk cache
    func clear() {
        images = [:]; order = []; failed = [:]; key = nil
        try? FileManager.default.removeItem(at: MediaStore.dir)
        try? FileManager.default.removeItem(at: MediaStore.playDir)
    }
    func image(_ id: String) -> NSImage? { images[id] }

    func thumb(_ id: String) -> Thumb {
        if let i = images[id] { return .ready(i) }
        if let t = failed[id], Date().timeIntervalSince(t) < 30 { return .failed }
        load(id)
        return failed[id] != nil ? .failed : .loading          // keep showing "unavailable" while it retries
    }
    /// a thumbnail this Mac just made and uploaded: no need to download it again
    func remember(_ id: String, sealedThumb: Data, image: NSImage) {
        try? FileManager.default.createDirectory(at: MediaStore.dir, withIntermediateDirectories: true)
        try? sealedThumb.write(to: MediaStore.dir.appendingPathComponent(id + ".thumb"), options: .atomic)
        put(id, image)
    }
    private func put(_ id: String, _ img: NSImage) {
        if images[id] == nil { order.append(id) }
        images[id] = img
        if order.count > 64 { images[order.removeFirst()] = nil }
    }

    private func load(_ id: String) {
        guard !loading.contains(id), let api = api, let key = key else { return }
        loading.insert(id)
        let file = MediaStore.dir.appendingPathComponent(id + ".thumb")
        Task {
            var img: NSImage?
            if let cached = try? Data(contentsOf: file) {
                if let d = try? JotCrypto.openMedia(key, id: id, part: "thumb", cached) { img = NSImage(data: d) }
                else { try? FileManager.default.removeItem(at: file) }      // damaged: fetch it again
            }
            if img == nil, let sealed = try? await api.getMedia(id, part: "thumb"),
               let d = try? JotCrypto.openMedia(key, id: id, part: "thumb", sealed), let i = NSImage(data: d) {
                try? FileManager.default.createDirectory(at: MediaStore.dir, withIntermediateDirectories: true)
                try? sealed.write(to: file, options: .atomic)               // still sealed on disk
                img = i
            }
            let result = img
            DispatchQueue.main.async { self.loaded(id, result) }
        }
    }
    private func loaded(_ id: String, _ img: NSImage?) {
        loading.remove(id)
        if let i = img { failed[id] = nil; put(id, i) } else { failed[id] = Date() }
        NotificationCenter.default.post(name: .jotMediaLoaded, object: id)
    }

    // MARK: drawing (JotLayoutManager.drawBackground)

    /// draws the media line's thumbnail with its top-left at `at`; returns the picture's rect
    /// where the thumbnail goes (top-left at `at`): aspect-fit, 160 high unless too wide; placeholder size until it's loaded
    static func frame(_ m: MediaAttr, at: NSPoint, maxWidth: CGFloat) -> NSRect {
        let maxW = min(Style.mediaMaxWidth, max(40, maxWidth)), h = Style.mediaHeight
        var rect = NSRect(x: at.x, y: at.y, width: min(maxW, 240), height: h)
        if let img = MediaStore.shared.image(m.id), img.size.width > 0, img.size.height > 0 {
            let s = min(h / img.size.height, maxW / img.size.width)
            rect.size = NSSize(width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        }
        return rect
    }
    static func draw(_ m: MediaAttr, at: NSPoint, maxWidth: CGFloat) -> NSRect {
        let state = MediaStore.shared.thumb(m.id)
        let rect = frame(m, at: at, maxWidth: maxWidth)
        let shape = NSBezierPath(roundedRect: rect, xRadius: Style.mediaRadius, yRadius: Style.mediaRadius)
        switch state {
        case .ready(let img):
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.08).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Style.mediaRadius, yRadius: Style.mediaRadius)
            edge.lineWidth = 1; edge.stroke()
        case .loading:
            NSColor.white.withAlphaComponent(0.06).setFill(); shape.fill()
        case .failed:
            NSColor.white.withAlphaComponent(0.06).setFill(); shape.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor]
            let t = (m.video ? "video unavailable" : "image unavailable") as NSString, sz = t.size(withAttributes: attrs)
            t.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
        }
        var failed = false
        if case .failed = state { failed = true }
        if m.video && !failed {
            // ▶ in a dark circle, duration pill bottom-right
            let d: CGFloat = 44
            let circle = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let tri = NSBezierPath()                     // view is flipped: y grows downwards
            tri.move(to: NSPoint(x: circle.midX - 6, y: circle.midY - 9))
            tri.line(to: NSPoint(x: circle.midX - 6, y: circle.midY + 9))
            tri.line(to: NSPoint(x: circle.midX + 10, y: circle.midY))
            tri.close()
            NSColor.white.setFill(); tri.fill()
            if !m.duration.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white]
                let sz = (m.duration as NSString).size(withAttributes: attrs)
                let pill = NSRect(x: rect.maxX - sz.width - 18, y: rect.maxY - sz.height - 12, width: sz.width + 10, height: sz.height + 4)
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                (m.duration as NSString).draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 2), withAttributes: attrs)
            }
        }
        return rect
    }
}

// MARK: - paste / drop

/// images coming in by paste or drag: downscaled + re-encoded as JPEG (full ≤ 2048 px q 0.85, thumb ≤ 640 px q 0.75)
enum MediaImport {
    struct Encoded { let full: Data; let thumb: Data }

    static func isImageFile(_ u: URL) -> Bool { UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true }
    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    /// text on the pasteboard that isn't just a link (a copied image often comes with its URL; spreadsheet cells
    /// come with a picture of themselves, and those stay text)
    static func hasText(_ pb: NSPasteboard) -> Bool {
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
        return !(s.hasPrefix("http") && !s.contains(where: { $0.isWhitespace }))
    }
    /// cheap check while dragging
    static func hasImage(_ pb: NSPasteboard) -> Bool {
        let urls = fileURLs(pb)
        if !urls.isEmpty { return urls.contains(where: isImageFile) }
        return !hasText(pb) && NSImage.canInit(with: pb)
    }
    /// the image files / image data on the pasteboard, or nil if it should be handled as before (text, other files)
    static func images(_ pb: NSPasteboard) -> [Data]? {
        let urls = fileURLs(pb)
        if !urls.isEmpty {
            let imgs = urls.filter(isImageFile).compactMap { try? Data(contentsOf: $0) }
            return imgs.isEmpty ? nil : imgs
        }
        if hasText(pb) { return nil }
        for t in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let d = pb.data(forType: t) { return [d] }
        }
        if NSImage.canInit(with: pb), let img = NSImage(pasteboard: pb), let d = img.tiffRepresentation { return [d] }
        return nil
    }

    static func encode(_ data: Data) -> Encoded? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let full = jpeg(src, maxPixels: 2048, quality: 0.85), let thumb = jpeg(src, maxPixels: 640, quality: 0.75) else { return nil }
        return Encoded(full: full, thumb: thumb)
    }
    /// first frame, EXIF rotation applied, at most maxPixels on the long side, flattened onto white (JPEG has no alpha), sRGB
    static func jpeg(_ src: CGImageSource, maxPixels: Int, quality: Double) -> Data? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(r)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: r)
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

// MARK: - viewer

/// a note's image / video full size (click on its thumbnail), shown INSIDE the notes panel: a dark layer over the card
/// with the same rounded corners. ✕, Esc or a click on the dark background closes it. The full part is downloaded sealed
/// and opened in memory; a video is written decrypted to a temporary file (caches, 0600) only while it plays.
final class MediaViewer: NSView {
    static var current: MediaViewer?
    private enum Loaded { case image(Data), video(URL), failed(String) }
    private let media: MediaAttr
    private weak var returnTo: NSResponder?
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    private var monitor: Any?
    private var tempFile: URL?
    private var playerView: AVPlayerView?
    private let imageView = NSImageView()
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private static let pad: CGFloat = 14

    static func open(_ m: MediaAttr, from: NSWindow?) {
        current?.close()
        guard let w = from, let host = (w.contentView as? PanelRoot)?.card ?? w.contentView else { return }
        let v = MediaViewer(m, returnTo: w.firstResponder)
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        v.alphaValue = 0
        host.addSubview(v)
        current = v
        w.makeKey()
        w.makeFirstResponder(v)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; v.animator().alphaValue = 1 }
        v.start()
    }

    private init(_ m: MediaAttr, returnTo: NSResponder?) {
        media = m
        self.returnTo = returnTo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.96).cgColor
        layer?.cornerRadius = FloatingPanel.radius
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = MediaStore.shared.image(m.id)
        imageView.alphaValue = m.video ? 0.35 : 1
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        addSubview(imageView)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 100
        addSubview(bar)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        addSubview(label)
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        closeButton.contentTintColor = NSColor(white: 1, alpha: 0.75)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }                    // Esc
            let mine = MainActor.assumeIsolated { () -> Bool in
                guard let s = self, e.window === s.window else { return false }
                s.close()
                return true
            }
            return mine ? nil : e
        }
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let p = MediaViewer.pad, b = bounds
        closeButton.frame = NSRect(x: 10, y: 10, width: 28, height: 28)
        let content = NSRect(x: p, y: 44, width: b.width - 2 * p, height: b.height - 44 - p)
        imageView.frame = content
        playerView?.frame = content
        bar.frame = NSRect(x: b.midX - 110, y: b.midY + 14, width: 220, height: 12)
        label.frame = NSRect(x: p, y: b.midY - 10, width: b.width - 2 * p, height: 18)
    }

    // a click on the dark background (not on the picture / player) closes
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if media.video, playerView != nil, imageView.frame.contains(p) { return }
        if !media.video, let img = imageView.image, fitted(img.size, in: imageView.frame).contains(p) { return }
        close()
    }
    private func fitted(_ s: NSSize, in r: NSRect) -> NSRect {
        guard s.width > 0, s.height > 0 else { return r }
        let k = min(r.width / s.width, r.height / s.height)
        let w = s.width * k, h = s.height * k
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    @objc private func closeClicked() { close() }

    private func start() {
        guard let api = MediaStore.shared.api, let key = MediaStore.shared.key else { show(.failed("Jot is locked")); return }
        label.stringValue = media.video ? "Downloading video…" : ""
        let id = media.id, video = media.video
        let task = api.session.downloadTask(with: api.request("GET", "/api/media/\(id)?part=full")) { [weak self] url, resp, err in
            // runs in the background; the downloaded (sealed) file is gone after this returns
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var r = Loaded.failed(err.map { $0.localizedDescription } ?? (code == 404 ? "Not on the server" : "Download failed (\(code))"))
            if err == nil, code == 200, let u = url, let sealed = try? Data(contentsOf: u) {
                if let plain = try? JotCrypto.openMedia(key, id: id, part: "full", sealed) {
                    if !video { r = .image(plain) }
                    else if let f = MediaViewer.writeTemp(plain) { r = .video(f) }
                    else { r = .failed("Couldn't write the video") }
                } else { r = .failed("Couldn't decrypt it") }
            }
            let result = r
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let s = self, s.superview != nil { s.show(result) } else if case .video(let f) = result { try? FileManager.default.removeItem(at: f) }
                }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bar.doubleValue = f * 100 } }
        }
        download = task
        task.resume()
    }

    /// decrypted video → a private temporary file (extension from the container, so AVFoundation knows it)
    nonisolated static func writeTemp(_ d: Data) -> URL? {
        let head = [UInt8](d.prefix(12))
        let mov = head.count == 12 && String(decoding: head[4..<8], as: UTF8.self) == "ftyp" && String(decoding: head[8..<12], as: UTF8.self) == "qt  "
        try? FileManager.default.createDirectory(at: MediaStore.playDir, withIntermediateDirectories: true)
        let f = MediaStore.playDir.appendingPathComponent(UUID().uuidString + (mov ? ".mov" : ".mp4"))
        return FileManager.default.createFile(atPath: f.path, contents: d, attributes: [.posixPermissions: 0o600]) ? f : nil
    }

    private func show(_ r: Loaded) {
        bar.isHidden = true
        progress = nil
        switch r {
        case .failed(let msg):
            label.stringValue = (media.video ? "Video unavailable" : "Image unavailable") + " · " + msg
        case .image(let d):
            guard let img = NSImage(data: d) else { label.stringValue = "Image unavailable"; return }
            label.isHidden = true
            imageView.image = img
            imageView.alphaValue = 1
        case .video(let f):
            tempFile = f
            label.isHidden = true
            imageView.isHidden = true
            let pv = AVPlayerView(frame: imageView.frame)
            pv.controlsStyle = .floating
            pv.player = AVPlayer(url: f)
            addSubview(pv, positioned: .below, relativeTo: closeButton)
            playerView = pv
            window?.makeFirstResponder(pv)                  // space = play / pause
            pv.player?.play()
        }
    }

    func close() {
        download?.cancel(); download = nil
        progress = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        playerView?.player?.pause()
        playerView?.player = nil
        if let f = tempFile { try? FileManager.default.removeItem(at: f); tempFile = nil }
        let w = window, back = returnTo
        removeFromSuperview()
        if MediaViewer.current === self { MediaViewer.current = nil }
        if let r = back { w?.makeFirstResponder(r) }
    }
}

// MARK: - inline video

/// a note's video playing ON its thumbnail (click on a video thumbnail): a subview of the text view, so it scrolls with
/// the text; JotTextView.placeInlineVideo keeps it on the thumbnail after layout passes and stops it when the line is
/// gone / shown as text / the note changes. The full part is downloaded sealed, opened in memory and written to a
/// temporary file (caches, 0600) only while it plays. A click toggles pause / play. One at a time.
final class InlineVideo: NSView {
    static var current: InlineVideo?
    let mediaId: String
    var charAt: Int                                  // where its line's text was last seen (to pick the nearest copy)
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    private var tempFile: URL?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private let host = NSView()                      // layer-hosting view for the AVPlayerLayer
    private let playerLayer = AVPlayerLayer()
    private let poster = NSImageView()               // the thumbnail, dimmed, while downloading
    private let spinner = NSProgressIndicator()
    private let badge = PlayBadge()                  // ▶ while paused
    private let track = NSView(), fill = NSView()    // thin progress line at the bottom
    private let pill = NSTextField(labelWithString: "")

    init(_ m: MediaAttr, charAt: Int) {
        mediaId = m.id
        self.charAt = charAt
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Style.mediaRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        host.layer = playerLayer                     // layer first, then wantsLayer: a layer-hosting view
        host.wantsLayer = true
        addSubview(host)
        poster.image = MediaStore.shared.image(m.id)
        poster.imageScaling = .scaleAxesIndependently // the view has the thumbnail's own aspect
        poster.alphaValue = 0.55
        addSubview(poster)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = false
        spinner.minValue = 0; spinner.maxValue = 100
        spinner.appearance = NSAppearance(named: .darkAqua)
        addSubview(spinner)
        badge.isHidden = true
        addSubview(badge)
        for (v, c) in [(track, NSColor.white.withAlphaComponent(0.25)), (fill, NSColor.white.withAlphaComponent(0.9))] {
            v.wantsLayer = true
            v.layer?.backgroundColor = c.cgColor
            v.isHidden = true
            addSubview(v)
        }
        pill.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        pill.textColor = .white
        pill.alignment = .center
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        pill.layer?.cornerRadius = 8
        pill.stringValue = m.duration
        pill.isHidden = m.duration.isEmpty
        addSubview(pill)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        host.frame = b
        poster.frame = b
        spinner.frame = NSRect(x: b.midX - 16, y: b.midY - 16, width: 32, height: 32)
        badge.frame = NSRect(x: b.midX - 22, y: b.midY - 22, width: 44, height: 44)
        track.frame = NSRect(x: 0, y: b.height - 3, width: b.width, height: 3)
        layoutFill()
        let w = max(34, pill.intrinsicContentSize.width + 10)
        pill.frame = NSRect(x: b.width - w - 8, y: b.height - 16 - 9, width: w, height: 16)
    }
    private var fraction: Double = 0
    private func layoutFill() { fill.frame = NSRect(x: 0, y: bounds.height - 3, width: bounds.width * CGFloat(min(1, max(0, fraction))), height: 3) }

    func start() {
        guard let api = MediaStore.shared.api, let key = MediaStore.shared.key else { stop(); return }
        let id = mediaId
        let task = api.session.downloadTask(with: api.request("GET", "/api/media/\(id)?part=full")) { [weak self] url, resp, err in
            // runs in the background; the downloaded (sealed) file is gone after this returns
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var file: URL?
            if err == nil, code == 200, let u = url, let sealed = try? Data(contentsOf: u),
               let plain = try? JotCrypto.openMedia(key, id: id, part: "full", sealed) { file = MediaViewer.writeTemp(plain) }
            let result = file, failed = err == nil || (err as? URLError)?.code != .cancelled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let s = self, s.superview != nil { s.ready(result, failed: failed) }
                    else if let f = result { try? FileManager.default.removeItem(at: f) }
                }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.spinner.doubleValue = f * 100 } }
        }
        download = task
        task.resume()
    }

    private func ready(_ file: URL?, failed: Bool) {
        progress = nil; download = nil
        spinner.isHidden = true
        guard let f = file else {
            if failed { pill.stringValue = "unavailable"; pill.isHidden = false; needsLayout = true }
            return
        }
        tempFile = f
        let p = AVPlayer(url: f)
        player = p
        playerLayer.player = p
        poster.isHidden = true
        track.isHidden = false; fill.isHidden = false; pill.isHidden = false
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let s = self, let pl = s.player else { return }
                pl.pause(); pl.seek(to: .zero)
                s.badge.isHidden = false
            }
        }
        p.play()
    }
    private func tick(_ t: CMTime) {
        let dur = player?.currentItem?.duration ?? .invalid
        let now = t.seconds.isFinite ? t.seconds : 0
        if dur.isNumeric, dur.seconds > 0 {
            fraction = now / dur.seconds
            pill.stringValue = InlineVideo.time(now) + " / " + InlineVideo.time(dur.seconds)
        } else {
            pill.stringValue = InlineVideo.time(now)
        }
        layoutFill()
        needsLayout = true                             // pill width
    }
    static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    // a click pauses / plays (while downloading it cancels)
    override func mouseDown(with e: NSEvent) {
        guard let p = player else { stop(); return }
        if p.timeControlStatus == .paused { p.play(); badge.isHidden = true } else { p.pause(); badge.isHidden = false }
    }

    func stop() {
        download?.cancel(); download = nil
        progress = nil
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        playerLayer.player = nil
        player = nil
        if let f = tempFile { try? FileManager.default.removeItem(at: f); tempFile = nil }
        removeFromSuperview()
        if InlineVideo.current === self { InlineVideo.current = nil }
    }
}

/// ▶ in a dark circle (paused inline video)
final class PlayBadge: NSView {
    override func draw(_ dirty: NSRect) {
        let c = bounds
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(ovalIn: c).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: c.midX - 6, y: c.midY - 9))
        tri.line(to: NSPoint(x: c.midX - 6, y: c.midY + 9))
        tri.line(to: NSPoint(x: c.midX + 10, y: c.midY))
        tri.close()
        NSColor.white.setFill(); tri.fill()
    }
}
