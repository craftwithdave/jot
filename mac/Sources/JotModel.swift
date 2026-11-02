// Jot app state: the notes + sync (NotesStore, shared) and each window's open note, history, search, autocomplete (AppModel). macOS only (built by install.sh).
import AppKit
import SwiftUI
import Security
import Combine

enum Keychain {
    static let service = "app.jot.mac", account = "keys"
    static func base() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func save(_ data: Data) {
        delete()
        var q = base()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> Data? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func delete() { SecItemDelete(base() as CFDictionary) }

    // An ad-hoc signed app gets a new identity with every build, so a rebuilt Jot would be asked for Keychain access.
    // Before an auto-update, the old build moves the keys to a private file; the new build puts them back in the
    // Keychain as its own item (no prompt) and deletes the file.
    static var handoffFile: URL { AppModel.storeFile.deletingLastPathComponent().appendingPathComponent("handoff.keys") }
    static func handOff() -> Bool {
        guard let d = load() else { return false }
        let f = handoffFile
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: f.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return false }
        delete()
        return true
    }
    static func takeHandoff() {
        guard let d = try? Data(contentsOf: handoffFile) else { return }
        save(d)
        try? FileManager.default.removeItem(at: handoffFile)
    }
}

enum SyncState: Equatable { case idle, syncing, live, offline(String) }

struct NoteRow: Identifiable, Equatable {
    let id: String
    let title: String
    let snippet: String
    let updated: Int64
    let pinned: Bool
    var reading = false                                  // in Reading List & Ideas
    /// list section without a search: 0 pinned, 1 Reading List & Ideas, 2 the rest
    var section: Int { pinned ? 0 : reading ? 1 : 2 }
    static let sections = ["Pinned", "Reading List & Ideas", "Notes"]
}

/// what every Jot window shares: the notes, their index, sync and the lock
@MainActor
final class NotesStore: ObservableObject {
    let repo: NotesRepo
    let events: EventStream

    @Published var unlocked = false
    @Published var unlockError: String?
    @Published var busy = false
    @Published private(set) var index = NotesIndex([])
    private(set) var indexGen = 0                      // bumped on every rebuild (the editor restyles links)
    /// when each note was last opened on this Mac (seconds; local only, shown in the note switcher)
    @Published private(set) var opened: [String: Double] = UserDefaults.standard.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:]
    @Published var sync: SyncState = .idle

    private var sessions: [Weak] = []                  // the windows' AppModels
    private struct Weak { weak var model: AppModel? }
    var models: [AppModel] { sessions.compactMap(\.model) }
    private var syncTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var timer: Timer?

    init() {
        let dev = Host.current().localizedName ?? "Mac"
        repo = NotesRepo(origin: AppModel.origin, file: AppModel.storeFile, dev: dev)
        events = EventStream(origin: AppModel.origin)
        repo.onChange = { [weak self] in self?.repoChanged() }
        events.onEvent = { [weak self] e in
            guard let seq = e["seq"] as? Int else { return }
            Task { @MainActor in if let s = self, seq != s.repo.lastSeq { s.syncSoon(0) } }
        }
        events.onState = { [weak self] up in Task { @MainActor in
            guard let s = self else { return }
            if up { if s.sync != .syncing { s.sync = .live }; s.syncSoon(0) } else if s.sync == .live { s.sync = .offline("reconnecting…") }
        } }
        events.onUnauthorized = { [weak self] in Task { @MainActor in self?.lock(message: "The passphrase was changed. Unlock again.") } }

        Keychain.takeHandoff()
        if let saved = Keychain.load(), let o = (try? JSONSerialization.jsonObject(with: saved)) as? [String: String],
           let dk = o["dk"].flatMap({ Data(base64Encoded: $0) }), let auth = o["auth"] {
            do { try repo.open(dk: dk, auth: auth); didUnlock() } catch { unlockError = "Couldn't open the notes on this Mac: \(error)" }
        }
    }

    /// a window's model joins; it loads its note now if the notes are already open
    func attach(_ m: AppModel) {
        sessions.removeAll { $0.model == nil }
        sessions.append(Weak(model: m))
        if unlocked { m.didUnlock() }
    }

    // MARK: unlock

    func unlock(passphrase: String) {
        guard !busy, !passphrase.isEmpty else { return }
        busy = true; unlockError = nil
        Task {
            defer { busy = false }
            do {
                let k = try await repo.unlock(passphrase: passphrase)
                Keychain.save(try JSONSerialization.data(withJSONObject: ["dk": k.dk.base64EncodedString(), "auth": k.auth]))
                didUnlock()
            } catch JotError.http(let code, let msg) where code == 401 || code == 429 {
                unlockError = msg
            } catch {
                unlockError = "Couldn't reach \(AppModel.origin.host ?? "the notes server"). Is it reachable from this Mac?\n(\(error))"
            }
        }
    }
    private func didUnlock() {
        unlocked = true
        rebuildIndex()
        for m in models { m.didUnlock() }
        if let a = repo.api.auth { events.start(auth: a) }
        syncSoon(0)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.syncSoon(0) } }
    }
    var onLock: (() -> Void)?
    func lock(message: String? = nil) {
        for m in models { m.commit() }
        events.stop(); timer?.invalidate()
        Keychain.delete()
        try? FileManager.default.removeItem(at: AppModel.storeFile)
        InlineVideo.current?.stop()
        MediaStore.shared.clear()                       // cached thumbnails (sealed) too
        for m in models { m.didLock() }                 // before repo.lock: each window remembers its note
        repo.lock()
        unlocked = false; unlockError = message
        index = NotesIndex([])
        onLock?()
    }

    // MARK: sync + index

    func syncSoon(_ delay: Double = 1.0) {
        syncTask?.cancel()
        syncTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            if Task.isCancelled { return }
            if sync != .live { sync = .syncing }
            do { try await repo.sync(); sync = .live } catch { sync = .offline(String(describing: error)) }
        }
    }
    private func repoChanged() {
        indexTask?.cancel()
        indexTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            rebuildIndex()
        }
        for m in models { m.repoChanged() }
    }
    private func rebuildIndex() { indexGen += 1; index = NotesIndex(repo.live) }

    func markOpened(_ id: String) {
        opened[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(opened, forKey: "lastOpened")
    }
    func forgetOpened(_ id: String) {
        opened[id] = nil
        UserDefaults.standard.set(opened, forKey: "lastOpened")
    }
}

