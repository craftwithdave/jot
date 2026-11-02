// Jot editor: a plain-text NSTextView with live markdown styling, clickable [[links]] / #tags / checkboxes / URLs /
// [Title](url) links, media thumbnails (JotMedia.swift), [[ autocomplete (keys handled here, list drawn by JotViews) and list continuation on Return. macOS only.
import AppKit
import SwiftUI
import JavaScriptCore

enum Style {
    static let size: CGFloat = 15
    static var base: NSFont { .systemFont(ofSize: size) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: size - 1, weight: .regular) }
    static let headingSizes: [CGFloat] = [22, 19, 17, 15.5, 15, 14]
    static var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .medium) }
    /// list markers sit left-aligned in a column as wide as "00." plus `markerGap`, so item text lines up
    /// for 1–99, A–Z and bullets alike; numbers are right-aligned in it and bullets end at its right edge
    static var numberWidth: CGFloat { ("00." as NSString).size(withAttributes: [.font: numberFont]).width }
    static var oneWidth: CGFloat { ("1." as NSString).size(withAttributes: [.font: numberFont]).width }
    static let markerGap: CGFloat = 6
    /// "1." and bullets start at the regular text margin; wider numbers ("10.") hang into this room to the left of it
    /// (every paragraph is indented by `hang` and the text inset is reduced by the same amount)
    static var hang: CGFloat { numberWidth - oneWidth }
    static let checkSize: CGFloat = 13
    static let rightMargin: CGFloat = 16              // extra room on the right of the text column
    static let codePad: CGFloat = 12                  // code text inset inside its block
    static let codeVPad: CGFloat = 6                  // block background above / below the code (fits in its paragraph spacing)
    static let quoteIndent: CGFloat = 10              // quote text starts this far inside its block
    static var tiny: NSFont { .systemFont(ofSize: 1) } // for marker characters that are drawn by JotLayoutManager instead
    static var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: base]).width }
    static var dashWidth: CGFloat { ("-" as NSString).size(withAttributes: [.font: base]).width }
}

/// the marker part of a list line (indent + "- ", "1. ", "- [ ] "; not quotes): never selected or copied.
/// Same rules as Coordinator.listItem, outside it so JotLayoutManager can use it too
enum ListLine {
    static let re = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+] \\[[ xX]\\] |[-*+] |(\\d+|[A-Za-z]|[ivxlcdmIVXLCDM]+)[.)] )")
    static func marker(_ s: NSString, _ line: NSRange) -> NSRange? {
        let text = s.substring(with: line)
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        if m.range(at: 3).location != NSNotFound {
            let t = (text as NSString).substring(with: m.range(at: 3))
            if t.count > 1, !t.allSatisfy(\.isNumber), ListMarker.fromRoman(t) == nil { return nil }   // "mix." etc.
        }
        return NSRange(location: line.location, length: m.range.length)
    }
    /// the markers of lines (outside code blocks) that overlap r
    static func markers(in r: NSRange, _ s: NSString, _ lm: JotLayoutManager) -> [NSRange] {
        var out: [NSRange] = [], at = r.location
        while at <= NSMaxRange(r), at < s.length {
            let line = s.lineRange(for: NSRange(location: at, length: 0))
            if lm.codeBlock(atChar: line.location) == nil, let m = marker(s, line),
               NSIntersectionRange(m, r).length > 0 || (r.length == 0 && NSLocationInRange(r.location, m)) { out.append(m) }
            if NSMaxRange(line) <= at { break }
            at = NSMaxRange(line)
        }
        return out
    }
}

extension NSAttributedString.Key {
    static let jotRule = NSAttributedString.Key("jotRule")        // "---" line drawn as a divider
    static let jotBullet = NSAttributedString.Key("jotBullet")    // list "-" drawn as a blue bullet; value = depth
    static let jotCheck = NSAttributedString.Key("jotCheck")      // "- [ ]" drawn as a blue checkbox; value = checked
    static let jotQuote = NSAttributedString.Key("jotQuote")      // "> " lines get a blue-tinted block behind them
    static let jotCodeBlock = NSAttributedString.Key("jotCodeBlock") // ``` block: rounded background, own sideways scroll; value = ordinal
}

/// draws what the plain text can't show: "---" lines as a divider, "- " list markers as blue bullets
/// (depth 0 ●, 1 ○, 2 ■, then repeating). The characters stay in the note; they're just painted clear.
final class JotLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    // code blocks (by ordinal in the note): sideways scroll offset, widest line, detected language.
    // Lines of block N are laid out shifted left by codeOffset[N] (JotTextContainer gives them a wide, shifted rect), so the caret,
    // selection and clicks follow the scrolled text; drawing is clipped to the block.
    var codeOffset: [Int: CGFloat] = [:]
    var codeWidth: [Int: CGFloat] = [:]
    var codeLanguage: [Int: String] = [:]
    var codeLabelRects: [Int: NSRect] = [:]          // where each block's language dropdown was last drawn (view coords)
    var mediaHits: [Int: MediaHit] = [:]             // thumbnails as last drawn, by the media line's "!" (click → viewer / play)
    var onLayout: (() -> Void)?                      // after each layout pass (keeps an inline video on its thumbnail)

    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func codeBlock(atChar i: Int) -> Int? {
        guard let ts = textStorage, i >= 0, i < ts.length else { return nil }
        return ts.attribute(.jotCodeBlock, at: i, effectiveRange: nil) as? Int
    }
    /// width code text can use inside its block
    func codeVisibleWidth(_ tc: NSTextContainer) -> CGFloat { codeBoxWidth(tc) - 2 * Style.codePad }
    /// the block's background spans the regular text column (same left / right margins as body text)
    func codeBoxWidth(_ tc: NSTextContainer) -> CGFloat { tc.size.width - 2 * tc.lineFragmentPadding - Style.hang }
    /// x range of a block's text area (clip for scrolled code), in view coordinates
    func codeClip(_ tc: NSTextContainer, _ origin: NSPoint) -> NSRect {
        NSRect(x: origin.x + tc.lineFragmentPadding + Style.hang + Style.codePad, y: -1e7, width: codeVisibleWidth(tc), height: 2e7)
    }
    func codeRange(_ ordinal: Int) -> NSRange? {
        guard let ts = textStorage else { return nil }
        var found: NSRange?
        ts.enumerateAttribute(.jotCodeBlock, in: NSRange(location: 0, length: ts.length)) { v, r, stop in
            if v as? Int == ordinal { found = r; stop.pointee = true }
        }
        return found
    }
    /// the code between block o's ``` lines (as restyle's `inner`)
    func codeInner(_ o: Int) -> NSRange? {
        guard let r = codeRange(o), let s = textStorage?.string as NSString? else { return nil }
        let first = s.lineRange(for: NSRange(location: r.location, length: 0))
        let start = NSMaxRange(first), end = max(start, (closingLine(o)?.location ?? start) - 1)
        return NSRange(location: start, length: end - start)
    }
    /// the line holding block o's closing ```
    func closingLine(_ o: Int) -> NSRange? {
        guard let r = codeRange(o), r.length > 0, let s = textStorage?.string as NSString? else { return nil }
        return s.lineRange(for: NSRange(location: NSMaxRange(r) - 1, length: 0))
    }
    /// how wide a line of block o is laid out (no wrapping: its widest line plus padding)
    func codeLineWidth(_ o: Int, _ tc: NSTextContainer) -> CGFloat {
        (codeWidth[o] ?? 0) + 2 * tc.lineFragmentPadding + Style.hang + 24
    }
    /// scrolls block `ordinal` sideways to `offset` (clamped); re-lays out just that block
    func setOffset(_ offset: CGFloat, for ordinal: Int) {
        guard let tc = textContainers.first else { return }
        let maxOff = max(0, (codeWidth[ordinal] ?? 0) - codeVisibleWidth(tc) + 12)
        let v = min(max(0, offset), maxOff).rounded()
        guard v != (codeOffset[ordinal] ?? 0), let r = codeRange(ordinal) else { return }
        codeOffset[ordinal] = v
        invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        ensureLayout(forCharacterRange: r)            // lay out now so the redraw never sees the block half done (blinking)
        invalidateDisplay(forCharacterRange: r)
    }

    func layoutManager(_ lm: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        onLayout?()
    }
    /// top-left and width limit of the picture of the media line whose text (from "!") starts at char i (view coordinates)
    func mediaSlot(atChar i: Int, origin: NSPoint) -> (at: NSPoint, maxWidth: CGFloat)? {
        let g = glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
        guard g.length > 0, let tc = textContainer(forGlyphAt: g.location, effectiveRange: nil) else { return nil }
        let frag = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
        let loc = location(forGlyphAt: g.location)
        let x = origin.x + frag.minX + loc.x
        return (NSPoint(x: x, y: origin.y + frag.minY + Style.mediaGap / 2), origin.x + frag.maxX - tc.lineFragmentPadding - x)
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        guard let ts = textStorage, let tc = textContainers.first else { return super.drawGlyphs(forGlyphRange: glyphs, at: origin) }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        ts.enumerateAttribute(.jotCodeBlock, in: chars) { v, r, _ in
            let seg = NSIntersectionRange(glyphRange(forCharacterRange: r, actualCharacterRange: nil), glyphs)
            guard seg.length > 0 else { return }
            if v is Int {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: codeClip(tc, origin)).addClip()
                super.drawGlyphs(forGlyphRange: seg, at: origin)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                super.drawGlyphs(forGlyphRange: seg, at: origin)
            }
        }
    }
    // selection highlight inside a scrolled block stays inside the block
    // ... and on every other line starts where the text starts: never over list markers (numbers, bullets, checkboxes)
    // or the margin under them on wrapped lines / indented follow-on lines
    override func fillBackgroundRectArray(_ rects: UnsafePointer<NSRect>, count: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let ts = textStorage, let tc = textContainers.first, let tv = tc.textView else {
            return super.fillBackgroundRectArray(rects, count: count, forCharacterRange: charRange, color: color)
        }
        let origin = tv.textContainerOrigin, s = ts.string as NSString
        NSGraphicsContext.saveGraphicsState()
        if codeBlock(atChar: charRange.location) != nil { NSBezierPath(rect: codeClip(tc, origin)).addClip() }
        else {
            let clip = NSBezierPath(rect: NSRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7))
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)) { frag, used, _, g, _ in
                let c = self.characterIndexForGlyph(at: g.location)
                guard self.codeBlock(atChar: c) == nil else { return }
                // a picture's or a "---" divider's line: no highlight at all (its text is hidden)
                let full = s.lineRange(for: NSRange(location: c, length: 0))
                var hasMedia = false
                for k in [NSAttributedString.Key.jotMedia, .jotRule] where !hasMedia {
                    ts.enumerateAttribute(k, in: full) { v, _, stop in if v != nil { hasMedia = true; stop.pointee = true } }
                }
                if hasMedia {
                    clip.append(NSBezierPath(rect: NSRect(x: origin.x + frag.minX - 4, y: origin.y + frag.minY, width: frag.width + 8, height: frag.height)))
                    return
                }
                var start = c                                   // first character of the line's text
                if c == s.paragraphRange(for: NSRange(location: c, length: 0)).location {
                    let line = s.lineRange(for: NSRange(location: c, length: 0))
                    if let m = ListLine.marker(s, line) { start = NSMaxRange(m) }
                    else { while start < NSMaxRange(line), [32, 9].contains(s.character(at: start)) { start += 1 } }
                }
                let first = self.glyphIndexForCharacter(at: start)
                let textX = first < NSMaxRange(g) && start < s.length && s.character(at: start) != 10
                    ? frag.minX + self.location(forGlyphAt: first).x : used.maxX
                clip.append(NSBezierPath(rect: NSRect(x: origin.x + frag.minX - 4, y: origin.y + frag.minY, width: textX - frag.minX + 4, height: frag.height)))
            }
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        super.fillBackgroundRectArray(rects, count: count, forCharacterRange: charRange, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let ts = textStorage else { return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        ts.enumerateAttribute(.jotRule, in: chars) { v, r, _ in
            guard v != nil else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard g.length > 0, let tc = textContainer(forGlyphAt: g.location, effectiveRange: nil) else { return }
            let line = lineFragmentUsedRect(forGlyphAt: g.location, effectiveRange: nil)
            let frag = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
            let pad = tc.lineFragmentPadding
            let y = (origin.y + line.minY + line.height / 2).rounded() + 0.5
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSRect(x: origin.x + frag.minX + pad + Style.hang, y: y - 0.5, width: frag.width - 2 * pad - Style.hang, height: 1).fill()
        }
        ts.enumerateAttribute(.jotCheck, in: chars) { v, r, _ in
            guard let checked = v as? Bool else { return }
            let g = glyphRange(forCharacterRange: NSRange(location: r.location, length: 1), actualCharacterRange: nil)
            guard g.length > 0 else { return }
            let frag = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
            let loc = location(forGlyphAt: g.location)
            let d = Style.checkSize
            // the box is about as tall as a capital, so it's centred between the baseline and cap height
            // (bullets use the x-height middle; that leaves a box hanging below the baseline)
            let cy = (origin.y + frag.minY + loc.y - Style.base.capHeight / 2).rounded()
            let box = NSRect(x: origin.x + frag.minX + loc.x, y: cy - d / 2, width: d, height: d)
            if checked {
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + d * 0.26, y: box.minY + d * 0.52))
                tick.line(to: NSPoint(x: box.minX + d * 0.43, y: box.minY + d * 0.70))
                tick.line(to: NSPoint(x: box.minX + d * 0.75, y: box.minY + d * 0.32))
                tick.lineWidth = 1.7; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                NSColor.white.setStroke(); tick.stroke()
            } else {
                let o = NSBezierPath(roundedRect: box.insetBy(dx: 0.65, dy: 0.65), xRadius: 3.2, yRadius: 3.2)
                o.lineWidth = 1.3
                NSColor.systemBlue.setStroke(); o.stroke()
            }
        }
        ts.enumerateAttribute(.jotCodeBlock, in: chars) { v, r, _ in
            guard let o = v as? Int else { return }
            // the whole block's box, even when only part of it is being redrawn
            let g = glyphRange(forCharacterRange: codeRange(o) ?? r, actualCharacterRange: nil)
            guard g.length > 0, let tc = textContainer(forGlyphAt: g.location, effectiveRange: nil) else { return }
            var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
            enumerateLineFragments(forGlyphRange: g) { _, used, _, _, _ in
                top = min(top, used.minY); bottom = max(bottom, used.maxY)
            }
            guard top < bottom else { return }
            // from the container, not the line fragments (those are shifted while the block is scrolled)
            let x = origin.x + tc.lineFragmentPadding + Style.hang
            let box = NSRect(x: x, y: origin.y + top - Style.codeVPad, width: codeBoxWidth(tc), height: bottom - top + 2 * Style.codeVPad)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            do {
                // language dropdown in the block's top row (JotTextView opens the menu when it's clicked)
                let name = (codeLanguage[o].flatMap { CodeTheme.names[$0] } ?? "Auto") + "  ▾"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
                let sz = (name as NSString).size(withAttributes: attrs)
                let pill = NSRect(x: box.maxX - sz.width - 18, y: box.minY + 5, width: sz.width + 12, height: sz.height + 4)
                NSColor.white.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
                (name as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
                codeLabelRects[o] = pill
            }
        }
        ts.enumerateAttribute(.jotQuote, in: chars) { v, r, _ in
            guard v != nil else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard g.length > 0, let tc = textContainer(forGlyphAt: g.location, effectiveRange: nil) else { return }
            var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude, frag = NSRect.zero
            enumerateLineFragments(forGlyphRange: g) { f, used, _, _, _ in
                top = min(top, used.minY); bottom = max(bottom, used.maxY); frag = f
            }
            guard top < bottom else { return }
            // a blue-tinted block from the text margin (where bullets start) to the right edge
            let x = origin.x + frag.minX + tc.lineFragmentPadding + Style.hang
            let block = NSRect(x: x, y: origin.y + top - 3, width: origin.x + frag.maxX - tc.lineFragmentPadding - x, height: bottom - top + 6)
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: block, xRadius: 6, yRadius: 6).fill()
        }
        // media lines: the thumbnail fills the (fixed-height) line, from where its text starts,
        // so a line indented under a list item lines up with the item's text
        var drawnMedia = Set<Int>()
        ts.enumerateAttribute(.jotMedia, in: chars) { v, r, _ in
            guard v is MediaAttr else { return }
            var run = NSRange(location: 0, length: 0)          // the whole run: a revealed line can wrap, the picture sits above its first line
            guard let m = ts.attribute(.jotMedia, at: r.location, longestEffectiveRange: &run, in: NSRange(location: 0, length: ts.length)) as? MediaAttr,
                  drawnMedia.insert(run.location).inserted else { return }
            guard let slot = mediaSlot(atChar: run.location, origin: origin) else { return }
            let rect = MediaStore.draw(m, at: slot.at, maxWidth: slot.maxWidth)
            mediaHits[run.location] = MediaHit(rect: rect, area: NSRect(x: slot.at.x, y: slot.at.y, width: min(Style.mediaMaxWidth, max(40, slot.maxWidth)),
                                                                       height: Style.mediaHeight), media: m)
        }
        ts.enumerateAttribute(.jotBullet, in: chars) { v, r, _ in
            guard let depth = v as? Int else { return }
            let g = glyphRange(forCharacterRange: NSRange(location: r.location, length: 1), actualCharacterRange: nil)
            guard g.length > 0, let tc = textContainer(forGlyphAt: g.location, effectiveRange: nil) else { return }
            let frag = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
            let loc = location(forGlyphAt: g.location)
            _ = tc
            let font = (ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? Style.base
            // starts at the text margin like "1." does (its box is as wide as "1.", so dot→text = "1."→text)
            let right = origin.x + frag.minX + loc.x + [4.5, 4.75, 3.8][depth % 3], cy = origin.y + frag.minY + loc.y - font.xHeight / 2
            NSColor.systemBlue.set()
            switch depth % 3 {
            case 0: NSBezierPath(ovalIn: NSRect(x: right - 4.5, y: cy - 2.25, width: 4.5, height: 4.5)).fill()
            case 1:
                let o = NSBezierPath(ovalIn: NSRect(x: right - 4.75, y: cy - 2.1, width: 4.2, height: 4.2))
                o.lineWidth = 1.1; o.stroke()
            default: NSRect(x: right - 3.8, y: cy - 1.9, width: 3.8, height: 3.8).fill()
            }
        }
    }
}

