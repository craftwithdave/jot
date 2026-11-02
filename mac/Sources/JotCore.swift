// Jot core: end-to-end encryption, notes logic (titles, [[links]], tags, search, related notes) and sync.
// Platform-neutral on purpose (CryptoKit on macOS, swift-crypto on Linux) so it is tested on the VPS
// (mac//test, Docker swift:6.0-noble) against the reference in spec (logic.mjs, client.mjs,
// crypto.mjs) through fixtures.json / vectors.json. Change the spec first, then this file and Android's Logic.kt.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

enum JotError: Error, CustomStringConvertible {
    case http(Int, String), bad(String)
    var description: String {
        switch self { case .http(let c, let m): return c == 0 ? m : "\(m) (\(c))"; case .bad(let m): return m }
    }
}

// MARK: - crypto (same scheme as Drop, label "notes-dk-v1")

enum JotCrypto {
    static let wrapLabel = "notes-dk-v1"

    /// PBKDF2-HMAC-SHA256 → 64 bytes: kek = [0,32), auth = base64([32,64))
    static func fromPassphrase(_ pass: String, saltB64: String, iter: Int) throws -> (kek: SymmetricKey, auth: String) {
        guard let salt = Data(base64Encoded: saltB64) else { throw JotError.bad("bad salt") }
        let bits = pbkdf2(Data(pass.precomposedStringWithCompatibilityMapping.utf8), salt: salt, iter: iter, length: 64)
        return (SymmetricKey(data: bits.prefix(32)), bits.suffix(32).base64EncodedString())
    }

    static func pbkdf2(_ password: Data, salt: Data, iter: Int, length: Int) -> Data {
        #if canImport(CommonCrypto)
        var out = Data(count: length)
        let rc = out.withUnsafeMutableBytes { o in password.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                 s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 UInt32(iter), o.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
        } } }
        if rc == 0 { return out }
        #endif
        let key = SymmetricKey(data: password)
        var acc = Data()
        var block: UInt32 = 1
        while acc.count < length {
            var first = salt
            withUnsafeBytes(of: block.bigEndian) { first.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: first, using: key))
            var t = [UInt8](u)
            if iter > 1 {
                for _ in 1..<iter {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    let ub = [UInt8](u)
                    for j in 0..<32 { t[j] ^= ub[j] }
                }
            }
            acc.append(contentsOf: t)
            block += 1
        }
        return acc.prefix(length)
    }

    /// iv[12] || ciphertext || tag[16], AES-256-GCM with a string AAD
    static func seal(_ key: SymmetricKey, _ plain: Data, aad: String) throws -> Data {
        guard let c = try AES.GCM.seal(plain, using: key, authenticating: Data(aad.utf8)).combined else { throw JotError.bad("seal failed") }
        return c
    }
    static func open(_ key: SymmetricKey, _ all: Data, aad: String) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: all), using: key, authenticating: Data(aad.utf8))
    }
    static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        for i in 0..<n { b[i] = UInt8.random(in: 0...255) }   // SystemRandomNumberGenerator: CSPRNG on macOS and Linux
        return Data(b)
    }
    static func wrapDataKey(kek: SymmetricKey, dk: Data) throws -> String { try seal(kek, dk, aad: wrapLabel).base64EncodedString() }
    static func unwrapDataKey(kek: SymmetricKey, wrap: String) throws -> Data {
        guard let w = Data(base64Encoded: wrap) else { throw JotError.bad("bad wrap") }
        return try open(kek, w, aad: wrapLabel)
    }
    static func sealNote(_ key: SymmetricKey, id: String, _ c: NoteContent) throws -> String {
        try seal(key, try JSONEncoder().encode(c), aad: id).base64EncodedString()
    }
    static func openNote(_ key: SymmetricKey, id: String, _ b64: String) throws -> NoteContent {
        guard let d = Data(base64Encoded: b64) else { throw JotError.bad("bad note") }
        return try JSONDecoder().decode(NoteContent.self, from: try open(key, d, aad: id))
    }
    static func newId() -> String {
        randomBytes(16).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    /// media (images / videos in notes): raw bytes (not base64), iv[12] || AES-GCM(DK, bytes, aad "jot-media:<id>:<part>"),
    /// part "full" (the file) or "thumb" (a small JPEG preview)
    static func sealMedia(_ key: SymmetricKey, id: String, part: String, _ bytes: Data) throws -> Data {
        try seal(key, bytes, aad: "jot-media:\(id):\(part)")
    }
    static func openMedia(_ key: SymmetricKey, id: String, part: String, _ sealed: Data) throws -> Data {
        try open(key, sealed, aad: "jot-media:\(id):\(part)")
    }
}

// MARK: - model

struct NoteContent: Codable, Equatable {
    var body: String
    var created: Int64
    var updated: Int64
    var pinned: Bool?
    var dev: String?
    var cat: String? = nil       // "reading" = Reading List & Ideas; missing = normal note
}

enum Category { static let reading = "reading" }

