// Compiled with the actual controller and librime, replacing only the app entry.
// The IMKTextInput transport is an in-process adapter to a real NSTextView.
// These are NOT physical keyboard / remote IMK / browser / WeChat tests.
import AppKit
import InputMethodKit

private var failureCount = 0
private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  guard condition() else {
    failureCount += 1
    fputs("FAIL \(label)\n", stderr)
    return
  }
  print("PASS \(label)")
}

private final class CocoaClient: NSObject, IMKTextInput {
  let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
  let window: NSWindow
  var inserts = 0
  var tokenCommits = 0
  var separatorInserts = 0
  var marks = 0
  var documentAccess = true
  var dropsCommit = false
  var traceUndo = false
  var identity = "com.example.SquirrelSyntheticTextHost"
  override init() {
    window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    super.init()
    window.contentView = view
    view.isRichText = false
    view.allowsUndo = true
    view.string = "甲乙"
    view.setSelectedRange(NSRange(location: 1, length: 0))
  }
  func insertText(_ text: Any?, replacementRange: NSRange) {
    if traceUndo {
      print("UNDO insert attributed=\(text is NSAttributedString) range=\(replacementRange) coalescing=\(view.isCoalescingUndo) group=\(view.undoManager?.groupingLevel ?? -1)")
    }
    inserts += 1
    let value = (text as? NSAttributedString)?.string ?? (text as? String) ?? ""
    if value == " " { separatorInserts += 1 }
    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tokenCommits += 1 }
    if !dropsCommit { view.insertText(text ?? "", replacementRange: replacementRange) }
  }
  func setMarkedText(_ text: Any?, selectionRange: NSRange, replacementRange: NSRange) {
    if traceUndo {
      print("UNDO mark attributed=\(text is NSAttributedString) range=\(replacementRange) selection=\(selectionRange) coalescing=\(view.isCoalescingUndo) group=\(view.undoManager?.groupingLevel ?? -1)")
    }
    marks += 1
    view.setMarkedText(text ?? "", selectedRange: selectionRange, replacementRange: replacementRange)
  }
  func selectedRange() -> NSRange { view.selectedRange() }
  func markedRange() -> NSRange { view.markedRange() }
  func attributedSubstring(from range: NSRange) -> NSAttributedString? {
    var actual = NSRange(location: NSNotFound, length: 0)
    let result = view.attributedSubstring(forProposedRange: range, actualRange: &actual)
    return actual == range ? result : nil
  }
  func length() -> Int { view.string.utf16.count }
  func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode,
                      inMarkedRange: UnsafeMutablePointer<ObjCBool>?) -> Int { NSNotFound }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle rect: UnsafeMutablePointer<NSRect>?) -> [AnyHashable: Any]? {
    rect?.pointee = .zero
    return [:]
  }
  func validAttributesForMarkedText() -> [Any]? { [] }
  func overrideKeyboard(withKeyboardNamed name: String?) {}
  func selectMode(_ modeIdentifier: String?) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String? { identity }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { documentAccess }
  func uniqueClientIdentifierString() -> String? { "synthetic-controller-unit" }
  func string(from range: NSRange, actualRange: NSRangePointer?) -> String? {
    view.attributedSubstring(forProposedRange: range, actualRange: actualRange)?.string
  }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = range
    return .zero
  }
}

@main
struct SquirrelApp {
  static let appDir = Bundle.main.bundleURL
  static let userDir = appDir.deletingLastPathComponent().appendingPathComponent("ControllerTestsData")
  static let logDir = userDir.appendingPathComponent("logs")