/// one Jot window: its open note, history, search and autocomplete (the notes themselves are in NotesStore)
@MainActor
final class AppModel: ObservableObject {
    /// the notes server: JotOrigin in Info.plist, written by install.sh (JOT_ORIGIN / origin.txt when publishing)
    nonisolated static let origin = URL(string: Bundle.main.object(forInfoDictionaryKey: "JotOrigin") as? String ?? "http://localhost:8080")!
    nonisolated static var storeFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jot/notes.sealed")
    }

    let store: NotesStore
    var repo: NotesRepo { store.repo }
    var events: EventStream { store.events }
    var unlocked: Bool { store.unlocked }
    var unlockError: String? { store.unlockError }
    var busy: Bool { store.busy }
    var index: NotesIndex { store.index }
    var indexGen: Int { store.indexGen }
    var opened: [String: Double] { store.opened }
    var sync: SyncState { store.sync }
    func syncSoon(_ delay: Double = 1.0) { store.syncSoon(delay) }
    func unlock(passphrase: String) { store.unlock(passphrase: passphrase) }
    func lock(message: String? = nil) { store.lock(message: message) }

    @Published private(set) var currentId = JotCrypto.newId()
    @Published private(set) var loadToken = 0          // bumped when the editor must replace its text
    @Published var text = ""                            // body of the open note, as typed
    @Published var showSwitcher = false
    @Published var panelHover = false                   // the mouse is over the panel
    @Published var panelActive = false                  // the panel is the key window (top-bar buttons show only then)
    @Published var showConnections = UserDefaults.standard.bool(forKey: "showConnections") {
        didSet { UserDefaults.standard.set(showConnections, forKey: "showConnections") }
    }
    @Published var query = ""
    @Published var switcherSel = 0
    @Published var autocomplete: [String] = []          // titles offered while typing [[...
    @Published var acSel = 0
    @Published var confirmDelete = false
    @Published private(set) var notice: String?         // short message at the top of the panel (adding images)

    var onHide: (() -> Void)?
    var onGraph: (() -> Void)?
    var onNoteChange: (() -> Void)?                     // another note opened in this window (the window list is saved)
    private(set) var back: [String] = [], forward: [String] = []
    private var lastSaved = ""          // body last handed to the repo for the open note
    private var openedKey = ""          // titleKey of the open note when it was opened (to rewrite links on rename)
    private var saveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var wanted: String?         // the note this window should open once the notes are unlocked
    private var storeSink: AnyCancellable?

    /// `note`: open this note (a restored window), else the most recent one; `fresh`: start with a new note
    init(store: NotesStore, note: String? = nil, fresh: Bool = false) {
        self.store = store
        wanted = fresh ? "" : note
        storeSink = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        store.attach(self)
    }

    /// the notes are open: show the wanted note (a deleted one → the most recent)
    func didUnlock() {
        if let w = wanted, w.isEmpty { load(JotCrypto.newId()) }
        else if let w = wanted, repo.content(w) != nil { load(w) }
        else if let first = recentRows().first { load(first.id) } else { load(JotCrypto.newId()) }
        wanted = nil
    }
    func didLock() {
        wanted = repo.content(currentId) != nil ? currentId : nil
        text = ""; lastSaved = ""; back = []; forward = []
    }
    /// the notes changed (sync or another window): the open note, if this window isn't typing in it, shows the new text
    func repoChanged() {
        if saveTask == nil, text == lastSaved {
            let body = repo.content(currentId)?.body
            if let b = body, b != lastSaved { text = b; lastSaved = b; loadToken += 1 }
            else if body == nil, repo.records[currentId]?.del == true { load(recentRows().first?.id ?? JotCrypto.newId(), remember: false) }
        }
    }

    // MARK: editing

    /// called by the editor on every keystroke; saves after a short pause
    func typed(_ s: String) {
        guard s != text else { return }
        text = s
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            flush()
        }
    }
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard text != lastSaved else { return }
        lastSaved = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && repo.records[currentId] == nil { return }
        repo.edit(currentId, body: text)
        syncSoon()
    }
    /// leaving the open note: save it, drop it if empty, and fix [[links]] to it if its title changed
    func commit() {
        flush()
        guard let body = repo.content(currentId)?.body else { return }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { repo.remove(currentId); syncSoon(); return }
        let newTitle = Logic.title(body), newKey = Logic.titleKey(newTitle)
        if !openedKey.isEmpty, openedKey != newKey, openedKey != "untitled" {
            let others = repo.live.filter { $0.id != currentId }
            let stillUsed = others.contains { Logic.titleKey(Logic.title($0.content.body)) == openedKey }
            if !stillUsed {
                for n in others where Logic.links(n.content.body).contains(openedKey) {
                    repo.edit(n.id, body: Logic.renameLinks(n.content.body, oldKey: openedKey, newTitle: newTitle))
                }
            }
            syncSoon()
        }
        openedKey = newKey
    }

    private func load(_ id: String, remember: Bool = false) {
        if remember && id != currentId { back.append(currentId); if back.count > 100 { back.removeFirst() }; forward = [] }
        currentId = id
        store.markOpened(id)
        let body = repo.content(id)?.body ?? ""
        text = body; lastSaved = body
        openedKey = body.isEmpty ? "" : Logic.titleKey(Logic.title(body))
        autocomplete = []
        loadToken += 1
        onNoteChange?()
    }
    func open(_ id: String) {
        guard id != currentId else { showSwitcher = false; return }
        commit()
        load(id, remember: repo.content(currentId) != nil)
        showSwitcher = false
    }
    func newNote(title: String? = nil) {
        commit()
        let id = JotCrypto.newId()
        load(id, remember: repo.content(currentId) != nil)
        if let t = title, !t.isEmpty { text = t + "\n"; flush(); openedKey = Logic.titleKey(t); loadToken += 1 }
        showSwitcher = false
    }
    func openLink(_ name: String) {
        if let id = index.resolve(name) { open(id) } else { newNote(title: name.trimmingCharacters(in: .whitespaces)) }
    }
    func goBack() {
        commit()
        while let id = back.popLast() {
            if repo.content(id) != nil { forward.append(currentId); load(id); return }
        }
    }
    func goForward() {
        commit()
        while let id = forward.popLast() {
            if repo.content(id) != nil { back.append(currentId); load(id); return }
        }
    }
    func deleteCurrent() {
        repo.remove(currentId)
        syncSoon()
        load(recentRows().first?.id ?? JotCrypto.newId())
    }
    /// delete any note (from the switcher); the open one goes through deleteCurrent
    func deleteNote(_ id: String) {
        if id == currentId { deleteCurrent() } else { repo.remove(id); syncSoon() }
        store.forgetOpened(id)
    }
    func togglePin(_ id: String) {
        flush()
        guard let c = repo.content(id) else { return }
        repo.setPinned(id, !(c.pinned ?? false)); syncSoon()           // pinned is optional in the note format
    }
    var isPinned: Bool { repo.content(currentId)?.pinned ?? false }
    func togglePin() { flush(); if repo.content(currentId) != nil { repo.setPinned(currentId, !isPinned); syncSoon() } }
    /// in / out of Reading List & Ideas (note field cat = "reading")
    func toggleReading(_ id: String) {
        flush()
        guard let c = repo.content(id) else { return }
        repo.setCat(id, c.cat == Category.reading ? nil : Category.reading); syncSoon()
    }
    func toggleReading() { toggleReading(currentId) }

    /// Esc: close the innermost thing that is open, else hide the panel
    func escape() {
        if confirmDelete { confirmDelete = false }
        else if !autocomplete.isEmpty { autocomplete = [] }
        else if showSwitcher { showSwitcher = false }
        else { commit(); onHide?() }
    }
    /// shows a notice at the top of the panel (nil hides it); with `seconds` it goes away by itself
    func tell(_ s: String?, for seconds: Double? = nil) {
        noticeTask?.cancel(); noticeTask = nil
        notice = s
        guard s != nil, let t = seconds else { return }
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(t * 1e9))
            if !Task.isCancelled { notice = nil }
        }
    }
    func openSwitcher(_ q: String = "") { flush(); query = q; switcherSel = 0; showSwitcher = true }

    // MARK: lists

    func row(_ id: String, query: [String] = []) -> NoteRow? {
        guard let n = index.notes[id] else { return nil }
        return NoteRow(id: id, title: n.title, snippet: AppModel.snippet(n.body, query), updated: n.updated, pinned: n.pinned,
                       reading: n.cat == Category.reading)
    }
    func recentRows() -> [NoteRow] {
        index.notes.values.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.updated > $1.updated }.compactMap { row($0.id) }
    }
    func switcherRows() -> [NoteRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {                                   // pinned, Reading List & Ideas, the rest; each most recently opened first
            let at = { (r: NoteRow) in self.opened[r.id] ?? Double(r.updated) / 1000 }
            return index.notes.keys.compactMap { row($0) }.sorted { $0.section != $1.section ? $0.section < $1.section : at($0) > at($1) }
        }
        let words = Logic.words(q)
        return index.search(q).compactMap { row($0.id, query: words) }
    }
    /// the first line after the title that mentions a query word, else the first line after the title
    static func snippet(_ body: String, _ query: [String]) -> String {
        var lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty { lines.removeFirst() }
        if !query.isEmpty, let hit = lines.first(where: { l in let w = Logic.words(l); return query.contains { q in w.contains { $0.hasPrefix(q) } } }) {
            return String(hit.prefix(140))
        }
        return String((lines.first ?? "").prefix(140))
    }

    // MARK: [[ autocomplete

    func linkQuery(_ q: String?) {
        guard let q = q else { if !autocomplete.isEmpty { autocomplete = [] }; return }
        let nq = Logic.titleKey(q)
        let me = currentId
        let cands = index.notes.values.filter { $0.id != me && (nq.isEmpty || $0.key.contains(nq)) }
            .sorted { a, b in
                let ap = a.key.hasPrefix(nq), bp = b.key.hasPrefix(nq)
                return ap != bp ? ap : a.updated > b.updated
            }
        autocomplete = Array(cands.prefix(6).map { $0.title })
        acSel = 0
    }

    // MARK: connections of the open note

    var backlinkRows: [NoteRow] { index.backlinks(currentId).compactMap { row($0) } }
    var mentionRows: [NoteRow] { index.mentions(currentId).compactMap { row($0) } }
    var relatedRows: [NoteRow] { index.related(currentId).compactMap { row($0.id) } }
    var outgoing: [(name: String, id: String?)] {
        Logic.links(text).map { k in (index.notes[index.resolve(k) ?? ""]?.title ?? k, index.resolve(k)) }
    }
    var currentTags: [String] { Logic.tags(text) }
}
