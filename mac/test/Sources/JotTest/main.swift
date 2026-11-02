// Checks JotCore against spec (fixtures.json) and syncs with a live notes server.
//   JotTest fixtures <fixtures.json>
//   JotTest sync1|sync2 <origin> <statefile>   (run.sh puts a Node reference client between the two phases)
import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { failures += 1; print("FAIL:", what()) } }
extension Data {
  init(hexString h: String) {
    var b = [UInt8](), i = h.startIndex
    while i < h.endIndex { let j = h.index(i, offsetBy: 2); b.append(UInt8(h[i..<j], radix: 16)!); i = j }
    self.init(b)
  }
}
func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }
func scoredOK(_ got: [Scored], _ want: [[String: Any]]) -> Bool {
  got.count == want.count && zip(got, want).allSatisfy { $0.id == $1["id"] as! String && close($0.score, ($1["score"] as! NSNumber).doubleValue) }
}

let args = CommandLine.arguments
guard SelfTest.run() else { exit(1) }

if args[1] == "fixtures" {
  let fx = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
  let notes = (fx["notes"] as! [[String: Any]]).map { n in
    (id: n["id"] as! String, content: NoteContent(body: n["body"] as! String, created: (n["created"] as! NSNumber).int64Value,
                                                  updated: (n["updated"] as! NSNumber).int64Value, pinned: nil, dev: nil)) }
  let ix = NotesIndex(notes)
  for p in fx["perNote"] as! [[String: Any]] {
    let id = p["id"] as! String, body = ix.notes[id]!.body
    check(Logic.title(body) == p["title"] as! String, "title \(id): \(Logic.title(body))")
    check(Logic.titleKey(Logic.title(body)) == p["titleKey"] as! String, "titleKey \(id)")
    check(Logic.links(body) == p["links"] as! [String], "links \(id): \(Logic.links(body))")
    check(Logic.tags(body) == p["tags"] as! [String], "tags \(id): \(Logic.tags(body))")
    check(ix.backlinks(id) == p["backlinks"] as! [String], "backlinks \(id): \(ix.backlinks(id))")
    check(scoredOK(ix.related(id), p["related"] as! [[String: Any]]), "related \(id): \(ix.related(id))")
    check(ix.mentions(id) == p["mentions"] as! [String], "mentions \(id): \(ix.mentions(id))")
  }
  for t in fx["tokens"] as! [[String: Any]] {
    let s = t["s"] as! String
    check(Logic.words(s) == t["words"] as! [String], "words \(s): \(Logic.words(s))")
    check(Logic.tokens(s) == t["tokens"] as! [String], "tokens \(s): \(Logic.tokens(s))")
  }
  for q in fx["search"] as! [[String: Any]] {
    let s = q["q"] as! String
    check(scoredOK(ix.search(s), q["results"] as! [[String: Any]]), "search '\(s)': \(ix.search(s))")
  }
  let edges = ix.edges().map { [$0.0, $0.1] }
  check(edges == fx["edges"] as! [[String]], "edges \(edges)")
  let auto = ix.autoEdges(), wantAuto = fx["autoEdges"] as! [[String: Any]]
  check(auto.count == wantAuto.count && zip(auto, wantAuto).allSatisfy { $0.a == $1["a"] as! String && $0.b == $1["b"] as! String
    && $0.kind == $1["kind"] as! String && close($0.score, ($1["score"] as! NSNumber).doubleValue) }, "autoEdges \(auto)")
  for r in fx["resolve"] as! [[Any]] { check(ix.resolve(r[0] as! String) == r[1] as? String, "resolve \(r[0])") }
  for r in fx["rename"] as! [[String: String]] {
    let out = Logic.renameLinks(r["body"]!, oldKey: r["oldKey"]!, newTitle: r["newTitle"]!)
    check(out == r["out"]!, "rename: \(out)")
  }
  check(Logic.conflictCopy("  \nTitle  \nx") == "  \nTitle (conflict)\nx", "conflictCopy")
  // [Title](url) links (editor): a Reading List line, then what must not count as one
  let rl = "- [ ] [How agents plan](https://example.com/x) · blog · Oct 17\n  Summary text" as NSString
  let ml = MdLink.find(rl as String)
  check(ml.count == 1 && rl.substring(with: ml[0].title) == "How agents plan" && rl.substring(with: ml[0].url) == "https://example.com/x"
        && ml[0].range.location == 6, "mdlink find \(ml)")
  if let l = ml.first {
    let a = l.range.location, b = NSMaxRange(l.range)
    check(!MdLink.touches(l, NSRange(location: a, length: 0)) && MdLink.touches(l, NSRange(location: a + 1, length: 0))
          && MdLink.touches(l, NSRange(location: b, length: 0)) && !MdLink.touches(l, NSRange(location: b + 1, length: 0))
          && MdLink.touches(l, NSRange(location: 0, length: rl.length)), "mdlink touches")
  }
  check(MdLink.find("[[a]](http://x.y) - [ ] (http://x.y) [a [b]](http://x.y)").count == 0, "mdlink not wiki/checkbox")
  check(MdLink.find("`[x](http://a.b)` and\n```\n[x](http://a.b)\n```\n[y](http://a.b)").count == 1, "mdlink not in code")
  // media lines ![alt](jot-media:<id>) (logic.mjs media())
  for f in fx["media"] as! [[String: Any]] {
    let body = f["body"] as! String
    let want = (f["media"] as! [[String: String]]).map { Media.Item(id: $0["id"]!, kind: $0["kind"]!, duration: $0["duration"]!) }
    check(Media.find(body) == want, "media \(body): \(Media.find(body))")
  }
  let mb = "- [ ] [T](https://x.com/a) · X\n  Summary\n  ![video 0:42](jot-media:AbCdEf0123456789abcdEF)\nafter" as NSString
  let mls = Media.lines(mb as String)
  check(mls.count == 1 && mb.substring(with: mls[0].range) == "  ![video 0:42](jot-media:AbCdEf0123456789abcdEF)"
        && mb.substring(with: mls[0].body) == "![video 0:42](jot-media:AbCdEf0123456789abcdEF)", "media lines \(mls)")
  if let l = mls.first {
    check(Media.touches(l.range, NSRange(location: l.range.location, length: 0)) && Media.touches(l.range, NSRange(location: NSMaxRange(l.range), length: 0))
          && !Media.touches(l.range, NSRange(location: l.range.location - 1, length: 0)) && !Media.touches(l.range, NSRange(location: NSMaxRange(l.range) + 1, length: 0))
          && Media.touches(l.range, NSRange(location: 0, length: 5 + l.range.location)), "media touches")
  }
  // media crypto: vectors.json next to fixtures.json (sealed by crypto.mjs sealMedia)
  let vx = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]).deletingLastPathComponent().appendingPathComponent("vectors.json"))) as! [String: Any]
  let vkey = SymmetricKey(data: Data(hexString: vx["dk"] as! String)), vid = vx["id"] as! String
  let plain = Data(hexString: vx["mediaPlain"] as! String), sealedM = Data(base64Encoded: vx["mediaSealed"] as! String)!
  check((try? JotCrypto.openMedia(vkey, id: vid, part: "thumb", sealedM)) == plain, "openMedia vector")
  check((try? JotCrypto.openMedia(vkey, id: vid, part: "full", sealedM)) == nil && (try? JotCrypto.openMedia(vkey, id: "B" + vid.dropFirst(), part: "thumb", sealedM)) == nil, "openMedia aad")
  let resealed = try! JotCrypto.sealMedia(vkey, id: vid, part: "full", plain)
  check(resealed.count == plain.count + 28 && (try? JotCrypto.openMedia(vkey, id: vid, part: "full", resealed)) == plain, "sealMedia roundtrip")
  // note content: pinned / cat read, and written back unchanged
  for f in fx["content"] as! [[String: Any]] {
    let c = try! JSONDecoder().decode(NoteContent.self, from: Data((f["json"] as! String).utf8))
    check((c.pinned ?? false) == f["pinned"] as! Bool && c.cat == f["cat"] as? String, "content \(f["json"]!)")
    let back = try! JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(c))
    check(back == c, "content round trip \(f["json"]!)")
  }
  print(failures == 0 ? "fixtures ok" : "\(failures) failures"); exit(failures == 0 ? 0 : 1)
}