  static func main() {
    let app = NSApplication.shared
    let delegate = SquirrelApplicationDelegate()
    app.delegate = delegate
    delegate.setupRime()
    delegate.startRime(fullCheck: true)
    delegate.rimeAPI.join_maintenance_thread()
    delegate.loadSettings()
    let server = IMKServer(name: "Squirrel_SyntheticControllerTests", bundleIdentifier: Bundle.main.bundleIdentifier!)!
    func controller(_ client: CocoaClient) -> SquirrelInputController {
      let value = SquirrelInputController(server: server, delegate: nil, client: nil)!
      value.activateServer(client)
      return value
    }
    @discardableResult
    func key(_ value: String, _ code: UInt16, _ controller: SquirrelInputController, _ client: CocoaClient,
             flags: NSEvent.ModifierFlags = []) -> Bool {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                  characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!
      let handled = controller.handle(event, client: client)
      // Separate events so a single-Undo result cannot be explained solely by
      // all keystrokes sharing one top-level run-loop undo group.
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      return handled
    }
    func state(_ client: CocoaClient, _ text: String, _ caret: Int, _ marked: Bool, _ label: String) {
      if client.view.string != text || client.selectedRange() != NSRange(location: caret, length: 0) ||
          client.view.hasMarkedText() != marked {
        print("STATE textMatches=\(client.view.string == text) selection=\(client.selectedRange()) marked=\(client.markedRange())")
      }
      check(client.view.string == text && client.selectedRange() == NSRange(location: caret, length: 0) &&
            client.view.hasMarkedText() == marked, label)
    }

    #if SYNTHETIC_SPACING_L
    // Strict experiment oracle. Never accept missing right spacing, a pending
    // mark, a caret after the right space, or two Undos as completion.
    do {
    let enable = CocoaClient()
    let enableInput = controller(enable)
    check(enableInput.menu().items.first?.state == .off, "experiment default off")
    enableInput.toggleAutoSpacing()
    func receipt(_ client: CocoaClient, _ phase: String) {
      print("EXPERIMENT phase=\(phase) text=\(String(reflecting: client.view.string)) caret=\(client.selectedRange().location) marked=\(client.markedRange()) undo=\(client.view.undoManager?.canUndo == true)")
    }
    for (name, original, start, token, expected, end, ending) in [
      ("line-end", "甲", 1, "ab2", "甲 ab2", 5, "commit"),
      ("right-Han", "甲乙", 1, "ab2", "甲 ab2 乙", 5, "commit"),
      ("Space", "甲乙", 1, "a", "甲 a 乙", 3, "space"),
      ("Enter", "甲乙", 1, "42", "甲 42 乙", 4, "enter"),
      ("punctuation", "甲乙", 1, "a,", "甲 a,乙", 4, "commit"),
      ("blur-unmoved", "甲乙", 1, "a", "甲 a 乙", 3, "blur"),
      ("existing-space", "甲 乙", 2, "a", "甲 a 乙", 3, "commit")
    ] {
      let edge = CocoaClient()
      edge.view.string = original
      edge.view.setSelectedRange(NSRange(location: start, length: 0))
      edge.view.undoManager?.removeAllActions()
      let edgeInput = controller(edge)
      for letter in token { key(String(letter), 0, edgeInput, edge) }
      switch ending {
      case "space": key(" ", 49, edgeInput, edge)
      case "enter": _ = key("\r", 36, edgeInput, edge) // Observe completion before host inserts newline.
      case "blur": edgeInput.deactivateServer(edge)
      default: edgeInput.commitComposition(edge)
      }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
      receipt(edge, "\(name)-finish")
      state(edge, expected, end, false, "\(name): final text + token-tail caret + no mark")
      edge.view.undoManager?.undo()
      receipt(edge, "\(name)-oneUndo")
      state(edge, original, start, false, "\(name): single Cocoa Undo")
    }
    delegate.config = nil
    let chinese = CocoaClient()
    chinese.view.string = "x7"
    chinese.view.setSelectedRange(NSRange(location: 1, length: 0))
    chinese.view.undoManager?.removeAllActions()
    let chineseInput = controller(chinese)
    for (letter, code) in [("j", UInt16(38)), ("i", 34), ("a", 0)] { key(letter, code, chineseInput, chinese) }
    check(chinese.inserts == 0 && chinese.view.hasMarkedText(), "experiment Pinyin remains Rime preedit")
    key(" ", 49, chineseInput, chinese)
    receipt(chinese, "Chinese-finish")
    state(chinese, "x 甲 7", 3, false, "Chinese: final text + token-tail caret + no mark")
    chinese.view.undoManager?.undo()
    receipt(chinese, "Chinese-oneUndo")
    state(chinese, "x7", 1, false, "Chinese: single Cocoa Undo")
    delegate.loadSettings()

    let continuous = CocoaClient()
    continuous.view.string = "甲"
    continuous.view.setSelectedRange(NSRange(location: 1, length: 0))
    let continuousInput = controller(continuous)
    key("4", 21, continuousInput, continuous)
    key("2", 19, continuousInput, continuous)
    continuousInput.commitComposition(continuous)
    delegate.config = nil
    let nextChineseInput = controller(continuous)
    for (letter, code) in [("j", UInt16(38)), ("i", 34), ("a", 0)] { key(letter, code, nextChineseInput, continuous) }
    key(" ", 49, nextChineseInput, continuous)
    receipt(continuous, "continuous-Chinese-number-Chinese")
    state(continuous, "甲 42 甲", 6, false, "next Chinese commit merges its left separator")
    delegate.loadSettings()

    let moved = CocoaClient()
    let movedInput = controller(moved)
    key("a", 0, movedInput, moved)
    moved.view.setSelectedRange(NSRange(location: 0, length: 0))
    let writes = moved.marks + moved.inserts
    movedInput.deactivateServer(moved)
    check(moved.marks + moved.inserts == writes && moved.selectedRange().location == 0,
          "user click/movement is not corrected on blur")
    enableInput.toggleAutoSpacing()
    print("EXPERIMENT evidence=in-process real-host=pending failures=\(failureCount)")
    exit(failureCount == 0 ? 0 : 1)
    }
    #endif

    let client = CocoaClient()
    let input = controller(client)
    check(input.menu().items.first?.state == .off, "spacing starts off")
    check(!key("a", 0, input, client), "off keeps ASCII pass-through")
    check(client.inserts == 0, "off performs no commits")
    state(client, "甲乙", 1, false, "off leaves document and caret unchanged")
    let item = input.menu().items.first!
    check(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.control, .option], "menu exposes Control-Option-S")
    _ = input.perform(item.action!)
    check(input.menu().items.first?.state == .on, "menu enables shared switch")
    for (value, code, expected, caret) in [("a", UInt16(0), "甲 a 乙", 3), ("b", 11, "甲 ab 乙", 4), ("2", 19, "甲 ab2 乙", 5)] {
      check(key(value, code, input, client), "token key consumed")
      state(client, expected, caret, true, "continuous token text/caret/mark")
      check(client.tokenCommits == 0 && client.inserts == 1 && client.separatorInserts == 1,
            "typing writes one separator but never commits token characters")
    }
    input.commitComposition(client)
    state(client, "甲 ab2 乙", 5, false, "final commit keeps caret before right space")
    check(client.tokenCommits == 1 && client.inserts == 2, "one separator write and one final token commit")
    input.commitComposition(client)
    check(client.inserts == 2, "duplicate commit callback is a no-op")
    client.view.undoManager?.undo()
    state(client, "甲乙", 1, false, "actual Cocoa Undo restores original text and caret")

