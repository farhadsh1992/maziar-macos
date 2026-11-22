import AppKit

// MaziarSpell — a small helper that exposes macOS's spelling and grammar checker (NSSpellChecker) to the
// Numenor editor Maziar embeds. Numenor's Node backend starts it once (path in MAZIAR_SPELL_HELPER,
// set by NumenorServer) and talks to it over stdin/stdout, one JSON object per line:
//
//   → {"id":1,"op":"check","text":"…","language":"en","grammar":true}
//   ← {"id":1,"issues":[{"from":4,"to":8,"kind":"spelling","message":"…","suggestions":["…"]}]}
//   → {"id":2,"op":"languages"}            ← {"id":2,"languages":["en","en_GB",…]}
//   → {"id":3,"op":"learn","word":"SyncTeX"} ← {"id":3,"learned":true}
//
// Offsets are UTF-16 code units, which is also what JavaScript strings index by. Everything runs on this
// Mac; no text is sent anywhere.

let checker = NSSpellChecker.shared
checker.automaticallyIdentifiesLanguages = false
let spellingType = NSTextCheckingResult.CheckingType.spelling.rawValue
let grammarType = NSTextCheckingResult.CheckingType.grammar.rawValue

func reply(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

func check(_ text: String, language: String, grammar: Bool) -> [[String: Any]] {
    let ns = text as NSString
    guard ns.length > 0 else { return [] }
    _ = checker.setLanguage(language)
    let orthography = NSOrthography.defaultOrthography(forLanguage: language)
    var orthographyOut: NSOrthography? = orthography
    let types = spellingType | (grammar ? grammarType : 0)
    let results = checker.check(
        text, range: NSRange(location: 0, length: ns.length), types: types,
        options: [.orthography: orthography], inSpellDocumentWithTag: 0,
        orthography: &orthographyOut, wordCount: nil)
    var issues: [[String: Any]] = []
    for result in results {
        if result.resultType == .spelling {
            let word = ns.substring(with: result.range)
            let guesses = checker.guesses(forWordRange: result.range, in: text, language: language, inSpellDocumentWithTag: 0) ?? []
            issues.append([
                "from": result.range.location, "to": NSMaxRange(result.range), "kind": "spelling",
                "message": "\u{201c}\(word)\u{201d} may be misspelled.", "word": word,
                "suggestions": Array(guesses.prefix(6)),
            ])
        } else if result.resultType == .grammar {
            for detail in result.grammarDetails ?? [] {
                guard let local = (detail["NSGrammarRange"] as? NSValue)?.rangeValue else { continue }
                let range = NSRange(location: result.range.location + local.location, length: local.length)
                guard range.length > 0, NSMaxRange(range) <= ns.length else { continue }
                let message = detail["NSGrammarUserDescription"] as? String ?? "Possible grammar issue."
                let corrections = detail["NSGrammarCorrections"] as? [String] ?? []
                issues.append([
                    "from": range.location, "to": NSMaxRange(range), "kind": "grammar",
                    "message": message, "word": ns.substring(with: range),
                    "suggestions": Array(corrections.prefix(6)),
                ])
            }
        }
    }
    return issues
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    let id = request["id"] ?? NSNull()
    switch request["op"] as? String {
    case "check":
        let text = request["text"] as? String ?? ""
        let language = request["language"] as? String ?? "en"
        let grammar = request["grammar"] as? Bool ?? true
        reply(["id": id, "issues": check(text, language: language, grammar: grammar)])
    case "languages":
        reply(["id": id, "languages": checker.availableLanguages])
    case "learn":
        let word = request["word"] as? String ?? ""
        if !word.isEmpty { checker.learnWord(word) }
        reply(["id": id, "learned": !word.isEmpty])
    default:
        reply(["id": id, "error": "unknown op"])
    }
}