/// code-block lines get a rect as wide as their widest line, shifted by the block's sideways scroll, before they're
/// laid out (so they never wrap or clip, and the caret can reach the line end)
final class JotTextContainer: NSTextContainer {
    override var isSimpleRectangularTextContainer: Bool { false }
    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var r = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        guard let lm = layoutManager as? JotLayoutManager, !r.isEmpty, let o = lm.codeBlock(atChar: characterIndex) else { return r }
        r.origin.x -= lm.codeOffset[o] ?? 0
        r.size.width = max(r.width, lm.codeLineWidth(o, self))
        return r
    }
}

/// code-block colouring: highlight.js + jothl.js (installed in the app's Resources) run in JavaScriptCore —
/// nothing leaves the Mac. Results are cached so typing only re-highlights the block being edited. Main thread only.
final class Highlighter {
    static let shared = Highlighter()
    struct Result { let spans: [HLParse.Span]; let language: String }
    private var ctx: JSContext?
    private lazy var fn: JSValue? = {
        guard let a = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let b = Bundle.main.url(forResource: "jothl", withExtension: "js"),
              let s1 = try? String(contentsOf: a, encoding: .utf8), let s2 = try? String(contentsOf: b, encoding: .utf8),
              let c = JSContext() as JSContext? else { return nil }
        c.evaluateScript(s1); c.evaluateScript(s2)
        ctx = c
        guard let f = c.objectForKeyedSubscript("jotHighlight"), !f.isUndefined else { return nil }
        return f
    }()
    private var cache: [String: Result] = [:], order: [String] = []

    func highlight(_ code: String, lang: String) -> Result? {
        guard !code.isEmpty, code.utf16.count <= 20_000 else { return nil }
        let key = lang + "\u{0}" + code
        if let r = cache[key] { return r }
        guard let f = fn, let json = f.call(withArguments: [code, lang])?.toString(), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let html = obj["value"] as? String else { return nil }
        let p = HLParse.parse(html)
        let r = Result(spans: p.text == code ? p.spans : [], language: obj["language"] as? String ?? "")
        cache[key] = r; order.append(key)
        if order.count > 64 { cache[order.removeFirst()] = nil }
        return r
    }
}

/// colours for highlight.js classes (GitHub-dark style) and display names for the language label
enum CodeTheme {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    // One Dark (Atom / VS Code)
    static let colors: [String: NSColor] = [
        "keyword": hex(0xc678dd), "doctag": hex(0xc678dd), "template-tag": hex(0xc678dd), "operator": hex(0x56b6c2),
        "string": hex(0x98c379), "regexp": hex(0x98c379), "meta string": hex(0x98c379), "char": hex(0x98c379), "addition": hex(0x98c379),
        "comment": hex(0x7f848e), "quote": hex(0x7f848e), "meta": hex(0x61afef), "meta keyword": hex(0xc678dd),
        "number": hex(0xd19a66), "literal": hex(0x56b6c2), "attr": hex(0xd19a66), "attribute": hex(0x98c379),
        "variable": hex(0xe06c75), "template-variable": hex(0xe06c75), "params": hex(0xabb2bf), "property": hex(0xe06c75),
        "title": hex(0x61afef), "title function_": hex(0x61afef), "title class_": hex(0xe5c07b), "section": hex(0xe06c75),
        "type": hex(0xe5c07b), "built_in": hex(0xe5c07b), "symbol": hex(0x61afef), "bullet": hex(0x61afef),
        "tag": hex(0xe06c75), "name": hex(0xe06c75), "selector-tag": hex(0xe06c75), "selector-class": hex(0xd19a66),
        "selector-id": hex(0x61afef), "selector-attr": hex(0xd19a66), "selector-pseudo": hex(0xd19a66), "subst": hex(0xe06c75),
        "punctuation": hex(0xabb2bf), "deletion": hex(0xe06c75), "link": hex(0x61afef), "code": hex(0x98c379),
    ]
    static let plain = hex(0xabb2bf)                 // code text without a token class
    static let italic: Set<String> = ["comment", "quote", "doctag"]
    static func color(_ cls: String) -> NSColor? {
        colors[cls] ?? cls.split(separator: " ").first.flatMap { colors[String($0)] }
    }
    static let names: [String: String] = [
        "bash": "Bash", "c": "C", "cpp": "C++", "csharp": "C#", "css": "CSS", "diff": "Diff", "go": "Go", "graphql": "GraphQL",
        "ini": "INI", "java": "Java", "javascript": "JavaScript", "json": "JSON", "kotlin": "Kotlin", "less": "Less", "lua": "Lua",
        "makefile": "Makefile", "markdown": "Markdown", "objectivec": "Objective-C", "perl": "Perl", "php": "PHP",
        "python": "Python", "r": "R", "ruby": "Ruby", "rust": "Rust", "scss": "SCSS", "shell": "Shell", "sql": "SQL",
        "swift": "Swift", "typescript": "TypeScript", "xml": "XML", "yaml": "YAML",
    ]
}

