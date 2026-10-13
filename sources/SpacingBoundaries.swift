import InputMethodKit
#if SYNTHETIC_IMK_PROBE
import OSLog
#endif

// Pure boundary decision for an already-chosen insertion.
// left/right are the immediately adjacent Characters in the host's logical line.
// This never reformats inserted text (including versions, URLs, or other tokens).
// URL and currency boundary policy is unresolved; this function only classifies
// the two literal neighboring characters, not their wider token context.
func spacesAroundInsertion(_ inserted: String, left: Character?, right: Character?)
  -> (before: Bool, after: Bool) {
  guard let first = inserted.first, let last = inserted.last else { return (false, false) }

  func isHan(_ character: Character) -> Bool {
    // A single ideograph in the Han ranges; exclude emoji, punctuation, and
    // multi-scalar graphemes whose boundary cannot be classified unambiguously.
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
          scalar.properties.isIdeographic else { return false }
    let value = scalar.value
    return value == 0x3007 || (0x3400...0x9FFF).contains(value) ||
      (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
  }

  func isASCIILetterOrDigit(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
      return false
    }
    let value = scalar.value
    return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) ||
      (0x61...0x7A).contains(value)
  }

  func needsSpace(_ lhs: Character?, _ rhs: Character?) -> Bool {
    guard let lhs, let rhs else { return false }
    return (isHan(lhs) && isASCIILetterOrDigit(rhs)) ||
      (isASCIILetterOrDigit(lhs) && isHan(rhs))
  }

  return (needsSpace(left, first), needsSpace(last, right))
}

// Owned by one controller, not inferred from a host's zero-length markedRange.
// The controller must first establish that Rime is idle or owns `replacing`.
// Establish the right separator before starting an idle token's composition.
// Remote IMK ignores replacement ranges while a composition is active, so a
// trailing separator cannot be detached from a mark by shrinking that mark.
final class SpacingComposition {
  private(set) var text = ""
  private var range: NSRange
  private var selection: NSRange
  private var marked: NSRange
  private var documentLength: Int
  private var rendered: String
  private var suffix: String?
  private var outsideSuffix = false
  private let before: String
  private let after: String
  #if SYNTHETIC_IMK_PROBE && SYNTHETIC_SPACING_P
  private(set) var hasPendingSeparator = false
  #endif

  init?(client: IMKTextInput, replacing range: NSRange) {
    let length = client.length()
    let selection = client.selectedRange()
    guard client.supportsProperty(UInt32(kTSMDocumentSupportDocumentAccessPropertyTag)),
          length >= 0, length != NSNotFound,
          range.location >= 0, range.location <= length,
          range.length >= 0, range.length <= length - range.location,
          selection.length == 0, selection.location >= range.location,
          selection.location <= NSMaxRange(range) else { return nil }
    func read(_ span: NSRange) -> String? {
      if span.length == 0 { return "" }
      guard let value = client.attributedSubstring(from: span), value.length == span.length else { return nil }
      return value.string
    }
    func neighbor(at boundary: Int, before: Bool) -> String? {
      if before ? boundary == 0 : boundary == length { return "" }
      func fetch(_ count: Int) -> String? {
        guard before ? boundary >= count : length - boundary >= count else { return nil }
        let requested = NSRange(location: before ? boundary - count : boundary, length: count)
        var actual = NSRange(location: NSNotFound, length: 0)
        guard let text = client.string(from: requested, actualRange: &actual),
              actual.location >= 0, actual.location <= length,
              actual.length >= count, actual.length <= length - actual.location,
              (text as NSString).length == actual.length,
              before ? NSMaxRange(actual) == boundary : actual.location == boundary else { return nil }
        return text
      }
      guard var text = fetch(1) else { return nil }
      let firstRead = text as NSString
      let unit = firstRead.character(at: before ? firstRead.length - 1 : 0)
      let high = (0xD800...0xDBFF).contains(unit)
      let low = (0xDC00...0xDFFF).contains(unit)
      if before ? high : low { return nil } // caret inside a surrogate pair
      if before ? low : high {
        if firstRead.length == 1 {
          guard let expanded = fetch(2) else { return nil }
          text = expanded
        }
        let units = text as NSString
        let partner = units.character(at: before ? units.length - 2 : 1)
        guard before ? (0xD800...0xDBFF).contains(partner) : (0xDC00...0xDFFF).contains(partner) else { return nil }
      }
      return text
    }
    guard let before = neighbor(at: range.location, before: true),
          let after = neighbor(at: NSMaxRange(range), before: false),
          let original = read(range) else { return nil }
    self.range = range
    self.selection = selection
    self.marked = client.markedRange()
    self.documentLength = length
    self.rendered = original
    self.before = before
    self.after = after
  }

  func requiresSpacing(for text: String) -> Bool {
    let spaces = spacesAroundInsertion(text, left: before.last, right: after.first)
    return spaces.before || spaces.after
  }