// sync phases
let origin = URL(string: args[2])!, state = URL(fileURLWithPath: args[3])
let keyFile = state.appendingPathExtension("keys")
Task { @MainActor in
  do {
    let repo = NotesRepo(origin: origin, file: state, dev: "swift")
    repo.iterations = 100_000
    if args[1] == "sync1" {
      let k = try await repo.unlock(passphrase: "swift ✓ pass")
      try JSONSerialization.data(withJSONObject: ["dk": k.dk.base64EncodedString(), "auth": k.auth]).write(to: keyFile)
      repo.edit("swiftnote-aaaaaaaaaaaa", body: "From Swift\nlinks to [[From Node]] #mac")
      repo.edit("shared-aaaaaaaaaaaaaaa", body: "Shared\nv1 from swift", now: 1000)
      try await repo.sync()
      check(repo.records.values.allSatisfy { !$0.dirty }, "all uploaded")
      // media: sealed parts up and down, write-once
      let mid = JotCrypto.newId(), bytes = JotCrypto.randomBytes(70_000), mk = repo.key!
      try await repo.api.putMedia(mid, part: "full", try JotCrypto.sealMedia(mk, id: mid, part: "full", bytes))
      try await repo.api.putMedia(mid, part: "thumb", try JotCrypto.sealMedia(mk, id: mid, part: "thumb", bytes.prefix(500)))
      check(try JotCrypto.openMedia(mk, id: mid, part: "full", try await repo.api.getMedia(mid, part: "full")) == bytes, "media full roundtrip")
      check(try JotCrypto.openMedia(mk, id: mid, part: "thumb", try await repo.api.getMedia(mid, part: "thumb")) == bytes.prefix(500), "media thumb roundtrip")
      do { try await repo.api.putMedia(mid, part: "full", Data(count: 40)); check(false, "media write-once") }
      catch JotError.http(let code, _) { check(code == 409, "media 409, got \(code)") }
      do { _ = try await repo.api.getMedia(JotCrypto.newId(), part: "thumb"); check(false, "media 404") }
      catch JotError.http(let code, _) { check(code == 404, "media 404, got \(code)") }
      // offline edit, synced only in phase 2 (Node edits the same note meanwhile, later timestamp wins)
      repo.edit("shared-aaaaaaaaaaaaaaa", body: "Shared\nv2 offline swift edit", now: 2000)
      print("sync1 done, lastSeq \(repo.lastSeq)")
    } else {
      let k = try JSONSerialization.jsonObject(with: Data(contentsOf: keyFile)) as! [String: String]
      try repo.open(dk: Data(base64Encoded: k["dk"]!)!, auth: k["auth"]!)     // local file must load again
      check(repo.records["shared-aaaaaaaaaaaaaaa"]?.dirty == true, "offline edit survived restart")
      try await repo.sync()
      let bodies = repo.live.map { $0.content.body }.sorted()
      print(bodies)
      check(bodies.contains("From Node\nhello from node, see [[From Swift]]"), "node note arrived")
      check(bodies.contains("Shared\nv2 node edit (later)"), "later edit kept the id")
      check(bodies.contains("Shared (conflict)\nv2 offline swift edit"), "conflict copy kept")
      check(!bodies.contains(where: { $0.hasPrefix("Doomed") }), "node delete arrived")
      let ix = NotesIndex(repo.live)
      check(ix.backlinks("swiftnote-aaaaaaaaaaaa").count == 1, "backlink across devices")
      // make sure what's on disk is ciphertext
      let raw = String(decoding: try Data(contentsOf: state), as: UTF8.self)
      check(!raw.contains("From Swift") && !raw.contains("Shared"), "local file encrypted")
    }
    print(failures == 0 ? "\(args[1]) ok" : "\(failures) failures"); exit(failures == 0 ? 0 : 1)
  } catch { print("ERROR \(error)"); exit(1) }
}
RunLoop.main.run()