/// the editor's text view: sideways scrolling over a code block scrolls just that block; its language dropdown
/// picks the language (written after the opening ```, so it syncs)
final class JotTextView: NSTextView {
    var onImages: (([Data], Int?) -> Void)?          // pasted / dropped images (Coordinator.addImages); Int = where they were dropped
    var storage: NSTextStorage?                      // keeps the text system (storage → JotLayoutManager → JotTextContainer) alive
    // text container = view width minus the insets and an extra right margin (widthTracksTextView is off)
    var onWidth: (() -> Void)?                       // the text width changed (Coordinator.sizeMedia: pictures may get narrower / shorter)
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let w = max(50, size.width - 2 * textContainerInset.width - Style.rightMargin)
        let changed = w != textContainer?.containerSize.width
        textContainer?.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        if changed, onWidth != nil { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onWidth?() } } }
    }
    // the caret is never picture-tall (a picture's line is as tall as the picture)
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        let h = ceil(Style.base.ascender - Style.base.descender + Style.base.leading) + 3
        if r.height > Style.mediaHeight / 2 { r.origin.y = r.maxY - h; r.size.height = h }
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }
    // fixed: a code block scrolled sideways has line fragments at negative x, which must not shift the whole text right
    override var textContainerOrigin: NSPoint { NSPoint(x: textContainerInset.width, y: textContainerInset.height) }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let lm = layoutManager as? JotLayoutManager, let (o, r) = lm.codeLabelRects.first(where: { $0.value.contains(p) }) {
            languageMenu(o, lm).popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 4), in: self)
            return
        }
        if e.clickCount == 1, let lm = layoutManager as? JotLayoutManager, let (at, hit) = lm.mediaHits.first(where: { $0.value.rect.contains(p) }) {
            if hit.media.video { playInline(hit, at: at) } else { MediaViewer.open(hit.media, from: window) }
            return
        }
        // a click on a picture's line but not on the picture (beside it, in the gap above / below): the caret goes to the
        // end of the line above (top half) or the start of the line below (bottom half), never onto the picture's line
        if e.clickCount == 1, e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let lm = layoutManager, let ts = textStorage, ts.length > 0 {
            let s = string as NSString
            let line = s.lineRange(for: NSRange(location: min(characterIndexForInsertion(at: p), s.length), length: 0))
            var media: NSRange?
            for k in [NSAttributedString.Key.jotMedia, .jotRule] where media == nil && line.length > 0 {    // pictures and "---" dividers
                ts.enumerateAttribute(k, in: line) { v, r, stop in if v != nil { media = r; stop.pointee = true } }
            }
            if let r = media {
                let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: r.location), effectiveRange: nil)
                let below = p.y - textContainerOrigin.y >= frag.midY
                let hasNext = s.character(at: NSMaxRange(line) - 1) == 10
                let to = below && hasNext ? NSMaxRange(line) : line.location > 0 ? line.location - 1 : (hasNext ? NSMaxRange(line) : line.location)
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: to, length: 0))
                return
            }
        }
        // a click under a code block (its collapsed closing ``` line) starts a text line below the block
        if e.clickCount == 1, e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let lm = layoutManager as? JotLayoutManager {
            let i = characterIndexForInsertion(at: p)
            let line = (string as NSString).lineRange(for: NSRange(location: min(i, (string as NSString).length), length: 0))
            if let o = lm.codeBlock(atChar: line.location), lm.closingLine(o)?.location == line.location {
                exitBelowCode(o)
                return
            }
        }
        // a drag that starts in a code block scrolls the block sideways while the mouse is at (or past) its edge
        var edgeScroll: Timer?
        if e.clickCount == 1, let lm = layoutManager as? JotLayoutManager, let tc = textContainer {
            let a = characterIndexForInsertion(at: p)
            if let o = lm.codeBlock(atChar: a) ?? lm.codeBlock(atChar: a - 1), let inner = lm.codeInner(o),
               a >= inner.location, a <= NSMaxRange(inner) {
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self = self, let w = self.window else { return }
                        let m = self.convert(w.mouseLocationOutsideOfEventStream, from: nil)
                        guard abs(m.x - p.x) > 3 || abs(m.y - p.y) > 3 else { return }        // a click, not a drag (yet)
                        let clip = lm.codeClip(tc, self.textContainerOrigin), band: CGFloat = 10
                        let over = m.x > clip.maxX - band ? m.x - (clip.maxX - band) : m.x < clip.minX + band ? m.x - (clip.minX + band) : 0
                        guard over != 0 else { return }
                        let old = lm.codeOffset[o] ?? 0
                        lm.setOffset(old + (over > 0 ? 1 : -1) * min(28, 2 + abs(over) * 0.4), for: o)
                        guard (lm.codeOffset[o] ?? 0) != old else { return }
                        let i = self.characterIndexForInsertion(at: NSPoint(x: min(max(m.x, clip.minX + 1), clip.maxX - 1), y: m.y))
                        self.setSelectedRange(NSRange(location: min(a, i), length: abs(i - a)))
                    }
                }
                RunLoop.current.add(t, forMode: .eventTracking)
                edgeScroll = t
            }
        }
        super.mouseDown(with: e)
        edgeScroll?.invalidate()
    }

    /// caret onto the line under block o: an empty line already there, else a new one
    func exitBelowCode(_ o: Int) {
        guard let lm = layoutManager as? JotLayoutManager, let close = lm.closingLine(o) else { return }
        let s = string as NSString
        let hasNewline = close.length > 0 && s.character(at: NSMaxRange(close) - 1) == 10
        let next = NSMaxRange(close)
        if hasNewline && (next == s.length || s.character(at: next) == 10) {
            setSelectedRange(NSRange(location: next, length: 0))
        } else {
            insertText("\n", replacementRange: NSRange(location: hasNewline ? next - 1 : next, length: 0))
        }
        window?.makeFirstResponder(self)
    }

    /// copied text leaves out list markers (numbers, bullets, checkboxes), as the highlight does
    func selectionWithoutMarkers() -> String? {
        guard let lm = layoutManager as? JotLayoutManager else { return nil }
        let s = string as NSString, sel = selectedRange()
        let markers = ListLine.markers(in: sel, s, lm)
        guard sel.length > 0, !markers.isEmpty else { return nil }
        var out = "", at = sel.location
        for m in markers {
            let cut = NSIntersectionRange(m, sel)
            if cut.location > at { out += s.substring(with: NSRange(location: at, length: cut.location - at)) }
            at = max(at, NSMaxRange(cut))
        }
        if NSMaxRange(sel) > at { out += s.substring(with: NSRange(location: at, length: NSMaxRange(sel) - at)) }
        return out
    }
    override func copy(_ sender: Any?) {
        guard let t = selectionWithoutMarkers() else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
    override func cut(_ sender: Any?) {
        guard selectionWithoutMarkers() != nil else { return super.cut(sender) }
        copy(sender)
        delete(sender)
    }

    /// ⌘A in a code block selects its code; again selects the whole note
    override func selectAll(_ sender: Any?) {
        let at = NSMaxRange(selectedRange())
        if let lm = layoutManager as? JotLayoutManager, let o = lm.codeBlock(atChar: at) ?? lm.codeBlock(atChar: at - 1),
           let inner = lm.codeInner(o), inner.length > 0, selectedRange() != inner {
            setSelectedRange(inner)
            return
        }
        super.selectAll(sender)
    }

    // MARK: inline video (plays on its thumbnail)

    /// a click on a video thumbnail plays it right there; starting another stops the first
    func playInline(_ hit: MediaHit, at: Int) {
        InlineVideo.current?.stop()
        let v = InlineVideo(hit.media, charAt: at)
        v.frame = hit.rect
        addSubview(v)
        InlineVideo.current = v
        (layoutManager as? JotLayoutManager)?.onLayout = { [weak self] in MainActor.assumeIsolated { self?.queuePlaceInlineVideo() } }
        v.start()
    }
    private var placeQueued = false
    /// after the layout pass (never during it)
    func queuePlaceInlineVideo() {
        guard !placeQueued else { return }
        placeQueued = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.placeQueued = false; self?.placeInlineVideo() } }
    }
    /// keeps the playing video on its thumbnail; stops it when its line is gone or shown as text (caret on it)
    func placeInlineVideo() {
        let lm = layoutManager as? JotLayoutManager
        guard let v = InlineVideo.current, v.superview === self else { lm?.onLayout = nil; return }
        guard let lm = lm, let ts = textStorage else { v.stop(); return }
        var best: NSRange?                                       // the line with this id nearest to where it was
        ts.enumerateAttribute(.jotMedia, in: NSRange(location: 0, length: ts.length)) { val, r, _ in
            guard (val as? MediaAttr)?.id == v.mediaId else { return }
            if let b = best, abs(b.location - v.charAt) <= abs(r.location - v.charAt) { return }
            best = r
        }
        guard let r = best, ((ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 15) < 2,
              let m = ts.attribute(.jotMedia, at: r.location, effectiveRange: nil) as? MediaAttr,
              let slot = lm.mediaSlot(atChar: r.location, origin: textContainerOrigin) else { v.stop(); lm.onLayout = nil; return }
        v.charAt = r.location
        let f = MediaStore.frame(m, at: slot.at, maxWidth: slot.maxWidth)
        if f != v.frame { v.frame = f }
    }
    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        let p = convert(e.locationInWindow, from: nil)
        if let lm = layoutManager as? JotLayoutManager, lm.mediaHits.values.contains(where: { $0.rect.contains(p) }) { NSCursor.pointingHand.set() }
    }

    // images in: paste / drag-and-drop (anything else behaves as before)
    override func paste(_ sender: Any?) {
        if let f = onImages, let imgs = MediaImport.images(NSPasteboard.general) { f(imgs, nil); return }
        super.paste(sender)
    }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL, .tiff, .png] }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingEntered(s)
        return onImages != nil && MediaImport.hasImage(s.draggingPasteboard) ? .copy : op
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(s)
        return onImages != nil && MediaImport.hasImage(s.draggingPasteboard) ? .copy : op
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if let f = onImages, let imgs = MediaImport.images(s.draggingPasteboard) {
            f(imgs, characterIndexForInsertion(at: convert(s.draggingLocation, from: nil)))
            return true
        }
        return super.performDragOperation(s)
    }
    private func languageMenu(_ o: Int, _ lm: JotLayoutManager) -> NSMenu {
        let menu = NSMenu()
        let current = fenceTag(o, lm)
        let langs = [("", "Auto-detect")] + CodeTheme.names.sorted { $0.value.lowercased() < $1.value.lowercased() }.map { ($0.key, $0.value) }
        for (i, (id, name)) in langs.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(MenuTarget.run), keyEquivalent: "")
            let t = MenuTarget { [weak self] in self?.setLanguage(o, id, lm) }
            item.target = t
            item.representedObject = t                     // keeps the target alive while the menu is open
            item.state = id == current ? .on : .off
            menu.addItem(item)
            if i == 0 { menu.addItem(.separator()) }
        }
        return menu
    }
    /// the opening ``` line of block o (without its newline) and the language written on it
    private func fenceLine(_ o: Int, _ lm: JotLayoutManager) -> NSRange? {
        guard let r = lm.codeRange(o) else { return nil }
        let s = string as NSString
        var line = s.lineRange(for: NSRange(location: r.location, length: 0))
        if line.length > 0, s.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        return line
    }
    private func fenceTag(_ o: Int, _ lm: JotLayoutManager) -> String {
        guard let line = fenceLine(o, lm) else { return "" }
        return String((string as NSString).substring(with: line).dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
    }
    private func setLanguage(_ o: Int, _ id: String, _ lm: JotLayoutManager) {
        guard let line = fenceLine(o, lm) else { return }
        let sel = selectedRange(), new = "```" + id
        insertText(new, replacementRange: line)
        let delta = (new as NSString).length - line.length
        setSelectedRange(NSRange(location: sel.location > line.location ? sel.location + delta : sel.location, length: sel.length))
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with e: NSEvent) {
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), let lm = layoutManager as? JotLayoutManager, let ts = textStorage, ts.length > 0 {
            let i = min(characterIndexForInsertion(at: convert(e.locationInWindow, from: nil)), ts.length - 1)
            if let o = lm.codeBlock(atChar: i) {
                let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 12
                lm.setOffset((lm.codeOffset[o] ?? 0) - dx, for: o)
                return
            }
        }
        super.scrollWheel(with: e)
    }
}

/// the page only scrolls up and down; code blocks scroll sideways on their own (JotLayoutManager.codeOffset)
final class JotClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        r.origin.x = 0
        return r
    }
}

