// Run from the fork root: swift scripts/host-text-probe.swift
// Synthetic, offscreen Cocoa probe only. NSTextView is NOT Squirrel's IMKTextInput proxy.
import AppKit

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  guard condition() else {
    fputs("FAIL \(label)\n", stderr)
    exit(1)
  }
  print("PASS \(label)")
}

// The caller supplies the document-relative UTF-16 snapshot. A real IMKTextInput
// may return NSNotFound/nil or a differently sized substring; none permits a write.
func lineSnapshot(selection: NSRange, length: Int, marked: Bool = false,
                  read: (NSRange) -> NSAttributedString?) -> (String, String, NSRange)? {
  guard !marked, selection.location != NSNotFound, selection.length == 0,
        length >= 0, length != NSNotFound, selection.location <= length,
        let content = read(NSRange(location: 0, length: length)), content.length == length else {
    return nil
  }
  let text = content.string as NSString
  let caret = selection.location
  if caret > 0 && caret < length {
    let before = text.character(at: caret - 1)
    let after = text.character(at: caret)
    // Neither a CRLF pair nor a UTF-16 surrogate pair has a writable interior caret.
    if (before == 13 && after == 10) ||
       ((0xD800...0xDBFF).contains(Int(before)) && (0xDC00...0xDFFF).contains(Int(after))) {
      return nil
    }
  }
  var start = caret
  while start > 0 {
    let unit = text.character(at: start - 1)
    if unit == 10 || unit == 13 { break }
    start -= 1
  }
  var end = caret
  while end < length {
    let unit = text.character(at: end)
    if unit == 10 || unit == 13 { break }
    end += 1
  }
  return (text.substring(with: NSRange(location: start, length: caret - start)),
          text.substring(with: NSRange(location: caret, length: end - caret)),
          NSRange(location: start, length: end - start))
}

let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
view.string = "甲A😀乙\r\n汉B\n末Z"
view.setSelectedRange(NSRange(location: 2, length: 0)) // between A and 😀
var actual = NSRange(location: NSNotFound, length: 0)
let documentLength = (view.string as NSString).length
let contents = view.attributedSubstring(forProposedRange: NSRange(location: 0, length: documentLength),
                                        actualRange: &actual)
check(documentLength == 12, "UTF-16 document length (emoji two code units)")
check(view.selectedRange() == NSRange(location: 2, length: 0), "Cocoa caret offset 2")
check(actual == NSRange(location: 0, length: 12) && contents?.length == 12,
      "Cocoa exact complete document read")

func cocoaLine() -> (String, String, NSRange)? {
  let length = (view.string as NSString).length
  return lineSnapshot(selection: view.selectedRange(), length: length, marked: view.hasMarkedText()) { range in
    var actual = NSRange(location: NSNotFound, length: 0)
    let value = view.attributedSubstring(forProposedRange: range, actualRange: &actual)
    return actual == range ? value : nil
  }
}

let first = cocoaLine()
check(first?.0 == "甲A" && first?.1 == "😀乙" && first?.2 == NSRange(location: 0, length: 5),
      "line-middle left/right and UTF-16 line range")
view.setSelectedRange(NSRange(location: 5, length: 0)) // just before CRLF
check(cocoaLine()?.2 == NSRange(location: 0, length: 5), "caret before CRLF ends prior line")
view.setSelectedRange(NSRange(location: 8, length: 0)) // after 汉, before B
let second = cocoaLine()
check(second?.0 == "汉" && second?.1 == "B" && second?.2 == NSRange(location: 7, length: 2),
      "CRLF belongs to neither adjacent logical line")
view.setSelectedRange(NSRange(location: 6, length: 0)) // inside CRLF
check(cocoaLine() == nil, "caret inside CRLF fails closed")
view.setSelectedRange(NSRange(location: 10, length: 0)) // after LF, at beginning of 末Z
let third = cocoaLine()
check(third?.0 == "" && third?.1 == "末Z" && third?.2 == NSRange(location: 10, length: 2),
      "caret after LF starts the next line")
view.string = "甲\n\n乙"
view.setSelectedRange(NSRange(location: 2, length: 0))
let empty = cocoaLine()
check(empty?.0 == "" && empty?.1 == "" && empty?.2 == NSRange(location: 2, length: 0),
      "empty logical line between LF delimiters")
view.string = "甲A😀乙\r\n汉B\n末Z"
view.setSelectedRange(NSRange(location: 1, length: 3))
let beforeSelection = view.string
check(view.selectedRange() == NSRange(location: 1, length: 3) && cocoaLine() == nil &&
      view.string == beforeSelection, "Cocoa nonempty selection skips read/write")