    let editing = CocoaClient()
    let editInput = controller(editing)
    key("a", 0, editInput, editing)
    key("b", 11, editInput, editing)
    key("\u{7f}", 51, editInput, editing)
    state(editing, "甲 a 乙", 3, true, "Backspace removes one token character")
    key("\u{1b}", 53, editInput, editing)
    state(editing, "甲乙", 1, false, "Escape removes token and both owned spaces")
    key("a", 0, editInput, editing)
    key("\u{7f}", 51, editInput, editing)
    state(editing, "甲乙", 1, false, "Backspace to empty removes owned spaces")
    key("a", 0, editInput, editing)
    key(" ", 49, editInput, editing)
    state(editing, "甲 a 乙", 4, false, "Space consumes boundary once and advances caret")

    let other = CocoaClient()
    let otherInput = controller(other)
    key("4", 21, otherInput, other)
    key("2", 19, otherInput, other)
    check(key("s", 1, editInput, editing, flags: [.control, .option]), "shortcut consumed")
    state(other, "甲 42 乙", 4, false, "disabling commits another session once")
    check(other.tokenCommits == 1 && otherInput.menu().items.first?.state == .off, "menu and shortcut share switch across sessions")
    key("s", 1, editInput, editing, flags: [.control, .option])

    let blur = CocoaClient()
    let blurInput = controller(blur)
    key("a", 0, blurInput, blur)
    blurInput.deactivateServer(blur)
    state(blur, "甲 a 乙", 3, false, "loss of focus commits token")
    check(blur.tokenCommits == 1, "focus loss commits token once")