/// One note as this device knows it. rev = server revision it is based on (0 = never uploaded), dirty = not uploaded yet.
struct NoteRecord: Codable, Equatable {
    var id: String
    var rev: Int
    var dirty: Bool
    var del: Bool
    var content: NoteContent?
    var edits: Int? = 0          // local only: bumped on every edit, so an upload can tell if it was edited meanwhile
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - logic (mirror of spec/logic.mjs; see the rules there)

enum Logic {
    static let stop: Set<String> = Set(("a an and are as at be but by for from has have i if in into is it its me my no not of on or our so " +
        "that the their them then there these they this to was we were what when which who will with you your " +
        "ada adalah akan aku dan dari di dengan ini itu ke kita mereka pada saya tidak untuk yang").split(separator: " ").map(String.init))

    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory { case .nonspacingMark, .spacingMark, .enclosingMark: return true; default: return false }
    }
    static func isWordChar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
    static func isSpace(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace }

    static func normalize(_ s: String) -> String {
        var u = String.UnicodeScalarView()
        for c in s.decomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(c) { u.append(c) }
        return String(u).lowercased()
    }
    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = String.UnicodeScalarView()
        for c in normalize(s).unicodeScalars {
            if isWordChar(c) { cur.append(c) } else if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }
    /// length counted in UTF-16 units, like JavaScript and Kotlin
    static func tokens(_ s: String) -> [String] { words(s).filter { $0.utf16.count >= 2 && !stop.contains($0) } }

    static func trimSpace(_ s: Substring) -> Substring {
        var a = s.unicodeScalars.startIndex, b = s.unicodeScalars.endIndex
        while a < b, isSpace(s.unicodeScalars[a]) { a = s.unicodeScalars.index(after: a) }
        while b > a, isSpace(s.unicodeScalars[s.unicodeScalars.index(before: b)]) { b = s.unicodeScalars.index(before: b) }
        return Substring(s.unicodeScalars[a..<b])
    }
    static func title(_ body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var t = trimSpace(line)
            if t.hasPrefix("#") { t = trimSpace(t.drop(while: { $0 == "#" })) }
            if !t.isEmpty { return String(String.UnicodeScalarView(t.unicodeScalars.prefix(120))) }
        }
        return "Untitled"
    }
    static func titleKey(_ t: String) -> String {
        var out = String.UnicodeScalarView(), space = false
        for c in normalize(t).unicodeScalars {
            if isSpace(c) { space = !out.isEmpty } else { if space { out.append(" ") }; space = false; out.append(c) }
        }
        return String(out)
    }

    static let linkRe = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+?)\\]\\]")
    static let tagRe = try! NSRegularExpression(pattern: "(^|[^\\p{L}\\p{N}_&#])#([\\p{L}\\p{N}_/-]*\\p{L}[\\p{L}\\p{N}_/-]*)")

    static func links(_ body: String) -> [String] {
        let ns = body as NSString
        var out: [String] = []
        for m in linkRe.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            let name = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let k = titleKey(String(name))
            if !k.isEmpty && !out.contains(k) { out.append(k) }
        }
        return out
    }
    static func renameLinks(_ body: String, oldKey: String, newTitle: String) -> String {
        let ns = body as NSString
        var out = "", last = 0
        for m in linkRe.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            let bar = inner.firstIndex(of: "|")
            let target = bar.map { String(inner[..<$0]) } ?? inner
            let hash = target.firstIndex(of: "#")
            let name = hash.map { String(target[..<$0]) } ?? target
            guard titleKey(name) == oldKey else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += "[[" + newTitle + (hash.map { String(target[$0...]) } ?? "") + (bar.map { String(inner[$0...]) } ?? "") + "]]"
            last = m.range.location + m.range.length
        }
        return last == 0 ? body : out + ns.substring(from: last)
    }
    static func tags(_ body: String) -> [String] {
        let ns = body as NSString
        var out: [String] = []
        for m in tagRe.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let t = normalize(ns.substring(with: m.range(at: 2)))
            if !out.contains(t) { out.append(t) }
        }
        return out
    }
    static func conflictCopy(_ body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let i = lines.firstIndex(where: { !trimSpace(Substring($0)).isEmpty }) else { return "(conflict)\n" + body }
        var l = Substring(lines[i])
        while let c = l.unicodeScalars.last, isSpace(c) { l = Substring(l.unicodeScalars.dropLast()) }
        lines[i] = String(l) + " (conflict)"
        return lines.joined(separator: "\n")
    }
}

/// byte-wise order on UTF-8: keeps every term with a given prefix next to each other
private func utf8Less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

struct IndexedNote {
    let id: String
    let body: String
    let created: Int64
    let updated: Int64
    let pinned: Bool
    let cat: String?
    let title: String
    let key: String
    let tf: [String: Int]
    let len: Int
    let links: [String]
    let tags: [String]
    let words: [String]
}

struct Scored: Equatable { let id: String; let score: Double }

final class NotesIndex {
    private(set) var notes: [String: IndexedNote] = [:]
    private(set) var order: [String] = []          // created, then id
    private var byKey: [String: String] = [:]
    private var df: [String: Int] = [:]
    private var terms: [String] = []
    private var avg = 1.0
    private(set) var out: [String: [String]] = [:]
    private(set) var back: [String: [String]] = [:]
    var count: Int { notes.count }
    static let k1 = 1.2, b = 0.75, titleTF = 3, relatedMin = 0.08, relatedMax = 5