let whole = NSAttributedString(string: view.string)
check(lineSnapshot(selection: NSRange(location: NSNotFound, length: NSNotFound), length: 12,
                   read: { _ in whole }) == nil, "unavailable IMK selection fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 2, length: 2), length: 12,
                   read: { _ in whole }) == nil, "nonempty selection fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 13, length: 0), length: 12,
                   read: { _ in whole }) == nil, "out-of-bounds caret fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 3, length: 0), length: 12,
                   read: { _ in whole }) == nil, "split emoji surrogate fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 2, length: 0), length: 12, marked: true,
                   read: { _ in whole }) == nil, "marked composition fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 2, length: 0), length: NSNotFound,
                   read: { _ in whole }) == nil, "unavailable IMK length fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 2, length: 0), length: 12,
                   read: { _ in nil }) == nil, "nil IMK substring fails closed (simulated)")
check(lineSnapshot(selection: NSRange(location: 2, length: 0), length: 12,
                   read: { _ in NSAttributedString(string: "甲A😀乙") }) == nil,
      "truncated IMK substring fails closed (simulated)")

view.setSelectedRange(NSRange(location: 2, length: 0))
view.insertText("新😀", replacementRange: NSRange(location: 1, length: 3)) // replace A😀, not caret
check(view.string == "甲新😀乙\r\n汉B\n末Z", "Cocoa targeted UTF-16 replacement, not insertion at caret")
check(view.selectedRange() == NSRange(location: 4, length: 0),
      "Cocoa caret moves to replacement end (original caret 2 is NOT preserved)")

// A fixture may set up its caret; the tested edit path may only use the IMKTextInput
// operation insertText(_:replacementRange:), never a client selection setter.
// The offscreen window exposes NSTextView's undo manager to the test harness only;
// IMKTextInput has no API to require grouping or to invoke undo in a target app.
func tryInsert(_ name: String, original: String, initialCaret: Int, offsets: [Int],
               expected: String, expectedCaret: Int) {
  let client = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
  let window = NSWindow(contentRect: client.frame, styleMask: .borderless, backing: .buffered, defer: false)
  window.contentView = client // never ordered onscreen or made key
  client.allowsUndo = true
  client.string = original
  client.setSelectedRange(NSRange(location: initialCaret, length: 0))
  check(client.undoManager != nil && client.undoManager?.canUndo == false,
        "\(name): clean fixture undo stack")
  for offset in offsets {
    client.insertText(" ", replacementRange: NSRange(location: offset, length: 0))
  }
  check(client.string == expected && client.selectedRange() == NSRange(location: expectedCaret, length: 0),
        "\(name): expected text and logical caret")
  if offsets.isEmpty {
    check(client.undoManager?.canUndo == false, "\(name): no edit means no undo entry")
  } else {
    check(client.undoManager?.canUndo == true, "\(name): Cocoa registered undo")
    client.undoManager?.undo() // test harness simulates the user's Undo, not an IMK editing operation
    check(client.string == original && client.selectedRange() == NSRange(location: initialCaret, length: 0)
          && client.undoManager?.canUndo == false,
          "\(name): one Cocoa undo restores original text and caret")
  }
}
tryInsert("at caret, left boundary", original: "甲ab😀乙", initialCaret: 1,
          offsets: [1], expected: "甲 ab😀乙", expectedCaret: 2)
tryInsert("left of middle caret", original: "甲ab😀乙", initialCaret: 3,
          offsets: [1], expected: "甲 ab😀乙", expectedCaret: 4)
tryInsert("right of middle caret", original: "甲ab😀乙", initialCaret: 3,
          offsets: [5], expected: "甲ab😀 乙", expectedCaret: 3)
tryInsert("at caret, right boundary", original: "甲ab😀乙", initialCaret: 5,
          offsets: [5], expected: "甲ab😀 乙", expectedCaret: 6)
tryInsert("right then left", original: "甲ab😀乙", initialCaret: 3,
          offsets: [5, 1], expected: "甲 ab😀 乙", expectedCaret: 4)
tryInsert("left then right", original: "甲ab😀乙", initialCaret: 3,
          offsets: [1, 6], expected: "甲 ab😀 乙", expectedCaret: 4)
tryInsert("already spaced, no-op", original: "甲 ab😀 乙", initialCaret: 4,
          offsets: [], expected: "甲 ab😀 乙", expectedCaret: 4)