struct EditorView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { MainActor.assumeIsolated { Coordinator(model) } }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let ts = NSTextStorage(), lm = JotLayoutManager()
        let tc = JotTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        ts.addLayoutManager(lm)
        lm.addTextContainer(tc)
        let tv = JotTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: tc)
        tv.storage = ts                                           // a hand-built text system is owned through its storage
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false          // JotTextView.setFrameSize sizes it (extra right margin)
        let clip = JotClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: TopBar.height, left: 0, bottom: TopBar.height, right: 0)   // text scrolls under the bar / bottom fade
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Style.base
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]   // never recolour selected text: hidden (clear) symbols like a divider's "---" stay hidden
        tv.textContainerInset = NSSize(width: 18 - Style.hang, height: 10)     // + hang indent on every paragraph
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        MainActor.assumeIsolated {
            tv.typingAttributes = Coordinator.baseAttrs
            tv.delegate = context.coordinator
            tv.textStorage?.delegate = context.coordinator
            context.coordinator.tv = tv
            tv.onImages = { [weak c = context.coordinator] d, at in MainActor.assumeIsolated { c?.addImages(d, at: at) } }
            tv.onWidth = { [weak c = context.coordinator, weak tv] in
                MainActor.assumeIsolated { if let ts = tv?.textStorage { ts.beginEditing(); c?.sizeMedia(ts); ts.endEditing() } }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        MainActor.assumeIsolated {
            let c = context.coordinator
            guard let tv = c.tv else { return }
            if c.token != model.loadToken {
                let sameNote = c.noteId == model.currentId
                if !sameNote { (tv.layoutManager as? JotLayoutManager)?.codeOffset = [:]; InlineVideo.current?.stop() }
                let sel = tv.selectedRange()
                c.token = model.loadToken
                c.noteId = model.currentId
                c.loading = true                             // the selection changes below aren't the user's caret
                tv.string = model.text                       // restyled by the text storage delegate
                let len = (model.text as NSString).length
                if sameNote { tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0)) }
                else if let at = Coordinator.savedCaret(model.currentId) {
                    // a note opens where its caret was left
                    tv.setSelectedRange(NSRange(location: min(at, len), length: 0)); tv.undoManager?.removeAllActions()
                    tv.scrollRangeToVisible(tv.selectedRange())
                }
                else { tv.setSelectedRange(NSRange(location: len, length: 0)); tv.undoManager?.removeAllActions(); tv.scrollToEndOfDocument(nil) }
                c.loading = false
                if !model.showSwitcher { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
            } else if c.indexVersion != model.indexGen {
                tv.textStorage.map { c.restyle($0) }          // links may now exist / be gone
            }
            c.indexVersion = model.indexGen
            if c.switcherShown && !model.showSwitcher { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
            c.switcherShown = model.showSwitcher
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let model: AppModel
        weak var tv: NSTextView?
        var token = -1
        var noteId = ""
        var switcherShown = false
        var indexVersion = -1
        var revealedLinks: [NSRange] = []          // [Title](url) links restyle showed whole (the caret touches them)
        var lastSel = NSRange(location: 0, length: 0)   // previous selection (revealCaretInCode: which end moved)
        var mouseAnchor = 0                              // caret the last click left: fixed end of the drag / shift-click after it
        var loading = false                              // a note's text is being put in (don't remember that caret)

        init(_ m: AppModel) {
            model = m
            super.init()
            // these are app-wide but meant for one window: focus names its window, format / accept go to the key one
            NotificationCenter.default.addObserver(forName: .jotFocusEditor, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let tv = self?.tv else { return }
                    if let w = n.object as? NSWindow, w !== tv.window { return }
                    tv.window?.makeFirstResponder(tv)
                }
            }
            NotificationCenter.default.addObserver(forName: .jotAcceptLink, object: nil, queue: .main) { [weak self] n in
                if let t = n.object as? String { MainActor.assumeIsolated { if self?.tv?.window?.isKeyWindow == true { self?.acceptLink(t) } } }
            }
            NotificationCenter.default.addObserver(forName: .jotFormat, object: nil, queue: .main) { [weak self] n in
                if let a = n.object as? String { MainActor.assumeIsolated { if self?.tv?.window?.isKeyWindow == true { self?.format(a) } } }
            }
            NotificationCenter.default.addObserver(forName: .jotMediaLoaded, object: nil, queue: .main) { [weak self] n in
                if let id = n.object as? String { MainActor.assumeIsolated { self?.mediaLoaded(id) } }
            }
        }

        /// list lines get more room between items; wrapped lines start where the item's text starts
        static func listPara(first: CGFloat, wrap: CGFloat, spaced: Bool = true) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = 2
            p.paragraphSpacingBefore = spaced ? 6 : 0
            p.firstLineHeadIndent = first
            p.headIndent = wrap
            return p
        }
        /// code blocks: base spacing + indent, but lines never wrap (the block scrolls sideways instead)
        static let codePara: NSParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = 2
            p.firstLineHeadIndent = Style.hang + Style.codePad
            p.headIndent = Style.hang + Style.codePad
            p.lineBreakMode = .byClipping
            return p
        }()
        /// the (collapsed) closing ``` line: space after the block for its background + a gap before the next line
        static let codeBottomPara: NSParagraphStyle = {
            let p = codePara.mutableCopy() as! NSMutableParagraphStyle
            p.paragraphSpacing = Style.codeVPad + 8
            return p
        }()
        /// the (collapsed) opening ``` line: extra space after it holds the language dropdown
        static let codeTopPara: NSParagraphStyle = {
            let p = codePara.mutableCopy() as! NSMutableParagraphStyle
            p.paragraphSpacing = 18
            p.paragraphSpacingBefore = Style.codeVPad + 6
            return p
        }()
        static func width(_ t: String, _ f: NSFont = Style.base) -> CGFloat { (t as NSString).size(withAttributes: [.font: f]).width }

        static var baseAttrs: [NSAttributedString.Key: Any] {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = 2
            p.firstLineHeadIndent = Style.hang
            p.headIndent = Style.hang
            return [.font: Style.base, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
        }

        // MARK: typing

        func textDidChange(_ n: Notification) {
            guard let tv = tv else { return }
            MainActor.assumeIsolated {
                model.typed(tv.string)
                model.linkQuery(linkQuery(tv))
            }
            ruleTyped(tv)
        }
        /// the third "-" just made a "---" divider: the caret goes to a new line under it (it would sit on the divider)
        func ruleTyped(_ tv: NSTextView) {
            guard let e = NSApp.currentEvent, e.type == .keyDown, e.characters == "-" else { return }
            let s = tv.string as NSString, sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0 else { return }
            let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
            var end = NSMaxRange(line)
            if end > line.location, s.character(at: end - 1) == 10 { end -= 1 }
            guard sel.location == end else { return }
            let text = s.substring(with: NSRange(location: line.location, length: end - line.location))
            guard text.range(of: "^[ \\t]*---$", options: .regularExpression) != nil else { return }
            if let lm = tv.layoutManager as? JotLayoutManager, lm.codeBlock(atChar: line.location) != nil { return }
            let at = sel.location
            DispatchQueue.main.async { [weak tv] in
                MainActor.assumeIsolated {
                    guard let tv = tv, tv.selectedRange() == NSRange(location: at, length: 0) else { return }
                    tv.insertText("\n", replacementRange: NSRange(location: at, length: 0))
                }
            }
        }
        /// last caret position per note (this Mac only), so a note reopens where it was left
        static let caretKey = "caretPositions"
        static func savedCaret(_ id: String) -> Int? {
            (UserDefaults.standard.dictionary(forKey: caretKey) as? [String: Int])?[id]
        }
        func saveCaret(_ at: Int) {
            guard !noteId.isEmpty else { return }
            var d = UserDefaults.standard.dictionary(forKey: Coordinator.caretKey) as? [String: Int] ?? [:]
            guard d[noteId] != at else { return }
            d[noteId] = at
            UserDefaults.standard.set(d, forKey: Coordinator.caretKey)
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv = tv else { return }
            if !loading { saveCaret(tv.selectedRange().location) }
            MainActor.assumeIsolated { model.linkQuery(linkQuery(tv)) }
            revealLinks(tv)
            fixTypingAttributes(tv)
            MainActor.assumeIsolated { revealCaretInCode(tv) }
        }
        /// a caret in a code block stays inside the block's visible width (scrolls the block sideways if needed)
        func revealCaretInCode(_ tv: NSTextView) {
            guard let lm = tv.layoutManager as? JotLayoutManager, let tc = tv.textContainer else { return }
            let sel = tv.selectedRange(), s = tv.string as NSString
            // the end that moved (a leftward drag moves the start); a selection ending in a newline reveals that line's end
            let startMoved = sel.location != lastSel.location && NSMaxRange(sel) == NSMaxRange(lastSel)
            lastSel = sel
            var at = startMoved ? sel.location : NSMaxRange(sel)
            if sel.length > 0, !startMoved, at > 0, at <= s.length, s.character(at: at - 1) == 10 { at -= 1 }
            guard let o = lm.codeBlock(atChar: at) ?? lm.codeBlock(atChar: at - 1) else { return }
            let lineStart = s.lineRange(for: NSRange(location: min(at, s.length), length: 0)).location
            let x = Coordinator.width(s.substring(with: NSRange(location: lineStart, length: at - lineStart)), Style.mono)
            let off = lm.codeOffset[o] ?? 0, visible = lm.codeVisibleWidth(tc)
            if x - off > visible - 16 { lm.setOffset(x - visible + 16, for: o) }
            else if x - off < 0 { lm.setOffset(x - 16, for: o) }
        }
        /// a [Title](url) link shows its "[" and "](url)" while the caret / selection touches it: restyle when that changes
        func revealLinks(_ tv: NSTextView) {
            guard let ts = tv.textStorage, !revealedLinks.isEmpty || tv.string.contains("](http") else { return }
            let sel = tv.selectedRange()
            let now = MdLink.find(tv.string).filter { MdLink.touches($0, sel) }.map { $0.range }
            guard now != revealedLinks else { return }
            ts.beginEditing(); restyle(ts); ts.endEditing()
        }
        /// after a hidden symbol the caret would take its 1pt clear style (tiny caret, invisible typing):
        /// use the line's real style instead (heading size on heading lines)
        func fixTypingAttributes(_ tv: NSTextView) {
            // (also after a picture's line: its fixed line height would make the next empty line / caret picture-tall)
            let tiny = (tv.typingAttributes[.font] as? NSFont).map { $0.pointSize < 2 } ?? false
            let tall = ((tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 0) > 0
            guard tiny || tall else { return }
            var attrs = Coordinator.baseAttrs
            let s = tv.string as NSString, at = tv.selectedRange().location
            let line = s.substring(with: s.lineRange(for: NSRange(location: min(at, s.length), length: 0)))
            if let m = Coordinator.headingRe.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let level = m.range(at: 1).length
                attrs[.font] = NSFont.systemFont(ofSize: Style.headingSizes[level - 1], weight: level == 1 ? .bold : .semibold)
            }
            tv.typingAttributes = attrs
            if tall, at >= s.length, s.length > 0 {                 // the empty last line is laid out from the typing attributes
                tv.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: s.length - 1, length: 1), actualCharacterRange: nil)
            }
        }

        /// text typed after an unfinished "[[" on the caret's line, or nil
        func linkQuery(_ tv: NSTextView) -> String? { linkStart(tv).map { $0.query } }
        func linkStart(_ tv: NSTextView) -> (start: Int, query: String)? {
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return nil }
            let s = tv.string as NSString
            let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
            let before = s.substring(with: NSRange(location: line.location, length: sel.location - line.location))
            guard let r = before.range(of: "[[", options: .backwards) else { return nil }
            let q = String(before[r.upperBound...])
            if q.contains("]") || q.contains("[") || q.count > 80 { return nil }
            return (line.location + (before as NSString).range(of: "[[", options: .backwards).location, q)
        }
        func acceptLink(_ title: String) {
            guard let tv = tv, let ls = linkStart(tv) else { return }
            let s = tv.string as NSString
            let caret = tv.selectedRange().location
            var end = caret
            if caret + 2 <= s.length, s.substring(with: NSRange(location: caret, length: 2)) == "]]" { end += 2 }
            let range = NSRange(location: ls.start, length: end - ls.start)
            tv.insertText("[[\(title)]]", replacementRange: range)
            MainActor.assumeIsolated { model.autocomplete = [] }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            MainActor.assumeIsolated {
                if !model.autocomplete.isEmpty {
                    switch sel {
                    case #selector(NSResponder.moveDown(_:)): model.acSel = min(model.acSel + 1, model.autocomplete.count - 1); return true
                    case #selector(NSResponder.moveUp(_:)): model.acSel = max(model.acSel - 1, 0); return true
                    case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                        acceptLink(model.autocomplete[min(model.acSel, model.autocomplete.count - 1)]); return true
                    case #selector(NSResponder.cancelOperation(_:)): model.autocomplete = []; return true
                    default: break
                    }
                }
                if sel == #selector(NSResponder.cancelOperation(_:)) { model.escape(); return true }
                if sel == #selector(NSResponder.moveDown(_:)), let o = lastCodeLineOfNote(textView) {
                    (textView as? JotTextView)?.exitBelowCode(o); return true
                }
                if sel == #selector(NSResponder.insertNewline(_:)) { return enterAtLineStart(textView) || continueList(textView) }
                if sel == #selector(NSResponder.insertTab(_:)) { return indentList(textView, out: false) }
                if sel == #selector(NSResponder.insertBacktab(_:)) { return indentList(textView, out: true) }
                if sel == #selector(NSResponder.deleteBackward(_:)) { return smartDelete(textView, forward: false) }
                if sel == #selector(NSResponder.deleteForward(_:)) { return smartDelete(textView, forward: true) }
                if sel == #selector(NSResponder.deleteWordBackward(_:)) || sel == #selector(NSResponder.deleteToBeginningOfLine(_:)) {
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.cleanEmptyMarks(textView) } }
                    return false                                  // AppKit deletes; then drop marks left empty
                }
                return false
            }
        }

        static let listRe = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+] \\[[ xX]\\] |[-*+] |(\\d+|[A-Za-z]|[ivxlcdmIVXLCDM]+)([.)]) |> )")

        struct ListItem { let indent: String, marker: String, token: String?, punct: String, length: Int }
        static func listItem(_ line: String) -> ListItem? {
            let ns = line as NSString
            guard let m = listRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let tok = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
            if let t = tok, t.count > 1, !t.allSatisfy(\.isNumber), ListMarker.fromRoman(t) == nil { return nil }   // "mix." etc.
            return ListItem(indent: ns.substring(with: m.range(at: 1)), marker: ns.substring(with: m.range(at: 2)), token: tok,
                            punct: tok != nil ? ns.substring(with: m.range(at: 4)) : "", length: m.range.length)
        }
        static func depth(_ indent: String) -> Int {
            let tabs = indent.filter { $0 == "\t" }.count, spaces = indent.filter { $0 == " " }.count
            return tabs + (spaces + 2) / 4
        }
        /// marker token of the nearest item above `lineStart` at `depth` under the same parent (nil if none)
        static func prevToken(_ s: NSString, before lineStart: Int, depth d: Int) -> String? {
            var end = lineStart
            while end > 0 {
                let r = s.lineRange(for: NSRange(location: end - 1, length: 0))
                let text = s.substring(with: r).trimmingCharacters(in: .newlines)
                end = r.location
                guard let it = listItem(text) else { return nil }           // the list ended
                let dd = depth(it.indent)
                if dd == d { return it.token }
                if dd < d { return nil }                                    // reached the parent
            }
            return nil
        }

        static let openMarksRe = try! NSRegularExpression(pattern: "^(\\*\\*|\\*|__|_|~~|<u>|`|\\[\\[?)*$")
        /// Return at the (visible) start of a styled line — the caret sits after its marker / opening marks, which are
        /// hidden — puts an empty line above and leaves the line as it was (splitting it would leave "# " / "**" behind
        /// as text); the caret stays at the start of the line's text
        func enterAtLineStart(_ tv: NSTextView) -> Bool {
            let s = tv.string as NSString, sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0, sel.location <= s.length else { return false }
            let c = sel.location
            let line = s.lineRange(for: NSRange(location: c, length: 0))
            guard c > line.location else { return false }                       // at the very start: plain Return does it
            if let lm = tv.layoutManager as? JotLayoutManager, lm.codeBlock(atChar: line.location) != nil { return false }
            let rest = s.substring(with: NSRange(location: c, length: NSMaxRange(line) - c)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return false }                           // empty item / heading: the usual rules
            let before = s.substring(with: NSRange(location: line.location, length: c - line.location)) as NSString
            var i = 0
            while i < before.length, [32, 9].contains(before.character(at: i)) { i += 1 }
            if let it = Coordinator.listItem(before as String) { i = max(i, it.length) }
            else if let m = Coordinator.headingPrefix.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) { i = max(i, m.range.length) }
            let tail = before.substring(from: i)
            let allHidden = (line.location + i ..< c).allSatisfy { isHidden(tv, $0) }
            guard allHidden || Coordinator.openMarksRe.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil else { return false }
            tv.insertText("\n", replacementRange: NSRange(location: line.location, length: 0))
            tv.setSelectedRange(NSRange(location: c + 1, length: 0))
            return true
        }

        /// Return on a list line starts the next item; on an empty item it ends the list
        func continueList(_ tv: NSTextView) -> Bool {
            let s = tv.string as NSString
            let sel = tv.selectedRange()
            let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
            let text = s.substring(with: NSRange(location: line.location, length: sel.location - line.location))
            guard let it = Coordinator.listItem(text) else { return false }
            let after = s.substring(with: NSRange(location: NSMaxRange(sel), length: max(0, NSMaxRange(line) - NSMaxRange(sel))))
            if it.length == (text as NSString).length, after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {   // empty item: remove the marker
                tv.insertText("", replacementRange: NSRange(location: line.location, length: it.length))
                return true
            }
            var next = it.marker
            if let t = it.token {
                let prev = Coordinator.prevToken(s, before: line.location, depth: Coordinator.depth(it.indent))
                next = ListMarker.next(t, prev: prev) + it.punct + " "
            }
            next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            tv.insertText("\n" + it.indent + next, replacementRange: sel)
            return true
        }
        /// Tab / Shift-Tab on a list line nests / un-nests it; numbered items switch style
        /// (1 2 3 → i ii iii, A B C → a b c) and continue any sibling list at the new depth
        func indentList(_ tv: NSTextView, out: Bool) -> Bool {
            let s = tv.string as NSString
            let sel = tv.selectedRange()
            let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
            let text = s.substring(with: line).trimmingCharacters(in: .newlines)
            guard let it = Coordinator.listItem(text) else { return false }
            var indent = it.indent
            if out {
                if indent.hasSuffix("    ") { indent.removeLast(4) }
                else if indent.hasSuffix("\t") { indent.removeLast() }
                else if indent.hasSuffix("  ") { indent.removeLast(2) }
                else { return true }
            } else {
                indent += "    "
            }
            var marker = it.marker
            if let t = it.token {
                let d = Coordinator.depth(it.indent), nd = Coordinator.depth(indent)
                let kind = ListMarker.kind(t, prev: Coordinator.prevToken(s, before: line.location, depth: d)) ?? .number
                if let sib = Coordinator.prevToken(s, before: line.location, depth: nd) {
                    marker = ListMarker.next(sib, prev: nil) + it.punct + " "
                } else {
                    marker = ListMarker.token(1, out ? (nd == 0 ? .number : .lower) : ListMarker.childKind(kind)) + it.punct + " "
                }
            }
            let old = NSRange(location: line.location, length: it.length), new = indent + marker
            tv.insertText(new, replacementRange: old)
            let delta = (new as NSString).length - it.length
            tv.setSelectedRange(NSRange(location: max(line.location + (new as NSString).length, sel.location + delta), length: sel.length))
            return true
        }
        // MARK: deleting around hidden symbols

        /// ← / →, Shift+← / → and ⌥ word jumps step over hidden symbols: a character move always passes one
        /// visible character, a word jump never "moves" across nothing but hidden marks
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            if let e = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(e.type) {
                return MainActor.assumeIsolated {
                    guard new.length == 0 else { return keepSelectable(textView, new, anchor: mouseAnchor, step: 0) }   // drag / shift-click
                    mouseAnchor = offBlockLine(textView, safeCaret(textView, new.location), forward: true)
                    return NSRange(location: mouseAnchor, length: 0)
                }
            }
            guard let e = NSApp.currentEvent, e.type == .keyDown, (123...126).contains(e.keyCode) else { return new }
            let vertical = e.keyCode == 125 || e.keyCode == 126          // ↓ ↑
            let word = e.modifierFlags.contains(.option)
            func step(_ d: Int) -> Bool { word || vertical ? d != 0 : abs(d) == 1 }
            // which end moved: the start (location) or the end (max)
            let movedEnd: (from: Int, to: Int, fixed: Int)
            if old.length == 0, new.length == 0, step(new.location - old.location) {
                movedEnd = (old.location, new.location, new.location)
            } else if new.location == old.location, step(NSMaxRange(new) - NSMaxRange(old)) {
                movedEnd = (NSMaxRange(old), NSMaxRange(new), new.location)
            } else if NSMaxRange(new) == NSMaxRange(old), step(new.location - old.location) {
                movedEnd = (old.location, new.location, NSMaxRange(new))
            } else { return new }
            return MainActor.assumeIsolated {
                guard let ts = textView.textStorage else { return new }
                let len = ts.length, right = movedEnd.to > movedEnd.from
                func anyVisible(_ a: Int, _ b: Int) -> Bool { (a..<b).contains { !isHidden(textView, $0) } }
                var p = movedEnd.to
                if vertical {
                    p = snapOutOfHidden(textView, p, down: e.keyCode == 125)
                } else if word {
                    // keep jumping while the jump only crossed hidden marks
                    if right { while p < len && !anyVisible(movedEnd.from, p) { let n = ts.nextWord(from: p, forward: true); if n <= p { break }; p = n } }
                    else { while p > 0 && !anyVisible(p, movedEnd.from) { let n = ts.nextWord(from: p, forward: false); if n >= p { break }; p = n } }
                } else if right { while p < len && isHidden(textView, p - 1) { p += 1 } }   // passed a hidden char: keep going
                else { while p > 0 && isHidden(textView, p) { p -= 1 } }
                if !vertical, let f = fenceLine(textView, p) {                 // hop over a collapsed ``` line
                    p = right ? min(len, NSMaxRange(f)) : max(0, f.location - 1)
                }
                p = offBlockLine(textView, p, forward: vertical ? e.keyCode == 125 : right)
                if new.length == 0 && old.length == 0 { return NSRange(location: p, length: 0) }
                let lo = min(p, movedEnd.fixed), hi = max(p, movedEnd.fixed)
                return keepSelectable(textView, NSRange(location: lo, length: hi - lo), anchor: movedEnd.fixed, step: vertical ? 0 : (right ? 1 : -1))
            }
        }

        /// a selection never takes a code block's hidden ``` lines: started in the code it stays in the code;
        /// started outside, an end resting on a ``` line stops at that line's edge (crossing a whole block still includes it).
        /// Its ends never rest inside a list marker either (step: -1 / +1 = Shift+← / →, 0 = mouse or vertical)
        func keepSelectable(_ tv: NSTextView, _ r: NSRange, anchor: Int, step: Int) -> NSRange {
            guard r.length > 0, let lm = tv.layoutManager as? JotLayoutManager else { return r }
            if let o = lm.codeBlock(atChar: anchor) ?? lm.codeBlock(atChar: anchor - 1), let inner = lm.codeInner(o),
               anchor >= inner.location, anchor <= NSMaxRange(inner) {
                let lo = max(r.location, inner.location), hi = min(NSMaxRange(r), NSMaxRange(inner))
                return NSRange(location: min(lo, hi), length: max(0, hi - lo))
            }
            var lo = r.location, hi = NSMaxRange(r)
            if anchor <= lo, let f = fenceLine(tv, hi) { hi = max(lo, f.location) }
            if anchor >= hi, let f = fenceLine(tv, lo) { lo = min(hi, NSMaxRange(f)) }
            let s = tv.string as NSString
            func inMarker(_ p: Int) -> NSRange? {
                guard p < s.length else { return nil }
                let line = s.lineRange(for: NSRange(location: p, length: 0))
                guard lm.codeBlock(atChar: line.location) == nil, let m = ListLine.marker(s, line), NSLocationInRange(p, m) else { return nil }
                return m
            }
            let startMoves = anchor >= hi, endMoves = anchor <= lo
            if let m = inMarker(lo) { lo = step < 0 && startMoves && m.location > 0 ? m.location - 1 : NSMaxRange(m) }
            if let m = inMarker(hi), hi > m.location { hi = step > 0 && endMoves ? NSMaxRange(m) : m.location }
            hi = max(hi, lo)
            return NSRange(location: lo, length: hi - lo)
        }

        /// the block whose last code line holds the caret, when that block's closing ``` is the note's last line (↓ leaves it)
        func lastCodeLineOfNote(_ tv: NSTextView) -> Int? {
            let sel = tv.selectedRange(), s = tv.string as NSString
            guard sel.length == 0, let lm = tv.layoutManager as? JotLayoutManager,
                  let o = lm.codeBlock(atChar: sel.location) ?? lm.codeBlock(atChar: sel.location - 1),
                  let close = lm.closingLine(o), NSMaxRange(close) == s.length,
                  sel.location < close.location,
                  NSMaxRange(s.lineRange(for: NSRange(location: sel.location, length: 0))) == close.location else { return nil }
            return o
        }
        /// the hidden ``` line (opening or closing, with its newline) that position p is on, if any
        func fenceLine(_ tv: NSTextView, _ p: Int) -> NSRange? {
            let s = tv.string as NSString
            guard s.length > 0 else { return nil }
            let line = s.lineRange(for: NSRange(location: min(p, s.length), length: 0))
            guard line.length >= 3, s.substring(with: line).hasPrefix("```"), isHidden(tv, line.location) else { return nil }
            return line
        }
        /// where a click may leave the caret: not on a hidden ``` line (→ into the block's code), not between hidden
        /// symbols (→ after them), not in front of a line's marker (→ after "# ", "- ", "1. ", "> ", "- [ ] ")
        func safeCaret(_ tv: NSTextView, _ p: Int) -> Int {
            let s = tv.string as NSString
            if let f = fenceLine(tv, p) {
                var opening = false
                Coordinator.fenceRe.enumerateMatches(in: tv.string, range: NSRange(location: 0, length: s.length)) { m, _, stop in
                    if let m = m, m.range.location == f.location { opening = true; stop.pointee = true }
                }
                return opening ? min(s.length, NSMaxRange(f)) : max(0, f.location - 1)
            }
            let line = s.lineRange(for: NSRange(location: min(p, s.length), length: 0))
            if p == line.location {
                let text = s.substring(with: line).trimmingCharacters(in: .newlines)
                if let it = Coordinator.listItem(text), it.indent.isEmpty { return line.location + it.length }
                if let m = Coordinator.headingPrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { return line.location + m.range.length }
            }
            if isHidden(tv, p - 1) && isHidden(tv, p) {
                var b = p
                while b < s.length && isHidden(tv, b) { b += 1 }
                return b
            }
            return p
        }

        /// ↑ / ↓ can land among hidden symbols: go to the end of the hidden run (so typing lands inside a heading /
        /// after a closing mark), and past lines that are entirely hidden (collapsed ``` lines) to the next real line
        func snapOutOfHidden(_ tv: NSTextView, _ start: Int, down: Bool) -> Int {
            let s = tv.string as NSString
            var p = start
            for _ in 0..<4 {
                var a = p, b = p
                while a > 0 && isHidden(tv, a - 1) { a -= 1 }
                while b < s.length && isHidden(tv, b) { b += 1 }
                if a == b { return p }
                let line = s.lineRange(for: NSRange(location: p, length: 0))
                var lineEnd = NSMaxRange(line)
                if lineEnd > line.location, s.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
                guard a <= line.location && b >= lineEnd else { return b }
                p = down ? min(s.length, NSMaxRange(line)) : max(0, line.location - 1)
                if p == start { return p }
            }
            return p
        }

        /// a character restyle hid (formatting symbol drawn 1pt + clear)
        func isHidden(_ tv: NSTextView, _ i: Int) -> Bool {
            guard let ts = tv.textStorage, i >= 0, i < ts.length else { return false }
            return ((ts.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 15) < 2
        }

        /// Backspace / Delete act only on what's visible: hidden symbols never take a press of their own,
        /// emptied inline formatting loses its marks, and Backspace at a line's start drops its whole marker
        func smartDelete(_ tv: NSTextView, forward: Bool) -> Bool {
            let s = tv.string as NSString, sel = tv.selectedRange()
            if sel.length > 0 {
                tv.insertText("", replacementRange: sel)
                cleanEmptyMarks(tv)
                return true
            }
            let c = sel.location
            if !forward {
                // a. start of a code block's first line: remove the block (empty) or just its ``` lines
                var handled = false
                Coordinator.fenceRe.enumerateMatches(in: tv.string, range: NSRange(location: 0, length: s.length)) { m, _, stop in
                    guard let m = m else { return }
                    let first = s.lineRange(for: NSRange(location: m.range.location, length: 0))
                    guard c == NSMaxRange(first) else { return }
                    let close = s.range(of: "```", options: .backwards, range: m.range)
                    let block = NSRange(location: m.range.location, length: NSMaxRange(close) - m.range.location)
                    let innerRange = NSRange(location: NSMaxRange(first), length: max(0, close.location - NSMaxRange(first)))
                    var inner = s.substring(with: innerRange)
                    if inner.hasSuffix("\n") { inner.removeLast() }
                    if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inner = "" }
                    tv.insertText(inner, replacementRange: block)
                    tv.setSelectedRange(NSRange(location: block.location, length: 0))
                    handled = true; stop.pointee = true
                }
                if handled { return true }
                // a2. start of the line under a media line or a "---" divider: the whole line goes (thumbnail and all)
                let here = s.lineRange(for: NSRange(location: c, length: 0))
                if c == here.location, c > 0, let m = mediaLine(tv, at: c - 1)?.range ?? ruleLine(tv, at: c - 1) {
                    let full = s.lineRange(for: m)
                    tv.insertText("", replacementRange: full)
                    tv.setSelectedRange(NSRange(location: full.location, length: 0))
                    return true
                }
                // b. caret inside / right after a line's marker (# , - , 1. , - [ ] , > ): drop the marker, keep the indent
                let line = s.lineRange(for: NSRange(location: c, length: 0))
                let text = s.substring(with: line).trimmingCharacters(in: .newlines)
                var start = -1, end = -1
                if let it = Coordinator.listItem(text) {
                    start = line.location + (it.indent as NSString).length; end = line.location + it.length
                } else if let m = Coordinator.headingPrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    start = line.location; end = line.location + m.range.length
                }
                if start >= 0, c > start, c <= end {
                    tv.insertText("", replacementRange: NSRange(location: start, length: end - start))
                    tv.setSelectedRange(NSRange(location: start, length: 0))
                    return true
                }
                // c. the nearest visible character to the left
                var i = c - 1
                while i >= 0 && isHidden(tv, i) { i -= 1 }
                if i < 0 { return true }
                // a line break right after a code block: don't join this line onto the closing ``` — go into the block
                if s.character(at: i) == 10, i > 0, let f = fenceLine(tv, i - 1), NSMaxRange(f) == i + 1 {
                    tv.setSelectedRange(NSRange(location: max(0, f.location - 1), length: 0))
                    return true
                }
                let r = s.rangeOfComposedCharacterSequence(at: i)
                tv.insertText("", replacementRange: r)
                tv.setSelectedRange(NSRange(location: r.location, length: 0))
            } else {
                var i = c
                while i < s.length && isHidden(tv, i) { i += 1 }
                if i >= s.length { return true }
                if s.character(at: i) == 10 {
                    let next = NSMaxRange(s.lineRange(for: NSRange(location: i, length: 0)))
                    // the next line is a code block's ``` line: leave the block alone
                    if next < s.length, fenceLine(tv, next) != nil { return true }
                    // the next line is a media line or a "---" divider: it goes whole
                    if next < s.length, let m = mediaLine(tv, at: next)?.range ?? ruleLine(tv, at: next) {
                        tv.insertText("", replacementRange: NSRange(location: i, length: NSMaxRange(m) - i))
                        tv.setSelectedRange(NSRange(location: i, length: 0))
                        return true
                    }
                    // the next line has a marker (heading, list, quote): join its text, without the marker
                    if next < s.length {
                        let text = s.substring(with: s.lineRange(for: NSRange(location: next, length: 0))).trimmingCharacters(in: .newlines)
                        var cut = 0
                        if let it = Coordinator.listItem(text) { cut = it.length }
                        else if let m = Coordinator.headingPrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { cut = m.range.length }
                        if cut > 0 {
                            tv.insertText("", replacementRange: NSRange(location: i, length: next + cut - i))
                            tv.setSelectedRange(NSRange(location: i, length: 0))
                            return true
                        }
                    }
                }
                let r = s.rangeOfComposedCharacterSequence(at: i)
                tv.insertText("", replacementRange: r)
                tv.setSelectedRange(NSRange(location: r.location, length: 0))
            }
            cleanEmptyMarks(tv)
            return true
        }

        /// removes formatting marks left with nothing between them around the caret ("**|**" → "|"), repeatedly
        func cleanEmptyMarks(_ tv: NSTextView) {
            let pairs = [("**", "**"), ("__", "__"), ("~~", "~~"), ("<u>", "</u>"), ("`", "`"), ("*", "*"), ("_", "_")]
            var changed = true
            while changed {
                changed = false
                let s = tv.string as NSString, sel = tv.selectedRange()
                guard sel.length == 0 else { return }
                let c = sel.location
                for (open, close) in pairs {
                    let ol = (open as NSString).length, cl = (close as NSString).length
                    guard c >= ol, c + cl <= s.length,
                          s.substring(with: NSRange(location: c - ol, length: ol)) == open,
                          s.substring(with: NSRange(location: c, length: cl)) == close else { continue }
                    tv.insertText("", replacementRange: NSRange(location: c - ol, length: ol + cl))
                    tv.setSelectedRange(NSRange(location: c - ol, length: 0))
                    changed = true
                    break
                }
            }
        }

        // MARK: media (images / videos in notes)

        /// the caret never stays on a media line (its text is hidden behind the thumbnail) or a "---" divider:
        /// forward → start of the next line, backward → end of the line above
        func offBlockLine(_ tv: NSTextView, _ p: Int, forward: Bool) -> Int {
            guard mediaLine(tv, at: p) != nil || ruleLine(tv, at: p) != nil else { return p }
            let s = tv.string as NSString
            let line = s.lineRange(for: NSRange(location: min(p, s.length), length: 0))
            let hasNext = NSMaxRange(line) <= s.length && line.length > 0 && s.character(at: NSMaxRange(line) - 1) == 10
            if forward && hasNext { return NSMaxRange(line) }
            return line.location > 0 ? line.location - 1 : (hasNext ? NSMaxRange(line) : p)
        }
        /// each media line is exactly as tall as its picture + mediaGap (4 above, 4 below; paragraphSpacing 2 like any line),
        /// so the space under a picture matches the space above. The picture's height depends on the thumbnail (aspect-fit
        /// in mediaMaxWidth × mediaHeight; placeholder until loaded) and the width it may take (as mediaSlot measures it)
        func sizeMedia(_ ts: NSTextStorage) {
            guard let tc = tv?.textContainer else { return }
            let s = ts.string as NSString
            var changes: [(NSRange, NSParagraphStyle)] = []
            ts.enumerateAttribute(.jotMedia, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
                guard let m = v as? MediaAttr else { return }
                let para = s.paragraphRange(for: NSRange(location: r.location, length: 0))
                let cur = (ts.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle) ?? NSParagraphStyle.default
                let lead = Coordinator.width(s.substring(with: NSRange(location: para.location, length: r.location - para.location)))
                let maxW = tc.size.width - 2 * tc.lineFragmentPadding - cur.firstLineHeadIndent - lead
                let h = MediaStore.frame(m, at: .zero, maxWidth: maxW).height + Style.mediaGap
                guard cur.minimumLineHeight != h || cur.maximumLineHeight != h || cur.paragraphSpacingBefore != 0
                        || cur.lineSpacing != 0 || cur.paragraphSpacing != 2 else { return }
                let p = cur.mutableCopy() as! NSMutableParagraphStyle
                p.paragraphSpacingBefore = 0
                p.lineSpacing = 0
                p.minimumLineHeight = h
                p.maximumLineHeight = h
                p.paragraphSpacing = 2
                changes.append((para, p))
            }
            for (r, p) in changes { ts.addAttribute(.paragraphStyle, value: p, range: r) }
        }
        /// the "---" divider line containing position i (as styled, so not one inside a code block), without its line break
        func ruleLine(_ tv: NSTextView, at i: Int) -> NSRange? {
            let s = tv.string as NSString
            guard let ts = tv.textStorage, i >= 0, i <= s.length, s.length > 0 else { return nil }
            var line = s.lineRange(for: NSRange(location: min(i, s.length), length: 0))
            if line.length > 0, s.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
            guard line.length > 0, ts.attribute(.jotRule, at: line.location, effectiveRange: nil) != nil else { return nil }
            return line
        }
        /// the media line containing position i (as styled, so not one inside a code block), in note coordinates
        func mediaLine(_ tv: NSTextView, at i: Int) -> Media.Line? {
            let s = tv.string as NSString
            guard let ts = tv.textStorage, i >= 0, i <= s.length else { return nil }
            let line = s.lineRange(for: NSRange(location: i, length: 0))
            guard let m = Media.lines(s.substring(with: line)).first else { return nil }
            let body = NSRange(location: line.location + m.body.location, length: m.body.length)
            guard body.location < ts.length, ts.attribute(.jotMedia, at: body.location, effectiveRange: nil) != nil else { return nil }
            return Media.Line(range: NSRange(location: line.location + m.range.location, length: m.range.length), body: body, item: m.item)
        }
        /// a thumbnail arrived (or failed): redraw where it is shown
        func mediaLoaded(_ id: String) {
            guard let tv = tv, let ts = tv.textStorage, let lm = tv.layoutManager as? JotLayoutManager else { return }
            for h in lm.mediaHits.values where h.media.id == id { tv.setNeedsDisplay(h.area.insetBy(dx: -2, dy: -2)) }
            ts.beginEditing(); sizeMedia(ts); ts.endEditing()        // the real picture may be shorter than the placeholder
            ts.enumerateAttribute(.jotMedia, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
                if (v as? MediaAttr)?.id == id { lm.invalidateDisplay(forCharacterRange: r) }
            }
        }
        /// pasted / dropped images: JPEG full (≤ 2048 px) + thumb (≤ 640 px), sealed and uploaded, then
        /// `![image](jot-media:<id>)` on a line of its own at the caret (or drop point). Nothing goes in if the upload fails.
        func addImages(_ datas: [Data], at drop: Int?) {
            MainActor.assumeIsolated {
                guard let key = model.repo.key, !datas.isEmpty else { return }
                let api = model.repo.api, note = noteId
                model.tell(datas.count == 1 ? "Adding image…" : "Adding \(datas.count) images…")
                Task { @MainActor in
                    var lines: [String] = [], failure: String?
                    for d in datas {
                        do {
                            guard let enc = await Task.detached(operation: { MediaImport.encode(d) }).value else { throw JotError.bad("not an image Jot can read") }
                            let id = JotCrypto.newId()
                            let thumb = try JotCrypto.sealMedia(key, id: id, part: "thumb", enc.thumb)
                            try await api.putMedia(id, part: "full", try JotCrypto.sealMedia(key, id: id, part: "full", enc.full))
                            try await api.putMedia(id, part: "thumb", thumb)
                            if let img = NSImage(data: enc.thumb) { MediaStore.shared.remember(id, sealedThumb: thumb, image: img) }
                            lines.append("![image](jot-media:\(id))")
                        } catch { failure = "\(error)" }
                    }
                    if let f = failure { model.tell("Couldn't add the image: \(f)", for: 6) } else { model.tell(nil) }
                    self.insertMedia(lines, note: note, at: drop)
                }
            }
        }
        /// media lines go on lines of their own; the caret ends up on the line after them
        func insertMedia(_ lines: [String], note: String, at drop: Int?) {
            guard !lines.isEmpty else { return }
            let md = lines.joined(separator: "\n")
            guard let tv = tv, noteId == note else {
                // the note was closed while uploading: add them at its end
                MainActor.assumeIsolated {
                    if let b = model.repo.content(note)?.body { model.repo.edit(note, body: b + (b.hasSuffix("\n") ? "" : "\n") + md); model.syncSoon() }
                }
                return
            }
            let s = tv.string as NSString
            let at = min(drop ?? tv.selectedRange().location, s.length)
            let line = s.lineRange(for: NSRange(location: at, length: 0))
            let nextIsBreak = at < s.length && s.character(at: at) == 10
            let text = (at > line.location ? "\n" : "") + md + (nextIsBreak ? "" : "\n")
            tv.insertText(text, replacementRange: NSRange(location: at, length: 0))
            tv.setSelectedRange(NSRange(location: min((tv.string as NSString).length, at + (text as NSString).length + (nextIsBreak ? 1 : 0)), length: 0))
            tv.window?.makeFirstResponder(tv)
        }

        // MARK: formatting (format bar, ⌘B / ⌘I / ⌘U / ⌘S)

        /// actions: bold italic strike underline code codeblock quote h1 h2 h3 ol ul task
        func format(_ action: String) {
            guard let tv = tv else { return }
            switch action {
            case "bold": wrap("**", "**")
            case "italic": wrap("*", "*")
            case "strike": wrap("~~", "~~")
            case "underline": wrap("<u>", "</u>")
            case "code": if tv.selectedRange().length > 0 { wrap("`", "`") } else { codeLine() }
            case "codeblock": codeBlock()
            case "h1", "h2", "h3": heading(Int(action.dropFirst()) ?? 1)
            case "quote", "ol", "ul", "task": lineMarker(action)
            default: break
            }
            tv.window?.makeFirstResponder(tv)
        }

        /// the parts of a selection that marks can wrap: per line, without the line break, the line's marker
        /// (# , - , 1. , - [ ] , > ) and spaces at either end (the marks only work inside a line, hugging the text)
        func markable(_ s: NSString, _ sel: NSRange) -> [NSRange] {
            guard sel.length > 0 else { return [sel] }
            var out: [NSRange] = [], at = sel.location
            while at < NSMaxRange(sel) {
                let line = s.lineRange(for: NSRange(location: at, length: 0))
                var end = NSMaxRange(line)
                while end > line.location, s.character(at: end - 1) == 10 || s.character(at: end - 1) == 13 { end -= 1 }
                var a = max(sel.location, line.location), b = min(NSMaxRange(sel), end)
                let text = s.substring(with: NSRange(location: line.location, length: end - line.location))
                var marker = 0
                if let it = Coordinator.listItem(text) { marker = it.length }
                else if let m = Coordinator.headingPrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { marker = m.range.length }
                a = max(a, line.location + marker)
                while a < b, s.character(at: a) == 32 || s.character(at: a) == 9 { a += 1 }
                while b > a, s.character(at: b - 1) == 32 || s.character(at: b - 1) == 9 { b -= 1 }
                if b > a { out.append(NSRange(location: a, length: b - a)) }
                if NSMaxRange(line) <= at { break }
                at = NSMaxRange(line)
            }
            return out
        }

        /// wraps the selection in open/close marks, or removes them if it's already wrapped (marks inside or around it).
        /// Over line breaks / whole lines, each line's text is wrapped (or unwrapped) on its own
        func wrap(_ open: String, _ close: String) {
            guard let tv = tv else { return }
            let s0 = tv.string as NSString
            let parts = markable(s0, tv.selectedRange())
            if parts.isEmpty { return }
            if parts.count > 1 { wrapLines(open, close, parts); return }
            if parts[0] != tv.selectedRange() { tv.setSelectedRange(parts[0]) }
            let s = tv.string as NSString, sel = tv.selectedRange()
            let ol = (open as NSString).length, cl = (close as NSString).length
            let inner = s.substring(with: sel)
            if inner.count >= open.count + close.count, inner.hasPrefix(open), inner.hasSuffix(close) {
                let plain = String(inner.dropFirst(open.count).dropLast(close.count))
                tv.insertText(plain, replacementRange: sel)
                tv.setSelectedRange(NSRange(location: sel.location, length: (plain as NSString).length))
                return
            }
            if sel.location >= ol, NSMaxRange(sel) + cl <= s.length,
               s.substring(with: NSRange(location: sel.location - ol, length: ol)) == open,
               s.substring(with: NSRange(location: NSMaxRange(sel), length: cl)) == close {
                tv.insertText(inner, replacementRange: NSRange(location: sel.location - ol, length: ol + sel.length + cl))
                tv.setSelectedRange(NSRange(location: sel.location - ol, length: sel.length))
                return
            }
            tv.insertText(open + inner + close, replacementRange: sel)
            tv.setSelectedRange(NSRange(location: sel.location + ol, length: sel.length))
        }
        /// several lines at once, as one edit: unwrapped if every part already is wrapped, else every part gets wrapped
        func wrapLines(_ open: String, _ close: String, _ parts: [NSRange]) {
            guard let tv = tv, let first = parts.first, let last = parts.last else { return }
            let s = tv.string as NSString
            let ol = (open as NSString).length, cl = (close as NSString).length
            let wrapped = { (r: NSRange) -> Bool in
                let t = s.substring(with: r)
                return t.count >= open.count + close.count && t.hasPrefix(open) && t.hasSuffix(close)
            }
            let off = parts.allSatisfy(wrapped)
            let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            var out = "", at = span.location
            for r in parts {
                out += s.substring(with: NSRange(location: at, length: r.location - at))
                let t = s.substring(with: r)
                if off { out += (t as NSString).substring(with: NSRange(location: ol, length: r.length - ol - cl)) }
                else if wrapped(r) { out += t }
                else { out += open + t + close }
                at = NSMaxRange(r)
            }
            tv.insertText(out, replacementRange: span)
            tv.setSelectedRange(NSRange(location: span.location, length: (out as NSString).length))
        }

        /// replaces the selected lines with f(lines); keeps a lone caret at the same distance from its line's end
        func editLines(_ f: ([String]) -> [String]) {
            guard let tv = tv else { return }
            let s = tv.string as NSString, sel = tv.selectedRange()
            var block = s.lineRange(for: sel)
            if block.length > 0, s.substring(with: NSRange(location: NSMaxRange(block) - 1, length: 1)) == "\n" { block.length -= 1 }
            let lines = s.substring(with: block).components(separatedBy: "\n")
            let fromEnd = NSMaxRange(block) - NSMaxRange(sel)
            let out = f(lines).joined(separator: "\n")
            tv.insertText(out, replacementRange: block)
            let len = (out as NSString).length
            if sel.length == 0 && lines.count == 1 { tv.setSelectedRange(NSRange(location: block.location + max(0, len - fromEnd), length: 0)) }
            else { tv.setSelectedRange(NSRange(location: block.location, length: len)) }
        }

        static let headingPrefix = try! NSRegularExpression(pattern: "^(#{1,6}) +")
        /// "# " … "### " on the selected lines; choosing a line's current level removes it
        func heading(_ n: Int) {
            editLines { lines in
                lines.map { line in
                    let ns = line as NSString
                    var body = line, level = 0
                    if let m = Coordinator.headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                        level = m.range(at: 1).length; body = ns.substring(from: m.range.length)
                    }
                    return level == n ? body : String(repeating: "#", count: n) + " " + body
                }
            }
        }

        /// quote / ordered / bullet / task markers on the selected lines; if every line already has it, it's removed.
        /// Any other list or quote marker on a line is replaced (indent kept).
        func lineMarker(_ kind: String) {
            editLines { lines in
                let parsed = lines.map { line -> (indent: String, marker: String, body: String) in
                    guard let it = Coordinator.listItem(line) else {
                        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                        return (indent, "", String(line.dropFirst(indent.count)))
                    }
                    return (it.indent, it.marker, (line as NSString).substring(from: it.length))
                }
                func isKind(_ m: String) -> Bool {
                    switch kind {
                    case "quote": return m == "> "
                    case "task": return m.contains("[")
                    case "ul": return !m.contains("[") && (m == "- " || m == "* " || m == "+ ")
                    default: return m.first.map { $0.isNumber || $0.isLetter } ?? false
                    }
                }
                let content = parsed.filter { !$0.body.isEmpty || !$0.marker.isEmpty }
                let remove = !content.isEmpty && content.allSatisfy { isKind($0.marker) }
                var n = 0
                return parsed.map { p in
                    if p.body.isEmpty && p.marker.isEmpty && parsed.count > 1 { return p.indent }   // blank line in a multi-line selection
                    if remove { return p.indent + p.body }
                    n += 1
                    let mk = kind == "quote" ? "> " : kind == "task" ? "- [ ] " : kind == "ul" ? "- " : "\(n). "
                    return p.indent + mk + p.body
                }
            }
        }

        /// wraps the selected lines in ``` fences (an empty line gets an empty block with the caret inside)
        /// toggles a ``` block: inside one → its ``` lines are removed; otherwise the selected lines get wrapped
        func codeBlock() {
            guard let tv = tv else { return }
            let s = tv.string as NSString, sel = tv.selectedRange()
            var unwrapped = false
            Coordinator.fenceRe.enumerateMatches(in: tv.string, range: NSRange(location: 0, length: s.length)) { m, _, stop in
                guard let m = m, sel.location >= m.range.location, NSMaxRange(sel) <= NSMaxRange(m.range) else { return }
                let first = s.lineRange(for: NSRange(location: m.range.location, length: 0))
                let close = s.range(of: "```", options: .backwards, range: m.range)
                let blockRange = NSRange(location: m.range.location, length: NSMaxRange(close) - m.range.location)
                var inner = s.substring(with: NSRange(location: NSMaxRange(first), length: max(0, close.location - NSMaxRange(first))))
                if inner.hasSuffix("\n") { inner.removeLast() }
                tv.insertText(inner, replacementRange: blockRange)
                tv.setSelectedRange(NSRange(location: blockRange.location, length: (inner as NSString).length))
                unwrapped = true; stop.pointee = true
            }
            if unwrapped { return }
            var block = s.lineRange(for: sel)
            if block.length > 0, s.substring(with: NSRange(location: NSMaxRange(block) - 1, length: 1)) == "\n" { block.length -= 1 }
            let text = s.substring(with: block)
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                tv.insertText("```\n\n```", replacementRange: block)
                tv.setSelectedRange(NSRange(location: block.location + 4, length: 0))
            } else {
                tv.insertText("```\n" + text + "\n```", replacementRange: block)
                tv.setSelectedRange(NSRange(location: block.location + 4, length: (text as NSString).length))
            }
        }

        /// Code with nothing selected: the caret's line (after any list / heading marker) becomes inline code,
        /// or stops being code if it already is
        func codeLine() {
            guard let tv = tv else { return }
            let s = tv.string as NSString, c = tv.selectedRange().location
            let line = s.lineRange(for: NSRange(location: c, length: 0))
            let text = s.substring(with: line).trimmingCharacters(in: .newlines)
            var start = 0
            if let it = Coordinator.listItem(text) { start = it.length }
            else if let m = Coordinator.headingPrefix.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { start = m.range.length }
            let contentRange = NSRange(location: line.location + start, length: (text as NSString).length - start)
            let content = s.substring(with: contentRange)
            let lead = content.prefix { $0 == " " || $0 == "\t" }.count
            let body = content.dropFirst(lead)
            let r = NSRange(location: contentRange.location + lead, length: (String(body) as NSString).length)
            if body.count >= 2, body.hasPrefix("`"), body.hasSuffix("`") {
                let plain = String(body.dropFirst().dropLast())
                tv.insertText(plain, replacementRange: r)
                tv.setSelectedRange(NSRange(location: r.location + (plain as NSString).length, length: 0))
            } else {
                tv.insertText("`" + body + "`", replacementRange: r)
                tv.setSelectedRange(NSRange(location: r.location + r.length + 1, length: 0))   // inside the closing `
            }
        }

        // MARK: clicks

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let str = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            return MainActor.assumeIsolated {
                if str.hasPrefix("jot-link:") {
                    model.openLink(String(str.dropFirst(9)).removingPercentEncoding ?? "")
                } else if str.hasPrefix("jot-tag:") {
                    model.openSwitcher("#" + (String(str.dropFirst(8)).removingPercentEncoding ?? ""))
                } else if str.hasPrefix("jot-check:"), let at = Int(str.dropFirst(10)) {
                    let s = textView.string as NSString
                    guard at + 3 <= s.length else { return true }
                    let box = s.substring(with: NSRange(location: at, length: 3)), r = NSRange(location: at, length: 3)
                    let new = box == "[ ]" ? "[x]" : "[ ]"
                    // ticked in place: the caret / selection and the scroll position stay where they were
                    // (insertText would move the caret to the box and scroll there)
                    let keep = textView.selectedRanges
                    if textView.shouldChangeText(in: r, replacementString: new) {
                        textView.textStorage?.replaceCharacters(in: r, with: new)
                        textView.didChangeText()
                    }
                    textView.selectedRanges = keep
                } else if let u = URL(string: str), u.scheme == "http" || u.scheme == "https" {
                    NSWorkspace.shared.open(u)
                }
                return true
            }
        }

        // MARK: styling

        nonisolated func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
            if mask.contains(.editedCharacters) { MainActor.assumeIsolated { restyle(ts) } }
        }

        static let headingRe = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+(.*)$", options: .anchorsMatchLines)
        static let checkRe = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+] (\\[[ xX]\\]))(.*)$", options: .anchorsMatchLines)
        static let bulletRe = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]) (?!\\[[ xX]\\])", options: .anchorsMatchLines)
        static let numberRe = try! NSRegularExpression(pattern: "^[ \\t]*((?:\\d+|[A-Za-z]|[ivxlcdmIVXLCDM]+)[.)]) ", options: .anchorsMatchLines)
        static let ruleRe = try! NSRegularExpression(pattern: "^[ \\t]*-{3,}[ \\t]*$", options: .anchorsMatchLines)
        static let quoteRe = try! NSRegularExpression(pattern: "^(>) (.*)$", options: .anchorsMatchLines)
        static let fenceRe = try! NSRegularExpression(pattern: "^```[^\\n]*\\n[\\s\\S]*?^```\\s*$", options: .anchorsMatchLines)
        static let codeRe = try! NSRegularExpression(pattern: "`[^`\\n]+`")
        static let boldRe = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
        static let italicRe = try! NSRegularExpression(pattern: "(?<![*\\w])([*_])(?=\\S)([^*_\\n]+?)(?<=\\S)\\1(?![*\\w])")
        static let urlRe = try! NSRegularExpression(pattern: "https?://[^\\s<>()\\[\\]]+[^\\s<>()\\[\\].,;:!?'\"]")
        static let underlineRe = try! NSRegularExpression(pattern: "<u>(.+?)</u>")
        static let strikeRe = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")

        func restyle(_ ts: NSTextStorage?) {
            guard let ts = ts else { return }
            let s = ts.string as NSString, all = NSRange(location: 0, length: s.length)
            let str = ts.string
            let dim = NSColor.tertiaryLabelColor, soft = NSColor.secondaryLabelColor, accent = NSColor.controlAccentColor
            // formatting symbols (# ** * ~~ <u> ` ```) stay in the text but are never shown (tiny + clear)
            func hide(_ r: NSRange) {
                guard r.length > 0 else { return }
                ts.addAttribute(.font, value: Style.tiny, range: r)
                ts.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            }
            func marks(_ m: NSRange, _ open: Int, _ close: Int) {
                hide(NSRange(location: m.location, length: open)); hide(NSRange(location: NSMaxRange(m) - close, length: close))
            }
            func each(_ re: NSRegularExpression, _ f: (NSTextCheckingResult) -> Void) { re.enumerateMatches(in: str, range: all) { m, _, _ in if let m = m { f(m) } } }
            func trait(_ r: NSRange, _ t: NSFontTraitMask) {
                ts.enumerateAttribute(.font, in: r) { v, sub, _ in
                    let f = (v as? NSFont) ?? Style.base
                    ts.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: t), range: sub)
                }
            }
            ts.setAttributes(Coordinator.baseAttrs, range: all)
            each(Coordinator.headingRe) { m in
                let level = m.range(at: 1).length
                ts.addAttribute(.font, value: NSFont.systemFont(ofSize: Style.headingSizes[level - 1], weight: level == 1 ? .bold : .semibold), range: m.range)
                let prefix = NSRange(location: m.range.location, length: m.range(at: 2).location - m.range.location)
                hide(prefix)
            }
            each(Coordinator.bulletRe) { m in
                ts.addAttribute(.foregroundColor, value: NSColor.clear, range: m.range(at: 2))
                ts.addAttribute(.jotBullet, value: Coordinator.depth(s.substring(with: m.range(at: 1))), range: m.range(at: 2))
                ts.addAttribute(.kern, value: Style.oneWidth + Style.markerGap - Style.dashWidth, range: m.range(at: 2))
                let lead = Coordinator.width(s.substring(with: m.range(at: 1)))
                ts.addAttribute(.paragraphStyle, value: Coordinator.listPara(first: Style.hang, wrap: Style.hang + lead + Style.oneWidth + Style.markerGap + Style.spaceWidth),
                                range: s.paragraphRange(for: m.range))
            }
            each(Coordinator.numberRe) { m in
                let tok = String(s.substring(with: m.range(at: 1)).dropLast())
                guard tok.count == 1 || tok.allSatisfy(\.isNumber) || ListMarker.fromRoman(tok) != nil else { return }
                let mk = m.range(at: 1)
                ts.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: mk)
                ts.addAttribute(.font, value: Style.numberFont, range: mk)
                let w = (s.substring(with: mk) as NSString).size(withAttributes: [.font: Style.numberFont]).width
                // right-aligned so the last digit lines up: "1." starts at the text margin, "10." hangs left of it
                let pad = max(0, Style.hang + Style.oneWidth - w)
                ts.addAttribute(.kern, value: Style.markerGap, range: NSRange(location: NSMaxRange(mk) - 1, length: 1))
                let line = s.lineRange(for: m.range)
                let lead = Coordinator.width(s.substring(with: NSRange(location: line.location, length: mk.location - line.location)))
                ts.addAttribute(.paragraphStyle, value: Coordinator.listPara(first: pad, wrap: lead + pad + w + Style.markerGap + Style.spaceWidth),
                                range: s.paragraphRange(for: m.range))
            }
            each(Coordinator.ruleRe) { m in
                ts.addAttribute(.foregroundColor, value: NSColor.clear, range: m.range)
                ts.addAttribute(.jotRule, value: true, range: m.range)
            }
            each(Coordinator.quoteRe) { m in
                // ">" shrunk + kerned so the text starts quoteIndent in; the block is drawn by JotLayoutManager
                let gt = m.range(at: 1)
                ts.addAttribute(.foregroundColor, value: NSColor.clear, range: gt)
                ts.addAttribute(.font, value: Style.tiny, range: gt)
                let w = Coordinator.width(">", Style.tiny)
                ts.addAttribute(.kern, value: Style.quoteIndent - w, range: gt)
                ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: m.range(at: 2))
                let para = s.paragraphRange(for: m.range)
                ts.addAttribute(.jotQuote, value: true, range: para)
                ts.addAttribute(.paragraphStyle, value: Coordinator.listPara(first: Style.hang, wrap: Style.hang + Style.quoteIndent + Style.spaceWidth, spaced: false), range: para)
            }
            each(Coordinator.checkRe) { m in
                // "- [ ]" shrunk + kerned to the width of "1." + gap, so item text lines up with bullets / numbers;
                // the whole marker is the click target, the box is drawn by JotLayoutManager
                let marker = m.range(at: 2), box = m.range(at: 3), checked = s.substring(with: box) != "[ ]"
                ts.addAttribute(.foregroundColor, value: NSColor.clear, range: marker)
                ts.addAttribute(.font, value: Style.tiny, range: marker)
                ts.addAttribute(.link, value: "jot-check:\(box.location)", range: marker)
                ts.addAttribute(.jotCheck, value: checked, range: NSRange(location: marker.location, length: 1))
                let w = Coordinator.width(s.substring(with: marker), Style.tiny)
                ts.addAttribute(.kern, value: Style.oneWidth + Style.markerGap - w, range: NSRange(location: NSMaxRange(marker) - 1, length: 1))
                let lead = Coordinator.width(s.substring(with: m.range(at: 1)))
                ts.addAttribute(.paragraphStyle, value: Coordinator.listPara(first: Style.hang, wrap: Style.hang + lead + Style.oneWidth + Style.markerGap + Style.spaceWidth),
                                range: s.paragraphRange(for: m.range))
                if checked {
                    ts.addAttribute(.foregroundColor, value: soft, range: m.range(at: 4))
                    ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 4))
                }
            }
            // a list item's indented follow-on lines ("  Summary text") line up with the item's text
            var at = 0, itemHead: CGFloat? = nil
            while at < s.length {
                let line = s.lineRange(for: NSRange(location: at, length: 0))
                let text = s.substring(with: line).trimmingCharacters(in: .newlines)
                let lead = String(text.prefix { $0 == " " || $0 == "\t" })
                if let it = Coordinator.listItem(text) {
                    itemHead = it.marker == "> " ? nil : (ts.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent
                } else if let h = itemHead, !lead.isEmpty, lead.count < text.count {
                    ts.addAttribute(.paragraphStyle, value: Coordinator.listPara(first: max(0, h - Coordinator.width(lead)), wrap: h, spaced: false), range: line)
                } else { itemHead = nil }
                at = NSMaxRange(line)
            }
            // media lines ![alt](jot-media:<id>): the line becomes exactly as tall as its picture (sizeMedia, at the end)
            let mediaLines = Media.lines(str)
            if !mediaLines.isEmpty { MainActor.assumeIsolated { MediaStore.shared.use(api: model.repo.api, key: model.repo.key) } }
            each(Coordinator.boldRe) { m in trait(m.range, .boldFontMask); marks(m.range, 2, 2) }
            each(Coordinator.italicRe) { m in trait(m.range(at: 2), .italicFontMask); marks(m.range, 1, 1) }
            each(Coordinator.underlineRe) { m in
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
                marks(m.range, 3, 4)
            }
            each(Coordinator.strikeRe) { m in
                ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
                ts.addAttribute(.foregroundColor, value: soft, range: m.range(at: 1))
                marks(m.range, 2, 2)
            }
            each(Coordinator.urlRe) { m in
                ts.addAttribute(.link, value: s.substring(with: m.range), range: m.range)
                ts.addAttribute(.foregroundColor, value: accent, range: m.range)
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            }
            each(Logic.tagRe) { m in
                let r = NSRange(location: m.range(at: 2).location - 1, length: m.range(at: 2).length + 1)
                ts.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: r)
                ts.addAttribute(.link, value: "jot-tag:" + (s.substring(with: m.range(at: 2)).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""), range: r)
            }
            each(Logic.linkRe) { m in
                let inner = s.substring(with: m.range(at: 1))
                let target = String(inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0])
                let exists = MainActor.assumeIsolated { model.index.resolve(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].description) != nil }
                ts.addAttribute(.link, value: "jot-link:" + (target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""), range: m.range)
                ts.addAttribute(.foregroundColor, value: exists ? accent : accent.withAlphaComponent(0.55), range: m.range(at: 1))
                ts.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location, length: 2))
                ts.addAttribute(.foregroundColor, value: dim, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
                if !exists { ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: m.range(at: 1)) }
            }
            // [Title](https://…): the title in link blue, a click opens the url; "[" and "](url)" are hidden, or dim
            // while the caret / selection touches the link (revealLinks restyles when that changes)
            let sel = tv?.selectedRange()
            revealedLinks = []
            for l in MdLink.find(str) {
                let mark = NSRange(location: l.range.location, length: 1)
                let tail = NSRange(location: NSMaxRange(l.title), length: NSMaxRange(l.range) - NSMaxRange(l.title))
                ts.addAttribute(.link, value: s.substring(with: l.url), range: l.title)
                ts.addAttribute(.foregroundColor, value: accent, range: l.title)
                ts.removeAttribute(.link, range: tail)                 // the bare-url / #tag styling of the url part
                ts.removeAttribute(.underlineStyle, range: tail)
                if let sel = sel, MdLink.touches(l, sel) {
                    revealedLinks.append(l.range)
                    ts.addAttribute(.foregroundColor, value: dim, range: mark)
                    ts.addAttribute(.foregroundColor, value: dim, range: tail)
                } else { hide(mark); hide(tail) }
            }
            each(Coordinator.codeRe) { m in
                ts.addAttribute(.font, value: Style.mono, range: m.range)
                ts.removeAttribute(.link, range: m.range)
                ts.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: NSRange(location: m.range.location + 1, length: m.range.length - 2))
                marks(m.range, 1, 1)
            }
            // media lines: the text (from "!") is always hidden behind the thumbnail; the caret never stops on the line
            // (offBlockLine), Backspace on the line below removes it
            // (after the inline styles, which an id with "_" or "*" could otherwise catch)
            for ml in mediaLines {
                for k in [NSAttributedString.Key.link, .underlineStyle, .strikethroughStyle, .backgroundColor, .kern] { ts.removeAttribute(k, range: ml.body) }
                ts.addAttribute(.jotMedia, value: MediaAttr(ml.item), range: ml.body)
                hide(ml.body)
            }
            if !mediaLines.isEmpty { sizeMedia(ts) }
            let lm = tv?.layoutManager as? JotLayoutManager
            lm?.codeWidth = [:]; lm?.codeLanguage = [:]; lm?.codeLabelRects = [:]; lm?.mediaHits = [:]
            MainActor.assumeIsolated { if InlineVideo.current != nil { (tv as? JotTextView)?.queuePlaceInlineVideo() } }
            var ordinal = 0
            each(Coordinator.fenceRe) { m in
                // the match can run on over blank lines after the closing ```; the block ends at that ```
                let close = s.range(of: "```", options: .backwards, range: m.range)
                let block = NSRange(location: m.range.location, length: NSMaxRange(close) - m.range.location)
                ts.setAttributes(Coordinator.baseAttrs, range: block)
                ts.addAttribute(.font, value: Style.mono, range: block)
                ts.addAttribute(.foregroundColor, value: CodeTheme.plain, range: block)
                ts.addAttribute(.paragraphStyle, value: Coordinator.codePara, range: block)      // long lines don't wrap
                ts.addAttribute(.jotCodeBlock, value: ordinal, range: block)
                let first = s.lineRange(for: NSRange(location: block.location, length: 0))
                let last = s.lineRange(for: NSRange(location: close.location, length: 0))
                // the code between the ``` lines: colours (fence language, else detected), widest line, language label
                let inner = NSRange(location: NSMaxRange(first), length: max(0, last.location - 1 - NSMaxRange(first)))
                let code = inner.length > 0 ? s.substring(with: inner) : ""
                let tag = s.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(3).trimmingCharacters(in: .whitespaces)
                if let r = Highlighter.shared.highlight(code, lang: tag) {
                    for sp in r.spans {
                        guard let col = CodeTheme.color(sp.cls), NSMaxRange(sp.range) <= inner.length else { continue }
                        let at = NSRange(location: inner.location + sp.range.location, length: sp.range.length)
                        ts.addAttribute(.foregroundColor, value: col, range: at)
                        if CodeTheme.italic.contains(sp.cls) {
                            ts.addAttribute(.font, value: NSFontManager.shared.convert(Style.mono, toHaveTrait: .italicFontMask), range: at)
                        }
                    }
                    lm?.codeLanguage[ordinal] = r.language
                }
                lm?.codeWidth[ordinal] = code.components(separatedBy: "\n").map { Coordinator.width($0, Style.mono) }.max() ?? 0
                ordinal += 1
                // the ``` lines collapse to (almost) nothing
                hide(NSRange(location: first.location, length: max(0, first.length - 1)))
                ts.addAttribute(.paragraphStyle, value: Coordinator.codeTopPara, range: first)    // room for the language dropdown
                if last.location != first.location {
                    ts.addAttribute(.paragraphStyle, value: Coordinator.codeBottomPara, range: NSRange(location: last.location, length: NSMaxRange(block) - last.location))
                }
                hide(NSRange(location: last.location, length: NSMaxRange(close) - last.location))
            }
        }
    }
}

extension Notification.Name {
    static let jotFocusEditor = Notification.Name("jotFocusEditor")
    static let jotFormat = Notification.Name("jotFormat")     // object: a format action, see Coordinator.format
}