    init(_ list: [(id: String, content: NoteContent)]) {
        let sorted = list.sorted { $0.content.created != $1.content.created ? $0.content.created < $1.content.created : $0.id < $1.id }
        var total = 0
        for (id, c) in sorted {
            let t = Logic.title(c.body)
            var tf: [String: Int] = [:]
            for w in Logic.tokens(t) { tf[w, default: 0] += NotesIndex.titleTF }
            for w in Logic.tokens(c.body) { tf[w, default: 0] += 1 }
            let len = tf.values.reduce(0, +)
            total += len
            for w in tf.keys { df[w, default: 0] += 1 }
            let key = Logic.titleKey(t)
            if byKey[key] == nil { byKey[key] = id }
            notes[id] = IndexedNote(id: id, body: c.body, created: c.created, updated: c.updated, pinned: c.pinned ?? false, cat: c.cat, title: t, key: key,
                                    tf: tf, len: len, links: Logic.links(c.body), tags: Logic.tags(c.body), words: Logic.words(c.body))
            order.append(id)
        }
        avg = notes.isEmpty ? 1 : Double(total) / Double(notes.count)
        terms = df.keys.sorted(by: utf8Less)
        for id in order {
            let n = notes[id]!
            var to: [String] = []
            for k in n.links { if let t = byKey[k], t != id, !to.contains(t) { to.append(t) } }
            out[id] = to
            for t in to { back[t, default: []].append(id) }
        }
    }

    func resolve(_ name: String) -> String? { byKey[Logic.titleKey(name)] }
    func backlinks(_ id: String) -> [String] { (back[id] ?? []).sorted() }
    func edges() -> [(String, String)] { order.flatMap { from in (out[from] ?? []).map { (from, $0) } } }

    func prefixed(_ p: String) -> [String] {
        var lo = 0, hi = terms.count
        while lo < hi { let mid = (lo + hi) / 2; if utf8Less(terms[mid], p) { lo = mid + 1 } else { hi = mid } }
        var res: [String] = []
        let pb = Array(p.utf8)
        var i = lo
        while i < terms.count, terms[i].utf8.starts(with: pb) { res.append(terms[i]); i += 1 }
        return res
    }

    func search(_ query: String, limit: Int = 50) -> [Scored] {
        let q = Logic.words(query)
        var qt: [String] = []
        for (i, w) in q.enumerated() where i == q.count - 1 || (w.utf16.count >= 2 && !Logic.stop.contains(w)) { qt.append(w) }
        if qt.isEmpty { return [] }
        let sets = qt.map { prefixed($0) }
        if sets.contains(where: { $0.isEmpty }) { return [] }
        let N = Double(notes.count)
        var res: [(id: String, score: Double, updated: Int64)] = []
        for id in order {
            let n = notes[id]!
            var score = 0.0, ok = true
            for set in sets {
                var best = -1.0
                for t in set {
                    guard let tfi = n.tf[t] else { continue }
                    let tf = Double(tfi), d = Double(df[t]!)
                    let idf = log(1 + (N - d + 0.5) / (d + 0.5))
                    let s = idf * tf * (NotesIndex.k1 + 1) / (tf + NotesIndex.k1 * (1 - NotesIndex.b + NotesIndex.b * Double(n.len) / avg))
                    if s > best { best = s }
                }
                if best < 0 { ok = false; break }
                score += best
            }
            if ok { res.append((id, score, n.updated)) }
        }
        res.sort { $0.score != $1.score ? $0.score > $1.score : $0.updated != $1.updated ? $0.updated > $1.updated : $0.id < $1.id }
        return res.prefix(limit).map { Scored(id: $0.id, score: $0.score) }
    }

    private var vecs: [String: (v: [String: Double], norm: Double)] = [:]
    private func vector(_ n: IndexedNote) -> (v: [String: Double], norm: Double) {
        if let c = vecs[n.id] { return c }
        var v: [String: Double] = [:], norm = 0.0
        let N = Double(notes.count)
        for (t, tf) in n.tf {
            let w = (1 + log(Double(tf))) * log(N / Double(df[t]!))
            if w > 0 { v[t] = w; norm += w * w }
        }
        vecs[n.id] = (v, norm.squareRoot())
        return (v, norm.squareRoot())
    }
    func related(_ id: String) -> [Scored] {
        guard let me = notes[id], notes.count >= 2 else { return [] }
        let a = vector(me)
        if a.norm == 0 { return [] }
        let linked = Set((out[id] ?? []) + (back[id] ?? []))
        var res: [Scored] = []
        for oid in order where oid != id && !linked.contains(oid) {
            let b = vector(notes[oid]!)
            if b.norm == 0 { continue }
            var dot = 0.0
            for (t, w) in a.v { if let x = b.v[t] { dot += w * x } }
            let s = dot / (a.norm * b.norm)
            if s >= NotesIndex.relatedMin { res.append(Scored(id: oid, score: s)) }
        }
        res.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return Array(res.prefix(NotesIndex.relatedMax))
    }
    struct AutoEdge: Equatable { let a: String; let b: String; let kind: String; let score: Double }
    /// edges nobody typed (spec autoEdges): mentions, then related pairs; one per pair, linked pairs left out, a < b
    func autoEdges() -> [AutoEdge] {
        func pair(_ x: String, _ y: String) -> (String, String) { utf8Less(x, y) ? (x, y) : (y, x) }
        var linked = Set<String>(), seen = Set<String>(), res: [AutoEdge] = []
        for (x, y) in edges() { let p = pair(x, y); linked.insert(p.0 + " " + p.1) }
        func add(_ x: String, _ y: String, _ kind: String, _ score: Double) {
            let p = pair(x, y), k = p.0 + " " + p.1
            if linked.contains(k) || seen.contains(k) { return }
            seen.insert(k); res.append(AutoEdge(a: p.0, b: p.1, kind: kind, score: score))
        }
        for id in order { for m in mentions(id) { add(id, m, "mention", 0) } }
        for id in order { for r in related(id) { add(id, r.id, "related", r.score) } }
        return res.sorted { $0.a != $1.a ? utf8Less($0.a, $1.a) : utf8Less($0.b, $1.b) }
    }
    func mentions(_ id: String) -> [String] {
        guard let me = notes[id] else { return [] }
        let tw = Logic.words(me.title)
        if tw.joined().utf16.count < 3 { return [] }
        var res: [String] = []
        for oid in order where oid != id && !(out[oid] ?? []).contains(id) {
            let w = notes[oid]!.words
            if w.count < tw.count { continue }
            for i in 0...(w.count - tw.count) where Array(w[i..<(i + tw.count)]) == tw { res.append(oid); break }
        }
        return res.sorted()
    }
}