// C's candidate write order, with literal independent boundary expectations.
// Crucially, test the *sequence*: three one-character passes must grow one
// contiguous ASCII token, not three separately spaced tokens.
let token = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
let tokenWindow = NSWindow(contentRect: token.frame, styleMask: .borderless, backing: .buffered, defer: false)
tokenWindow.contentView = token // offscreen, never key
token.string = "甲乙"
token.setSelectedRange(NSRange(location: 1, length: 0))
let sequence: [(String, String, Int)] = [
  ("a", "甲 a 乙", 3),
  ("b", "甲 ab 乙", 4),
  ("2", "甲 ab2 乙", 5)
]
var allStepsMatch = true
for (letter, expectedText, expectedCaret) in sequence {
  let originalCaret = token.selectedRange().location
  let original = token.string as NSString
  let before = originalCaret > 0 && original.substring(with: NSRange(location: originalCaret - 1, length: 1)) == "甲"
  let after = originalCaret < original.length && original.substring(with: NSRange(location: originalCaret, length: 1)) == "乙"
  if after {
    token.insertText(" ", replacementRange: NSRange(location: originalCaret, length: 0))
    check((token.string as NSString).substring(with: NSRange(location: originalCaret, length: 1)) == " ",
          "C first targeted right space confirmed")
  }
  token.insertText((before ? " " : "") + letter,
                   replacementRange: NSRange(location: originalCaret, length: 0))
  let textMatch = token.string == expectedText
  let caretMatch = token.selectedRange() == NSRange(location: expectedCaret, length: 0)
  print("C step status=observed textMatch=\(textMatch) caretMatch=\(caretMatch) selection=\(token.selectedRange())")
  allStepsMatch = allStepsMatch && textMatch && caretMatch
}

// D's exact IMKTextInput hypothesis on an offscreen NSTextView, not an IMK
// proxy: commit once, then ask an empty marked string to position the caret.
// Literal expected document, UTF-16 caret, and absent marked state per key.
let dClient = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
let dWindow = NSWindow(contentRect: dClient.frame, styleMask: .borderless, backing: .buffered, defer: false)
dWindow.contentView = dClient // never onscreen
dClient.string = "甲乙"
dClient.setSelectedRange(NSRange(location: 1, length: 0))
var dStepsMatch = true
for (letter, expectedText, expectedCaret) in sequence {
  let insertion = dClient.selectedRange().location
  let original = dClient.string as NSString
  if insertion == NSNotFound || insertion > original.length {
    dStepsMatch = false
    print("D step status=invalid-selection selection=\(dClient.selectedRange()) marked=\(dClient.markedRange())")
    break
  }
  let before = insertion > 0 && original.substring(with: NSRange(location: insertion - 1, length: 1)) == "甲"
  let after = insertion < original.length && original.substring(with: NSRange(location: insertion, length: 1)) == "乙"
  let combined = (before ? " " : "") + letter + (after ? " " : "")
  dClient.insertText(combined, replacementRange: NSRange(location: NSNotFound, length: 0))
  let desired = insertion + combined.utf16.count - (after ? 1 : 0)
  dClient.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                        replacementRange: NSRange(location: desired, length: 0))
  let selection = dClient.selectedRange()
  let marked = dClient.markedRange()
  let textMatch = dClient.string == expectedText
  let caretMatch = selection == NSRange(location: expectedCaret, length: 0)
  let hasMarked = dClient.hasMarkedText()
  let markClear = marked.location == NSNotFound && !hasMarked
  print("D step status=observed textMatch=\(textMatch) caretMatch=\(caretMatch) markClear=\(markClear) hasMarked=\(hasMarked) selection=\(selection) marked=\(marked)")
  dStepsMatch = dStepsMatch && textMatch && caretMatch && markClear
  if !textMatch || !caretMatch || !markClear {
    print("D status=halt-after-unexpected-state selection=\(selection) marked=\(marked)")
    break // no forced b/2 after a left a marked range in the client
  }
}
let dOutcome = dStepsMatch && dClient.string == "甲 ab2 乙" &&
  dClient.selectedRange() == NSRange(location: 5, length: 0) && !dClient.hasMarkedText()
if !dOutcome { fputs("FAIL D continuous token, caret, or marked state\n", stderr) }

// Even a fresh, idle Cocoa view can return a valid zero-length markedRange.
// IMKTextInput has no hasMarkedText API to distinguish this state from a
// composition owned by the Rime path; do not take over it in a test IME.
let idleClient = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
let idleWindow = NSWindow(contentRect: idleClient.frame, styleMask: .borderless, backing: .buffered, defer: false)
idleWindow.contentView = idleClient
idleClient.string = "甲乙"
idleClient.setSelectedRange(NSRange(location: 1, length: 0))
print("E preflight status=observed selection=\(idleClient.selectedRange()) marked=\(idleClient.markedRange()) hasMarked=\(idleClient.hasMarkedText())")
check(!idleClient.hasMarkedText() && idleClient.markedRange() == NSRange(location: 2, length: 0),
      "E blocker: idle Cocoa client exposes a valid zero-length marked range")
check(allStepsMatch && token.string == "甲 ab2 乙" && token.selectedRange() == NSRange(location: 5, length: 0),
      "C continuous a→b→2 keeps ab2 and caret before right space")
check(dOutcome, "D continuous a→b→2 keeps ab2, caret, and no marked composition")
print("Synthetic Cocoa only; real IMK proxy/native apps/browser/WeChat NOT tested.")