  func isCurrent(in client: IMKTextInput) -> Bool {
    let selectedMatches = client.selectedRange() == selection
    let markedMatches = client.markedRange() == marked
    let lengthMatches = client.length() == documentLength
    guard selectedMatches, markedMatches, lengthMatches else {
      #if SYNTHETIC_IMK_PROBE
      if client.bundleIdentifier() == "com.example.SquirrelSyntheticTextHost" {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "SquirrelTests", category: "lifecycle")
          .notice("snapshot selection=\(selectedMatches) marked=\(markedMatches) length=\(lengthMatches)")
      }
      #endif
      return false
    }
    let left = NSRange(location: range.location - before.utf16.count, length: before.utf16.count)
    let right = NSRange(location: NSMaxRange(range), length: after.utf16.count)
    let ownedMatches = range.length == 0 || client.attributedSubstring(from: range)?.string == rendered
    let beforeMatches = before.isEmpty || client.attributedSubstring(from: left)?.string == before
    let afterMatches = after.isEmpty || client.attributedSubstring(from: right)?.string == after
    #if SYNTHETIC_IMK_PROBE
    if !(ownedMatches && beforeMatches && afterMatches), client.bundleIdentifier() == "com.example.SquirrelSyntheticTextHost" {
      Logger(subsystem: Bundle.main.bundleIdentifier ?? "SquirrelTests", category: "lifecycle")
        .notice("snapshot owned=\(ownedMatches) left=\(beforeMatches) right=\(afterMatches)")
    }
    #endif
    return ownedMatches && beforeMatches && afterMatches
  }

  @discardableResult
  func update(_ text: String, in client: IMKTextInput) -> Bool {
    guard !text.isEmpty, isCurrent(in: client) else { return false }
    let spaces = spacesAroundInsertion(text, left: before.last, right: after.first)
    let prefix = (spaces.before ? " " : "") + text
    let firstUpdate = suffix == nil
    #if SYNTHETIC_IMK_PROBE && SYNTHETIC_SPACING_L
    // L hypothesis: merge the left separator into this token; a later token
    // can supply its own left separator. Existing right text is NOT repaired.
    // This is intentionally not a production fallback or completed feature.
    let suffix = ""
    #else
    let suffix = self.suffix ?? (spaces.after ? " " : "")
    #endif
    var replacement = firstUpdate ? range : NSRange.empty
    #if !(SYNTHETIC_IMK_PROBE && SYNTHETIC_SPACING_P)
    if firstUpdate && range.length == 0 && !suffix.isEmpty {
      // This writes only the owned separator, never an English/numeric token.
      // The first token event must include both operations in one Undo group.
      client.insertText(suffix, replacementRange: range)
      rendered = suffix
      range.length = suffix.utf16.count
      documentLength += range.length
      selection = NSRange(location: NSMaxRange(range), length: 0)
      marked = client.markedRange()
      guard (marked.location == NSNotFound || marked.length == 0), isCurrent(in: client) else { return false }
      outsideSuffix = true
      replacement = NSRange(location: range.location, length: 0)
    }
    #endif
    let transportAnchor = firstUpdate ? selection.location : marked.location
    let next = prefix + suffix
    self.text = text
    self.suffix = suffix
    rendered = next
    documentLength += next.utf16.count - range.length
    range.length = next.utf16.count
    marked = NSRange(location: range.location, length: outsideSuffix ? prefix.utf16.count : next.utf16.count)
    selection = NSRange(location: range.location + prefix.utf16.count, length: 0)
    client.setMarkedText(NSAttributedString(string: outsideSuffix ? prefix : next,
                                            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
                         selectionRange: NSRange(location: prefix.utf16.count, length: 0),
                         replacementRange: replacement)
    // Cocoa receives the requested replacement, but remote IMK can report the
    // inline range relative to the caret at which this session started. Keep
    // that exact wire range as the session fingerprint, never as a write target.
    // Both forms must have the expected length; all text, neighbor, document
    // length and actual caret checks below remain mandatory.
    let reported = client.markedRange()
    #if SYNTHETIC_IMK_PROBE
    if reported != marked, client.bundleIdentifier() == "com.example.SquirrelSyntheticTextHost" {
      Logger(subsystem: Bundle.main.bundleIdentifier ?? "SquirrelTests", category: "lifecycle")
        .notice("markWire actual=\(reported.location):\(reported.length) requested=\(self.marked.location):\(self.marked.length)")
    }
    #endif
    guard reported == marked || reported == NSRange(location: transportAnchor, length: marked.length) else { return false }
    marked = reported
    return isCurrent(in: client)
  }

  @discardableResult
  func finish(in client: IMKTextInput, space: Bool = false, cancel: Bool = false) -> Bool {
    guard isCurrent(in: client) else { return false }
    #if SYNTHETIC_IMK_PROBE && SYNTHETIC_SPACING_P
    // P hypothesis: commit the core, then leave only its right separator in a
    // new mark with selection at zero. This is a deferred transaction, NOT a
    // completed insertion. No host-only unmark/selection/Undo APIs are used.
    let spaces = spacesAroundInsertion(text, left: before.last, right: after.first)
    let core = cancel ? "" : (spaces.before ? " " : "") + text
    let pending = !cancel && (spaces.after || space) ? " " : ""
    if cancel {
      client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: .empty)
    } else {
      client.insertText(core, replacementRange: .empty)
    }
    documentLength += core.utf16.count - range.length
    range.length = core.utf16.count
    rendered = core
    selection = NSRange(location: NSMaxRange(range), length: 0)
    marked = client.markedRange()
    guard (marked.location == NSNotFound || marked.length == 0), isCurrent(in: client) else { return false }
    if !pending.isEmpty {
      client.setMarkedText(NSAttributedString(string: pending), selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: selection)
      rendered += pending
      range.length += pending.utf16.count
      documentLength += pending.utf16.count
      marked = NSRange(location: selection.location, length: pending.utf16.count)
      hasPendingSeparator = true
    }
    self.suffix = pending
    return isCurrent(in: client)
    #else
    #if SYNTHETIC_IMK_PROBE && SYNTHETIC_SPACING_L
    let spaces = (before: spacesAroundInsertion(text, left: before.last, right: after.first).before, after: false)
    #else
    let spaces = spacesAroundInsertion(text, left: before.last, right: after.first)
    #endif
    var committed = cancel ? "" : (spaces.before ? " " : "") + text
    if space && !cancel { committed += " " }
    // Normal completion replaces exactly the mark. Cancellation, consuming a
    // separator, and a changed final boundary also own the external separator.
    // Undo grouping belongs to the host and must be tested through IMK.
    let keepSuffix = !space && !cancel && (spaces.after ? " " : "") == (suffix ?? "")
    var replacement = keepSuffix && outsideSuffix ? NSRange.empty : range
    if keepSuffix && !outsideSuffix { replacement.length -= (suffix ?? "").utf16.count }
    if !keepSuffix && spaces.after && !space && !cancel { committed += " " }
    if outsideSuffix && !keepSuffix {
      // Active-session insertText ranges are also normalized by remote IMK.
      // Clear the mark before replacing the owned separator on Space.
      let clearMark = cancel || space
      if clearMark {
        client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: .empty)
      } else {
        client.insertText(committed, replacementRange: .empty)
      }
      let intermediateCore = clearMark ? "" : committed
      let intermediate = intermediateCore + (suffix ?? "")
      documentLength += intermediate.utf16.count - range.length
      range.length = intermediate.utf16.count
      rendered = intermediate
      selection = NSRange(location: range.location + intermediateCore.utf16.count, length: 0)
      marked = client.markedRange()
      guard (marked.location == NSNotFound || marked.length == 0), isCurrent(in: client) else { return false }
      replacement = NSRange(location: selection.location, length: (suffix ?? "").utf16.count)
      if space && !cancel {
        client.insertText(committed, replacementRange: replacement)
      } else {
        client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: replacement)
      }
    } else if cancel {
      client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: .empty)
    } else {
      client.insertText(committed, replacementRange: replacement)
    }
    let result = committed + (keepSuffix ? (suffix ?? "") : "")
    let resultRange = NSRange(location: range.location, length: result.utf16.count)
    let finalMark = client.markedRange()
    let left = NSRange(location: range.location - before.utf16.count, length: before.utf16.count)
    let right = NSRange(location: NSMaxRange(resultRange), length: after.utf16.count)
    return client.length() == documentLength - range.length + result.utf16.count &&
      client.selectedRange() == NSRange(location: range.location + committed.utf16.count, length: 0) &&
      (finalMark.location == NSNotFound || finalMark.length == 0) &&
      (result.isEmpty || client.attributedSubstring(from: resultRange)?.string == result) &&
      (before.isEmpty || client.attributedSubstring(from: left)?.string == before) &&
      (after.isEmpty || client.attributedSubstring(from: right)?.string == after)
    #endif
  }

  #if SYNTHETIC_IMK_PROBE && SYNTHETIC_SPACING_P
  func settlePendingSeparator(in client: IMKTextInput, forNextInsertion: Bool) -> Bool {
    guard hasPendingSeparator, isCurrent(in: client) else { return false }
    let tokenTail = selection
    let pending = suffix ?? ""
    if forNextInsertion {
      // The next token supplies its left separator; do not commit the pending
      // separator separately. Still test the next token's actual Undo history.
      client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: .empty)
      rendered = String(rendered.dropLast(pending.count))
      range.length -= pending.utf16.count
      documentLength -= pending.utf16.count
    } else {
      client.insertText(pending, replacementRange: .empty)
    }
    marked = client.markedRange()
    hasPendingSeparator = false
    let caretMatches = client.selectedRange() == tokenTail
    Logger(subsystem: Bundle.main.bundleIdentifier ?? "SquirrelTests", category: "lifecycle")
      .notice("pendingSettled next=\(forNextInsertion) caretMatches=\(caretMatches) expected=\(tokenTail.location) actual=\(client.selectedRange().location)")
    // A closing transaction that moves the caret is rejected, not repaired by
    // a second mark, synthetic arrow, or host-side selection setter.
    return isCurrent(in: client) && (marked.location == NSNotFound || marked.length == 0) && caretMatches
  }
  #endif
}