// MARK: - API

final class JotAPI {
    let origin: URL
    var auth: String?
    let session: URLSession

    init(origin: URL) {
        self.origin = origin
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    /// a request to the server with the auth header (path may carry a ?query)
    func request(_ method: String, _ path: String) -> URLRequest {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        comps.path = parts[0]
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        if let a = auth { r.setValue("Bearer " + a, forHTTPHeaderField: "Authorization") }
        return r
    }
    private func send(_ r: URLRequest) async throws -> (Int, Data) {
        let (data, resp): (Data, URLResponse) = try await withCheckedThrowingContinuation { c in
            session.dataTask(with: r) { d, resp, err in
                if let err = err { c.resume(throwing: err) } else { c.resume(returning: (d ?? Data(), resp!)) }
            }.resume()
        }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
    /// any status comes back; only network failures throw
    func call(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var r = request(method, path)
        if let j = json { r.httpBody = try JSONSerialization.data(withJSONObject: j); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (code, data) = try await send(r)
        return (code, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }
    /// raw bytes up / down (media); any status comes back; only network failures throw
    func raw(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        var r = request(method, path)
        if let b = body { r.httpBody = b; r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        return try await send(r)
    }
    private static func errorText(_ d: Data, _ fallback: String) -> String {
        ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String ?? fallback
    }
    /// one sealed part of a media file (JotCrypto.sealMedia); write-once on the server (409 if it exists)
    func putMedia(_ id: String, part: String, _ sealed: Data) async throws {
        let (code, d) = try await raw("PUT", "/api/media/\(id)?part=\(part)", body: sealed)
        guard code == 200 else { throw JotError.http(code, JotAPI.errorText(d, "upload failed")) }
    }
    func getMedia(_ id: String, part: String) async throws -> Data {
        let (code, d) = try await raw("GET", "/api/media/\(id)?part=\(part)")
        guard code == 200 else { throw JotError.http(code, JotAPI.errorText(d, "download failed")) }
        return d
    }
    func ok(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> [String: Any] {
        let (code, j) = try await call(method, path, json: json)
        guard code == 200 else { throw JotError.http(code, j["error"] as? String ?? "request failed") }
        return j
    }
}

// MARK: - repository + sync (mirror of spec/client.mjs)

/// All notes on this device, kept in one encrypted file, plus the sync with the server.
@MainActor
final class NotesRepo {
    struct State: Codable { var lastSeq: Int; var records: [String: NoteRecord] }

    let api: JotAPI
    let dev: String
    private let file: URL
    private(set) var key: SymmetricKey?
    private(set) var records: [String: NoteRecord] = [:]
    private(set) var lastSeq = 0
    var onChange: (() -> Void)?
    private var syncing = false, again = false
    var iterations = 600_000

    init(origin: URL, file: URL, dev: String) {
        api = JotAPI(origin: origin)
        self.file = file
        self.dev = dev
    }

    // ---- keys ----
    /// first device creates the account; later ones unlock. Returns the data key + auth to keep in the Keychain.
    func unlock(passphrase: String) async throws -> (dk: Data, auth: String) {
        let (code, s) = try await api.call("GET", "/api/salt")
        if code == 404 {
            let salt = JotCrypto.randomBytes(16).base64EncodedString()
            let d = try JotCrypto.fromPassphrase(passphrase, saltB64: salt, iter: iterations)
            let dk = JotCrypto.randomBytes(32)
            _ = try await api.ok("POST", "/api/init", json: ["salt": salt, "iter": iterations, "auth": d.auth, "wrap": try JotCrypto.wrapDataKey(kek: d.kek, dk: dk)])
            try open(dk: dk, auth: d.auth)
            return (dk, d.auth)
        }
        guard code == 200, let salt = s["salt"] as? String, let iter = s["iter"] as? Int else { throw JotError.http(code, s["error"] as? String ?? "server not reachable") }
        let d = try JotCrypto.fromPassphrase(passphrase, saltB64: salt, iter: iter)
        api.auth = d.auth
        do {
            let k = try await api.ok("GET", "/api/keys")
            let dk = try JotCrypto.unwrapDataKey(kek: d.kek, wrap: k["wrap"] as? String ?? "")
            try open(dk: dk, auth: d.auth)
            return (dk, d.auth)
        } catch { api.auth = nil; throw error }
    }
    /// unlock from saved keys (Keychain) and load the local file
    func open(dk: Data, auth: String) throws {
        key = SymmetricKey(data: dk)
        api.auth = auth
        if let d = try? Data(contentsOf: file), let k = key {
            let st = try JSONDecoder().decode(State.self, from: try JotCrypto.open(k, d, aad: "jot-local-v1"))
            records = st.records; lastSeq = st.lastSeq
        }
    }
    func lock() { key = nil; api.auth = nil; records = [:]; lastSeq = 0 }
    func save() {
        guard let k = key, let plain = try? JSONEncoder().encode(State(lastSeq: lastSeq, records: records)),
              let sealed = try? JotCrypto.seal(k, plain, aad: "jot-local-v1") else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: file, options: [.atomic])
    }
    private func changed() { save(); onChange?() }

    // ---- local edits ----
    var live: [(id: String, content: NoteContent)] { records.values.compactMap { r in r.del ? nil : r.content.map { (r.id, $0) } } }
    func content(_ id: String) -> NoteContent? { records[id].flatMap { $0.del ? nil : $0.content } }

    func edit(_ id: String, body: String, now: Int64 = nowMs()) {
        let cur = records[id]
        if let c = cur?.content, !(cur?.del ?? true), c.body == body { return }
        var c = cur?.content ?? NoteContent(body: body, created: now, updated: now, pinned: nil, dev: dev)
        c.body = body; c.updated = now; c.dev = dev
        records[id] = NoteRecord(id: id, rev: cur?.rev ?? 0, dirty: true, del: false, content: c, edits: (cur?.edits ?? 0) + 1)
        changed()
    }
    func setPinned(_ id: String, _ on: Bool) {
        guard var r = records[id], var c = r.content, !r.del else { return }
        c.pinned = on ? true : nil
        r.content = c; r.dirty = true; r.edits = (r.edits ?? 0) + 1
        records[id] = r
        changed()
    }
    func setCat(_ id: String, _ cat: String?) {
        guard var r = records[id], var c = r.content, !r.del, c.cat != cat else { return }
        c.cat = cat
        r.content = c; r.dirty = true; r.edits = (r.edits ?? 0) + 1
        records[id] = r
        changed()
    }
    func remove(_ id: String) {
        guard var r = records[id] else { return }
        if r.rev == 0 { records[id] = nil; changed(); return }    // never uploaded: just forget it
        r.del = true; r.dirty = true; r.content = nil; r.edits = (r.edits ?? 0) + 1
        records[id] = r
        changed()
    }

    // ---- sync ----
    func sync() async throws {
        if syncing { again = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            again = false
            try await syncOnce()
        } while again
    }
    private func syncOnce() async throws {
        guard let k = key else { return }
        let ch = try await api.ok("GET", "/api/changes?since=\(lastSeq)")
        var touched = false
        for n in ch["notes"] as? [[String: Any]] ?? [] {
            guard let id = n["id"] as? String, let rev = n["rev"] as? Int else { continue }
            if records[id]?.dirty == true { continue }
            let del = n["del"] as? Bool ?? false
            let c = del ? nil : try JotCrypto.openNote(k, id: id, n["blob"] as? String ?? "")
            records[id] = NoteRecord(id: id, rev: rev, dirty: false, del: del, content: c, edits: 0)
            touched = true
        }
        if let s = ch["seq"] as? Int, s != lastSeq { lastSeq = s; touched = true }
        if touched { changed() }
        for _ in 0..<5 {
            let dirty = records.values.filter { $0.dirty }
            if dirty.isEmpty { return }
            for r in dirty { try await push(r, key: k) }
        }
    }
    private func push(_ r: NoteRecord, key k: SymmetricKey) async throws {
        var body: [String: Any] = ["baseRev": r.rev]
        if r.del { body["del"] = true } else if let c = r.content { body["blob"] = try JotCrypto.sealNote(k, id: r.id, c) } else { return }
        let (code, j) = try await api.call("PUT", "/api/notes/\(r.id)", json: body)
        if code == 200, let rev = j["rev"] as? Int {
            guard var now = records[r.id] else { return }
            now.rev = rev
            if now.edits == r.edits { now.dirty = false }      // edited again while uploading: stays dirty
            records[r.id] = now
            changed()
            return
        }
        guard code == 409 else { throw JotError.http(code, j["error"] as? String ?? "upload failed") }
        guard let s = j["note"] as? [String: Any], let srev = s["rev"] as? Int else {
            records[r.id]?.rev = 0; changed(); return                 // server lost it (reset): upload as new
        }
        let sdel = s["del"] as? Bool ?? false
        let theirs = sdel ? nil : try JotCrypto.openNote(k, id: r.id, s["blob"] as? String ?? "")
        let take = { self.records[r.id] = NoteRecord(id: r.id, rev: srev, dirty: false, del: sdel, content: theirs, edits: 0) }
        if sdel && r.del { take() }
        else if sdel { records[r.id]?.rev = srev }
        else if r.del { take() }
        else if let t = theirs, let mine = r.content {
            if t.body == mine.body { take() }
            else {
                let oursWins = mine.updated > t.updated
                var loser = oursWins ? t : mine
                loser.body = Logic.conflictCopy(loser.body)
                if oursWins { records[r.id]?.rev = srev } else { take() }
                let cid = JotCrypto.newId()
                records[cid] = NoteRecord(id: cid, rev: 0, dirty: true, del: false, content: loser, edits: 1)
            }
        }
        changed()
    }
}

// MARK: - live events (Server-Sent Events from /api/events)

final class EventStream: NSObject, URLSessionDataDelegate {
    let origin: URL
    var auth: String?
    var onEvent: (([String: Any]) -> Void)?
    var onState: ((Bool) -> Void)?
    var onUnauthorized: (() -> Void)?
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buf = Data()
    private var backoff: Double = 1
    private var stopped = true
    private let q = DispatchQueue(label: "jot.events")

    init(origin: URL) {
        self.origin = origin
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 90          // the server pings every 25 s
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        let oq = OperationQueue(); oq.underlyingQueue = q; oq.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: oq)
    }

    func start(auth: String) { q.async { self.auth = auth; self.stopped = false; self.connect() } }
    func stop() { q.async { self.stopped = true; self.task?.cancel(); self.task = nil } }
    /// drop the current connection and dial again now (e.g. after the Mac wakes up)
    func restart() { q.async { guard !self.stopped else { return }; self.task?.cancel(); self.task = nil; self.backoff = 1; self.connect() } }

    private func connect() {
        guard !stopped, task == nil, let auth = auth else { return }
        var r = URLRequest(url: origin.appendingPathComponent("api/events"))
        r.setValue("Bearer " + auth, forHTTPHeaderField: "Authorization")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        buf = Data()
        let t = session.dataTask(with: r)
        task = t
        t.resume()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { completionHandler(.cancel); stopped = true; onUnauthorized?(); return }
        if code != 200 { completionHandler(.cancel); return }
        backoff = 1
        onState?(true)
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        buf.append(data)
        let sep = Data("\n\n".utf8)
        while let r = buf.range(of: sep) {
            let block = String(decoding: buf.subdata(in: buf.startIndex..<r.lowerBound), as: UTF8.self)
            buf.removeSubrange(buf.startIndex..<r.upperBound)
            let payload = block.split(separator: "\n").filter { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }.joined(separator: "\n")
            if !payload.isEmpty, let o = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] { onEvent?(o) }
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard t === task else { return }
        task = nil
        onState?(false)
        guard !stopped else { return }
        let wait = backoff
        backoff = min(backoff * 2, 15)
        q.asyncAfter(deadline: .now() + wait) { self.connect() }
    }
}

/// Checks this build's crypto against spec/vectors.json (Jot --selftest, run by install.sh).
enum SelfTest {
    static let vectors = """
    {"pass":"correct horse battery","salt":"AQIDBAUGBwgJCgsMDQ4PEA==","iter":1000,"kek":"3998aca8996855643fc45f1c839bc9a06aa9f3a7cf1f939bdc5f1c64b3e1f19b","auth":"97rJhKWx8BiPLqqbSEr48ECfd0xvRODIhR1m1QGkpbE=","dk":"c8c7c6c5c4c3c2c1c0bfbebdbcbbbab9b8b7b6b5b4b3b2b1b0afaeadacabaaa9","wrap":"BwcHBwcHBwcHBwcHK6i0F+PI2fr1MFufY/8ynfvuY8PhJ3Sb1QL/tI7yY4tqyup3Eh3/YInur+dkUKrK","id":"AAAAAAAAAAAAAAAAAAAAAA","blob":"5UaKw5BeJ8Br7wVI7KSURgW+ULMdzFrrRFQvPSyLAEBK05zxWwMFmdfXbc0Jls0V/VoDYGIYs8xM+fiQjt7Vvj2Afu46+riKQC2TLPuN5EIf9wlyXk+4A5r37l6/MYw09vtw9jIYItxwUnza3qh5Etgh31P3AWBg3PM/2+w=","noteJson":"{\\"body\\":\\"Héllo 👋\\\\n[[link]] #tag\\",\\"created\\":1760000000000,\\"updated\\":1760000001000,\\"dev\\":\\"mac\\"}","mediaSealed":"pD4WWKG35WsSRNCbnsZap+pnE0uxyXjpdb1PvkD6HNsmrhUjQ530M+EitnnHRxGEQqrR0WXnB/JBnwj+b0ckTmsCoSxPxZEc+/v9gcj2hOxKvamnL34xl4FM4Ppn/8nFNGfix2xHnFbdLQ6Z9krsQGjsjBrEMjChf+Mg3rxOYsWHQE5OcsaKGoFbcOd0IMcYpYx7MHPQYm16TyCc1IVFJo0vP4q1yvp+4dXl0I6ovfaVnm1pfpYHFP9n4YgtMZghERazwzKzRi4xkJgTg43saKwDOuZvHLlzP0hX0TKzF8fICjeY2YkVrnk1HpQ3HwGAA8HDDRMV5l+IegelcDFmqf5u7iGdC21nLUJIvVZuYYA/sq8TxPqaNo3h3dT8dySkhbVeXyihouoIhpbO0W0WHqRG/fdM3DhZRJM8FyhSbLJ8KtgsmqojJg=="}
    """

    static func run() -> Bool {
        do {
            let v = try JSONSerialization.jsonObject(with: Data(vectors.utf8)) as! [String: Any]
            let d = try JotCrypto.fromPassphrase(v["pass"] as! String, saltB64: v["salt"] as! String, iter: v["iter"] as! Int)
            let kekHex = d.kek.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
            guard kekHex == v["kek"] as! String, d.auth == v["auth"] as! String else { print("selftest: key derivation mismatch"); return false }
            let dk = try JotCrypto.unwrapDataKey(kek: d.kek, wrap: v["wrap"] as! String)
            guard dk.map({ String(format: "%02x", $0) }).joined() == v["dk"] as! String else { print("selftest: unwrap mismatch"); return false }
            let key = SymmetricKey(data: dk), id = v["id"] as! String
            let note = try JotCrypto.openNote(key, id: id, v["blob"] as! String)
            let want = try JSONDecoder().decode(NoteContent.self, from: Data((v["noteJson"] as! String).utf8))
            guard note == want else { print("selftest: note mismatch"); return false }
            let again = try JotCrypto.openNote(key, id: id, try JotCrypto.sealNote(key, id: id, want))
            guard again == want else { print("selftest: roundtrip mismatch"); return false }
            // media: raw bytes, aad "jot-media:<id>:<part>"; the plain bytes are (i * 7) & 255 for i < 300
            let sealed = Data(base64Encoded: v["mediaSealed"] as! String)!
            let media = try JotCrypto.openMedia(key, id: id, part: "thumb", sealed)
            guard media == Data((0..<300).map { UInt8(($0 * 7) & 255) }),
                  (try? JotCrypto.openMedia(key, id: id, part: "full", sealed)) == nil else { print("selftest: media mismatch"); return false }
            guard Logic.title("  ## Café [[x]]\nbody") == "Café [[x]]", Logic.tokens("Ünïcödé the naïve") == ["unicode", "naive"] else { print("selftest: logic mismatch"); return false }
            print("selftest ok")
            return true
        } catch {
            print("selftest failed: \(error)")
            return false
        }
    }
}

// MARK: - list markers (editor: Return continues, Tab / Shift-Tab nest)

/// ordered-list markers: 1 2 3 (children i ii iii) and A B C (children a b c)
enum ListMarker {
    enum Kind { case number, upper, lower, roman, upperRoman }
    static let romanDigits: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                               (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
    static func toRoman(_ n: Int) -> String {
        var n = max(1, n), out = ""
        for (v, s) in romanDigits { while n >= v { out += s; n -= v } }
        return out
    }
    static func fromRoman(_ s: String) -> Int? {
        let s = s.lowercased()
        guard !s.isEmpty, s.allSatisfy({ "ivxlcdm".contains($0) }) else { return nil }
        var rest = Substring(s), n = 0
        for (v, d) in romanDigits { while rest.hasPrefix(d) { n += v; rest = rest.dropFirst(d.count) } }
        return rest.isEmpty && toRoman(n) == s ? n : nil
    }
    /// what a marker token is; `prev` is the token of the item above at the same depth (single letters like "i" / "v"
    /// are letters when they continue a letter list, roman when they start one ("i") or continue a roman one)
    static func kind(_ t: String, prev: String?) -> Kind? {
        if !t.isEmpty, t.allSatisfy(\.isNumber) { return .number }
        let upper = t == t.uppercased()
        let isRoman = fromRoman(t) != nil
        if t.count == 1, let c = t.unicodeScalars.first, CharacterSet.letters.contains(c), c.isASCII {
            if let p = prev, let pk = kind(p, prev: nil) {
                if pk == .roman || pk == .upperRoman, isRoman, p.count > 1 || fromRoman(p).map({ $0 + 1 }) == fromRoman(t) { return upper ? .upperRoman : .roman }
                if p.count == 1 { return upper ? .upper : .lower }
            }
            return isRoman && (t == "i" || t == "I") ? (upper ? .upperRoman : .roman) : (upper ? .upper : .lower)
        }
        return isRoman ? (upper ? .upperRoman : .roman) : nil
    }
    static func value(_ t: String, _ k: Kind) -> Int {
        switch k {
        case .number: return Int(t) ?? 1
        case .upper, .lower: return Int((t.lowercased().unicodeScalars.first?.value ?? 97) - 96)
        case .roman, .upperRoman: return fromRoman(t) ?? 1
        }
    }
    static func token(_ n: Int, _ k: Kind) -> String {
        switch k {
        case .number: return String(n)
        case .lower: return String(UnicodeScalar(UInt8(96 + min(max(n, 1), 26))))
        case .upper: return String(UnicodeScalar(UInt8(64 + min(max(n, 1), 26))))
        case .roman: return toRoman(n)
        case .upperRoman: return toRoman(n).uppercased()
        }
    }
    static func next(_ t: String, prev: String?) -> String {
        guard let k = kind(t, prev: prev) else { return t }
        return token(value(t, k) + 1, k)
    }
    /// the style a child list uses under a parent of kind k
    static func childKind(_ k: Kind) -> Kind {
        switch k { case .number, .lower: return .roman; case .upper, .roman, .upperRoman: return .lower }
    }
}

// MARK: - [Title](https://…) links (editor: only the title shows, in link blue)

enum MdLink {
    /// UTF-16 ranges: the whole link, its title, its url
    struct Match: Equatable { let range: NSRange; let title: NSRange; let url: NSRange }
    static let re = try! NSRegularExpression(pattern: "\\[([^\\[\\]\\n]+)\\]\\((https?://[^)\\s]+)\\)")
    static let codeRe = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    static let fenceRe = try! NSRegularExpression(pattern: "^```[^\\n]*\\n[\\s\\S]*?^```\\s*$", options: .anchorsMatchLines)

    /// the links outside code spans / blocks
    static func find(_ s: String) -> [Match] {
        let all = NSRange(location: 0, length: (s as NSString).length)
        let code = (codeRe.matches(in: s, range: all) + fenceRe.matches(in: s, range: all)).map { $0.range }
        return re.matches(in: s, range: all).compactMap { m in
            code.contains { NSIntersectionRange($0, m.range).length > 0 } ? nil : Match(range: m.range, title: m.range(at: 1), url: m.range(at: 2))
        }
    }
    /// the caret / selection reaches the link from just after "[" to just after ")": then it shows whole (editable)
    static func touches(_ m: Match, _ sel: NSRange) -> Bool { sel.location <= NSMaxRange(m.range) && NSMaxRange(sel) > m.range.location }
}

// MARK: - media lines ![alt](jot-media:<id>) (mirror of logic.mjs media(); editor: a thumbnail instead of the text)

enum Media {
    /// kind "image" or "video"; duration as written in the alt ("video 0:42" → "0:42"), else ""
    struct Item: Equatable { let id: String; let kind: String; let duration: String }
    /// UTF-16 ranges: the whole line without its newline, and from "!" to the line's end (after any indent)
    struct Line: Equatable { let range: NSRange; let body: NSRange; let item: Item }
    static let re = try! NSRegularExpression(pattern: "^([ \\t]*)!\\[([^\\]\\n]*)\\]\\(jot-media:([A-Za-z0-9_-]{16,64})\\)[ \\t]*$",
                                             options: .anchorsMatchLines)

    static func item(alt: String, id: String) -> Item {
        let w = alt.split(whereSeparator: { $0.isWhitespace })
        let video = w.first == "video"
        return Item(id: id, kind: video ? "video" : "image", duration: video && w.count > 1 ? String(w[1]) : "")
    }
    static func lines(_ s: String) -> [Line] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let start = NSMaxRange(m.range(at: 1))
            return Line(range: m.range, body: NSRange(location: start, length: NSMaxRange(m.range) - start),
                        item: item(alt: ns.substring(with: m.range(at: 2)), id: ns.substring(with: m.range(at: 3))))
        }
    }
    static func find(_ body: String) -> [Item] { lines(body).map { $0.item } }
    /// the caret / selection is on the media line (from its start to its end): its text shows (dim, editable)
    static func touches(_ line: NSRange, _ sel: NSRange) -> Bool { sel.location <= NSMaxRange(line) && NSMaxRange(sel) >= line.location }
}

// MARK: - code highlighting output (highlight.js HTML → colour ranges)

/// highlight.js returns the code as HTML with `<span class="hljs-…">`; this turns it back into the plain text plus
/// (UTF-16 range, class) spans. Classes lose the "hljs-" prefix ("hljs-title function_" → "title function_").
/// Spans come outermost first, so applying them in order lets inner ones win.
enum HLParse {
    struct Span { let range: NSRange; let cls: String; let depth: Int }
    static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "#x27": "'", "#39": "'", "apos": "'"]

    static func parse(_ html: String) -> (text: String, spans: [Span]) {
        var text = "", len = 0
        var stack: [(start: Int, cls: String)] = []
        var spans: [Span] = []
        var i = html.startIndex
        while i < html.endIndex {
            let c = html[i]
            if c == "<" {
                guard let close = html[i...].firstIndex(of: ">") else { break }
                let tag = html[html.index(after: i)..<close]
                if tag.hasPrefix("/") {
                    if let top = stack.popLast() { spans.append(Span(range: NSRange(location: top.start, length: len - top.start), cls: top.cls, depth: stack.count)) }
                } else if tag.hasPrefix("span") {
                    var cls = ""
                    if let q = tag.range(of: "class=\"") {
                        let rest = tag[q.upperBound...]
                        cls = String(rest.prefix { $0 != "\"" }).split(separator: " ")
                            .map { $0.hasPrefix("hljs-") ? String($0.dropFirst(5)) : String($0) }.joined(separator: " ")
                    }
                    stack.append((len, cls))
                }
                i = html.index(after: close)
            } else if c == "&", let semi = html[i...].prefix(8).firstIndex(of: ";"),
                      let ch = entities[String(html[html.index(after: i)..<semi])] {
                text += ch; len += (ch as NSString).length
                i = html.index(after: semi)
            } else {
                text.append(c); len += String(c).utf16.count
                i = html.index(after: i)
            }
        }
        return (text, spans.sorted { $0.depth < $1.depth })
    }
}