    let undo = CocoaClient()
    let undoInput = controller(undo)
    key("a", 0, undoInput, undo)
    check(!key("z", 6, undoInput, undo, flags: .command), "Cmd-Z commits then passes to host")
    undo.view.undoManager?.undo()
    state(undo, "甲乙", 1, false, "host Undo after active token restores original")

    let space = CocoaClient()
    space.traceUndo = CommandLine.arguments.contains("--trace-undo")
    let spaceInput = controller(space)
    key("a", 0, spaceInput, space)
    key(" ", 49, spaceInput, space)
    state(space, "甲 a 乙", 4, false, "Space ending consumes one boundary")
    space.view.undoManager?.undo()
    print("UNDO space residualSeparator=\(space.view.string == "甲 乙") redo=\(space.view.undoManager?.canRedo == true)")
    state(space, "甲乙", 1, false, "Space ending Undo restores original")
    check(space.view.undoManager?.canUndo == false, "Space Undo leaves no hidden separator action")
    space.view.undoManager?.redo()
    state(space, "甲 a 乙", 4, false, "Space Redo restores complete insertion")
    // Keep the strict one-Undo failures above. Independently distinguish a
    // split Undo history from damaged neighboring text or irreversible edits.
    space.view.undoManager?.undo()
    space.view.undoManager?.undo()
    state(space, "甲乙", 1, false, "Space two Undos restore original text and caret")
    check(space.view.undoManager?.canUndo == false, "Space recovery exhausts fixture Undo history")
    space.view.undoManager?.redo()
    space.view.undoManager?.redo()
    state(space, "甲 a 乙", 4, false, "Space two Redos restore complete insertion")

    // No config means the synthetic schema starts in Chinese mode. The same
    // real librime/controller path must keep jia as Pinyin, not an ASCII token.
    delegate.config = nil
    let chinese = CocoaClient()
    chinese.traceUndo = CommandLine.arguments.contains("--trace-undo")
    chinese.view.string = "x7"
    chinese.view.setSelectedRange(NSRange(location: 1, length: 0))
    let chineseInput = controller(chinese)
    for (letter, code) in [("j", UInt16(38)), ("i", 34), ("a", 0)] { key(letter, code, chineseInput, chinese) }
    check(chinese.inserts == 0 && chinese.view.hasMarkedText(), "Pinyin stays Rime composition")
    key(" ", 49, chineseInput, chinese)
    state(chinese, "x 甲 7", 3, false, "Chinese commit spaces both boundaries and keeps caret")
    check(chinese.tokenCommits == 1 && chinese.separatorInserts == 1 && chinese.inserts == 2,
          "Chinese candidate commits once after one separator write")
    chinese.view.undoManager?.undo()
    print("UNDO chinese residualSeparator=\(chinese.view.string == "x 7") residualPreedit=\(chinese.view.string == "x　7") redo=\(chinese.view.undoManager?.canRedo == true)")
    state(chinese, "x7", 1, false, "Chinese commit Undo restores original")
    check(chinese.view.undoManager?.canUndo == false, "Chinese Undo leaves no hidden separator action")
    chinese.view.undoManager?.redo()
    state(chinese, "x 甲 7", 3, false, "Chinese Redo restores complete insertion")
    chinese.view.undoManager?.undo()
    chinese.view.undoManager?.undo()
    state(chinese, "x7", 1, false, "Chinese two Undos restore original text and caret")
    check(chinese.view.undoManager?.canUndo == false, "Chinese recovery exhausts fixture Undo history")
    chinese.view.undoManager?.redo()
    chinese.view.undoManager?.redo()
    state(chinese, "x 甲 7", 3, false, "Chinese two Redos restore complete insertion")
    let digits = CocoaClient()
    let digitsInput = controller(digits)
    key("4", 21, digitsInput, digits)
    key("2", 19, digitsInput, digits)
    state(digits, "甲 42 乙", 4, true, "Chinese-mode unhandled digits form one token")
    check(digits.tokenCommits == 0, "Chinese-mode digits not committed per key")
    digitsInput.commitComposition(digits)
    check(digits.tokenCommits == 1, "Chinese-mode number commits once")
    delegate.loadSettings()

    for (original, caret, token, expected, end) in [
      ("甲😀乙", 3, "ab", "甲😀ab 乙", 5),
      ("𠀀乙", 2, "42", "𠀀 42 乙", 5),
      ("😀甲乙😀", 3, "ab", "😀甲 ab 乙😀", 6),
      ("甲 乙", 2, "v1.2", "甲 v1.2 乙", 6),
      ("甲\n乙", 2, "a", "甲\na 乙", 3),
      ("甲乙", 1, "a,b", "甲 a,b 乙", 5)
    ] {
      let edge = CocoaClient()
      edge.view.string = original
      edge.view.setSelectedRange(NSRange(location: caret, length: 0))
      let edgeInput = controller(edge)
      for letter in token { key(String(letter), 0, edgeInput, edge) }
      state(edge, expected, end, true, "asymmetric Unicode/existing-space/token boundary")
      edgeInput.commitComposition(edge)
      state(edge, expected, end, false, "boundary final caret")
      check(edge.tokenCommits == 1, "boundary token commits once")
      edge.view.undoManager?.undo()
      state(edge, original, caret, false, "boundary Undo restores original")
    }

    let shifted = CocoaClient()
    let shiftedInput = controller(shifted)
    func shift(_ flags: NSEvent.ModifierFlags) {
      let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                  characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
      _ = shiftedInput.handle(event, client: shifted)
    }
    key("a", 0, shiftedInput, shifted)
    shift(.shift)
    key("B", 11, shiftedInput, shifted, flags: .shift)
    shift([])
    key("2", 19, shiftedInput, shifted)
    state(shifted, "甲 aB2 乙", 5, true, "Shift letter does not toggle mode or split token")
    check(shifted.tokenCommits == 0, "Shift letter leaves token uncommitted")
    shift(.shift)
    shift([])
    state(shifted, "甲 aB2 乙", 5, false, "Shift tap ends token when switching to Chinese")

    let stale = CocoaClient()
    let staleInput = controller(stale)
    key("a", 0, staleInput, stale)
    stale.view.setSelectedRange(NSRange(location: 0, length: 0))
    let writes = stale.marks + stale.inserts
    check(!key("b", 11, staleInput, stale), "stale caret passes event without targeting old offsets")
    staleInput.commitComposition(stale)
    check(stale.marks + stale.inserts == writes, "stale context performs no further writes")

    let changed = CocoaClient()
    let snapshot = SpacingComposition(client: changed, replacing: changed.selectedRange())!
    changed.view.textStorage!.replaceCharacters(in: NSRange(location: 1, length: 1), with: "丙")
    check(!snapshot.update("a", in: changed) && changed.marks == 0, "same-length neighbor change rejects stale snapshot")

    let broken = CocoaClient()
    let brokenInput = controller(broken)
    key("a", 0, brokenInput, broken)
    broken.dropsCommit = true
    brokenInput.commitComposition(broken)
    let brokenWrites = broken.inserts + broken.marks
    check(!key("b", 11, brokenInput, broken), "host dropping commit stops spacing path")
    brokenInput.commitComposition(broken)
    check(broken.inserts + broken.marks == brokenWrites, "no repair/retry writes after unconfirmed commit")

    let unsupported = CocoaClient()
    unsupported.documentAccess = false
    let unsupportedInput = controller(unsupported)
    check(!key("a", 0, unsupportedInput, unsupported), "unsupported document access preserves pass-through")
    check(unsupported.inserts == 0, "unsupported host not committed")
    state(unsupported, "甲乙", 1, false, "unsupported document and caret unchanged")
    guard failureCount == 0 else { fputs("FAIL controller suite; independent cases completed\n", stderr); exit(1) }
    print("PASS controller + real librime + Cocoa; remote IMK event routing remains unverified")
    withExtendedLifetime([input, editInput, otherInput, blurInput, undoInput, chineseInput, staleInput, unsupportedInput]) {}
  }
}
