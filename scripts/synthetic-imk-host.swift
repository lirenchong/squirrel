// A separate, disposable Cocoa client. Compile as an app bundle; never use real text.
// --focus-test --spacing-test drives this host's NSTextInputContext through
// remote IMK, not global event posting. --background never activates/switches.
// A/B/C/D remain manually selected experiments; the suite uses the default
// controller composition path and synthetic jia -> 甲 dictionary only.
import AppKit
import Carbon
import OSLog

private final class SyntheticTextView: NSTextView {
  var inserts = 0
  var separatorInserts = 0
  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    inserts += 1
    let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String)
    if text == " " { separatorInserts += 1 }
    Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
      .notice("insertReceived replacement=\(replacementRange.location):\(replacementRange.length) empty=\(text?.isEmpty == true) marked=\(self.hasMarkedText()) attributed=\(insertString is NSAttributedString) coalescing=\(self.isCoalescingUndo) group=\(self.undoManager?.groupingLevel ?? -1)")
    super.insertText(insertString, replacementRange: replacementRange)
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let logger = Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
    logger.notice("markReceived selection=\(selectedRange.location):\(selectedRange.length) replacement=\(replacementRange.location):\(replacementRange.length) attributed=\(string is NSAttributedString) coalescing=\(self.isCoalescingUndo) group=\(self.undoManager?.groupingLevel ?? -1)")
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    logger.notice("markApplied selection=\(self.selectedRange().location) marked=\(self.markedRange().location):\(self.markedRange().length)")
  }
  override func keyDown(with event: NSEvent) {
    Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture").notice("viewKeyDown")
    super.keyDown(with: event)
  }
}

@main
struct SyntheticTextHost {
  static var workspaceRoot: URL {
    let parent = Bundle.main.bundleURL.deletingLastPathComponent()
    let build = ["baseline", "L", "P"].contains(parent.lastPathComponent) ? parent.deletingLastPathComponent() : parent
    return build.deletingLastPathComponent().deletingLastPathComponent()
  }
  private static var experimentReceipt: [String: Any] = [:]
  private static func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
  }
  private static func saveExperimentReceipt() {
    guard let run = argument("--run-id"), UUID(uuidString: run) != nil else { return }
    // The offline builder places this app at build/synthetic-imk-probe/VARIANT.
    let directory = workspaceRoot.appendingPathComponent(".amp/in/artifacts")
    guard directory.resolvingSymlinksInPath() == directory.standardizedFileURL,
          FileManager.default.fileExists(atPath: directory.path) else { return }
    let output = directory.appendingPathComponent("remote-\(run).json")
    guard output.resolvingSymlinksInPath() == output.standardizedFileURL else { return }
    experimentReceipt["runID"] = run
    experimentReceipt["case"] = argument("--experiment-case")
    experimentReceipt["evidence"] = "remote-synthetic-NSTextView"
    if let data = try? JSONSerialization.data(withJSONObject: experimentReceipt, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output, options: .atomic)
    }
  }

  static func main() {
    let app = NSApplication.shared
    let background = CommandLine.arguments.contains("--background")
    app.setActivationPolicy(background ? .accessory : .regular)
    if CommandLine.arguments.contains("--web-fixture") {
      guard !background else { exit(2) }
      let fixture = SyntheticWebFixture()
      fixture.start()
      withExtendedLifetime(fixture) { app.run() }
      return
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Synthetic IMK Text Host"
    let view = SyntheticTextView(frame: window.contentView!.bounds)
    view.isRichText = false
    view.allowsUndo = true
    view.isVerticallyResizable = true
    view.autoresizingMask = [.width, .height]
    view.string = "甲乙\n甲😀乙\n甲42乙"
    window.contentView = view
    if background {
      // Prefer an external display away from the user's pointer. If none is
      // available, remain offscreen rather than taking over the working screen.
      let screen = NSScreen.screens.first { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) == 0 && !screen.frame.contains(NSEvent.mouseLocation)
      }
      if let screen {
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 60,
                                      y: screen.visibleFrame.maxY - window.frame.height - 60))
        window.orderBack(nil)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
          .notice("backgroundHost external=\(screen != nil) active=\(app.isActive) key=\(window.isKeyWindow) window=\(window.windowNumber) x=\(window.frame.minX) y=\(window.frame.minY)")
      }
    } else {
      window.makeKeyAndOrderFront(nil)
    }
    window.makeFirstResponder(view)
    view.setSelectedRange(NSRange(location: 1, length: 0))
    let spacingTest = CommandLine.arguments.contains("--spacing-test")
    let contextOnce = CommandLine.arguments.contains("--context-once") || spacingTest
    let focusTest = CommandLine.arguments.contains("--focus-test") && !background
    if focusTest {
      DispatchQueue.main.async {
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
      }
    }
    if contextOnce && !background {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        if focusTest, app.isActive, window.isKeyWindow,
           let context = view.inputContext, let original = context.selectedKeyboardInputSource {
          let expected = "im.rime.inputmethod.Squirrel.SyntheticTest.Hant"
          context.selectedKeyboardInputSource = expected
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if spacingTest { exerciseSpacing(view, window: window) }
            else { exerciseContext(view, window: window) }
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if app.isActive && context.selectedKeyboardInputSource == expected {
              context.selectedKeyboardInputSource = original
              Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
                .notice("focusTestRestored=\(context.selectedKeyboardInputSource == original)")
              experimentReceipt["restored"] = context.selectedKeyboardInputSource == original
              app.hide(nil)
            } else {
              // Never override an external focus/source change. The verifier
              // treats this as incomplete rollback, not successful restoration.
              experimentReceipt["restored"] = false
              experimentReceipt["restoreSkippedExternalChange"] = true
            }
            if argument("--experiment-case") != nil {
              saveExperimentReceipt()
              app.terminate(nil)
            }
          }
        } else {
          exerciseContext(view, window: window)
        }
      }
    }
    if CommandLine.arguments.contains("--send-once") && !background {
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        let expected = "im.rime.inputmethod.Squirrel.SyntheticTest.Hant"
        let logger = Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
        let selected = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let property = TISGetInputSourceProperty(selected, kTISPropertyInputSourceID)
        let sourceMatch = property.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String == expected } ?? false
        let frontMatch = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.example.SquirrelSyntheticTextHost"
        let responderMatch = window.firstResponder === view
        logger.notice("oneShotReady source=\(sourceMatch) front=\(frontMatch) responder=\(responderMatch) keyWindow=\(window.isKeyWindow)")
        guard sourceMatch, frontMatch, responderMatch,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "a", charactersIgnoringModifiers: "a",
                                           isARepeat: false, keyCode: 0) else {
          Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture").notice("oneShotSkipped")
          return
        }
        app.postEvent(event, atStart: false)
        logger.notice("oneShotPosted")
      }
    }
    app.run()
  }

  private static func exerciseSpacing(_ view: SyntheticTextView, window: NSWindow) {
    let logger = Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
    let expected = "im.rime.inputmethod.Squirrel.SyntheticTest.Hant"
    guard let context = view.inputContext else { return }
    logger.notice("undoPolicy automatic=\(view.undoManager?.groupsByEvent == true) defaultMode=\(view.undoManager?.runLoopModes.contains(.default) == true)")
    func ready() -> Bool {
      NSApp.isActive && window.isKeyWindow && window.firstResponder === view &&
        context.selectedKeyboardInputSource == expected
    }
    func verify(_ condition: Bool, _ phase: String) -> Bool {
      logger.notice("spacing phase=\(phase, privacy: .public) pass=\(condition) selection=\(view.selectedRange().location) marked=\(view.hasMarkedText()) tokenCommitted=\(view.inserts > view.separatorInserts)")
      return condition
    }
    func send(_ code: CGKeyCode, flags: CGEventFlags = [], type: CGEventType = .keyDown) -> Bool {
      guard ready(), let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return false }
      key.flags = flags
      key.type = type
      guard let event = NSEvent(cgEvent: key) else { return false }
      let handled = context.handleEvent(event)
      // Task.sleep alone does not close AppKit's automatic event Undo group.
      // Wake only our application's event loop; never post a global keyboard
      // event and never manipulate Undo grouping to manufacture acceptance.
      if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       subtype: 0, data1: 0, data2: 0) {
        NSApp.postEvent(wake, atStart: false)
      }
      return handled
    }
    guard ready() else { return }
    view.string = "甲乙"
    view.setSelectedRange(NSRange(location: 1, length: 0))
    view.undoManager?.removeAllActions()
    view.inserts = 0
    view.separatorInserts = 0
    Task { @MainActor in
      if let experiment = argument("--experiment-case") {
        // One independent case per fresh, default-off IME process. On a failed
        // observation no further IMK key writes are sent; Undo and restoration
        // are measured separately and are never used to relax the assertion.
        let chinese = experiment == "chinese"
        let original = chinese ? "x7" : (experiment == "line-end" ? "甲" : "甲乙")
        view.string = original
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.undoManager?.removeAllActions()
        experimentReceipt = ["complete": false, "restored": false, "userMoved": false]
        experimentReceipt["scope"] = experiment == "click" || experiment == "arrow" ? "user-movement" : "unmoved-completion"
        saveExperimentReceipt()
        guard ready(), send(1, flags: [.maskControl, .maskAlternate]) else { return }
        if chinese {
          _ = send(56, flags: [.maskShift], type: .flagsChanged)
          _ = send(56, type: .flagsChanged)
        }
        let codes: [CGKeyCode] = chinese ? [38, 34, 0] : (experiment == "line-end" || experiment == "right-Han" ? [0, 11, 19] : [0])
        for code in codes {
          try? await Task.sleep(nanoseconds: 100_000_000)
          guard ready(), send(code) else { return }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard ready() else { return }
        switch experiment {
        case "chinese", "space": _ = send(49)
        case "blur": _ = window.makeFirstResponder(nil)
        case "arrow":
          _ = send(123)
          experimentReceipt["userMoved"] = true
        case "click":
          view.setSelectedRange(NSRange(location: 0, length: 0))
          _ = window.makeFirstResponder(nil)
          experimentReceipt["userMoved"] = true
        default: _ = send(1, flags: [.maskControl, .maskAlternate])
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard NSApp.isActive, window.isKeyWindow, context.selectedKeyboardInputSource == expected else { return }
        let expectedText = chinese ? "x 甲 7" : (experiment == "line-end" ? "甲 ab2" : (experiment == "right-Han" ? "甲 ab2 乙" : "甲 a 乙"))
        let tokenTail = chinese ? 3 : (codes.count == 3 ? 5 : 3)
        let expectedCaret = experiment == "click" ? 0 : (experiment == "arrow" ? tokenTail - 1 : tokenTail)
        let textMatches = view.string == expectedText
        let caretMatches = view.selectedRange() == NSRange(location: expectedCaret, length: 0)
        let markClear = !view.hasMarkedText()
        experimentReceipt["textMatches"] = textMatches
        experimentReceipt["caretMatches"] = caretMatches
        experimentReceipt["markClear"] = markClear
        experimentReceipt["actualCaret"] = view.selectedRange().location
        experimentReceipt["expectedCaret"] = expectedCaret
        experimentReceipt["beforeUndoMarkLength"] = view.markedRange().length
        experimentReceipt["eventBoundary"] = view.undoManager?.groupingLevel == 0
        // Host-native Undo only. No manually opened groups or IME Undo API.
        view.undoManager?.undo()
        let undoMatches = view.string == original && view.selectedRange() == NSRange(location: 1, length: 0) && !view.hasMarkedText()
        experimentReceipt["oneUndoMatches"] = undoMatches
        experimentReceipt["undoRemaining"] = view.undoManager?.canUndo == true
        experimentReceipt["complete"] = true
        experimentReceipt["pass"] = textMatches && caretMatches && markClear && undoMatches &&
          view.undoManager?.canUndo == false && experimentReceipt["eventBoundary"] as? Bool == true
        saveExperimentReceipt()
        _ = verify(experimentReceipt["pass"] as? Bool == true, "experimentComplete")
        return
      }
      if !CommandLine.arguments.contains("--chinese-only") {
        guard verify(send(1, flags: [.maskControl, .maskAlternate]), "enable") else { return }
        for (code, text, caret) in [
          (CGKeyCode(0), "甲 a 乙", 3), (11, "甲 ab 乙", 4), (19, "甲 ab2 乙", 5),
        ] {
          try? await Task.sleep(nanoseconds: 100_000_000)
          guard verify(send(code), "keyHandled") else { return }
          guard
            verify(
              view.string == text && view.selectedRange() == NSRange(location: caret, length: 0)
                && view.hasMarkedText() && view.inserts == 1 && view.separatorInserts == 1, "token")
          else { return }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        if CommandLine.arguments.contains("--capture"), ready(),
          let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
          // Render only this fixture's own view; no screen-capture permission or
          // pixels from another application are involved.
          view.cacheDisplay(in: view.bounds, to: image)
          let path = workspaceRoot.appendingPathComponent(".amp/in/artifacts/spacing-token.png")
          if let data = image.representation(using: .png, properties: [:]) {
            try? data.write(to: path, options: .atomic)
          }
        }
        guard verify(send(1, flags: [.maskControl, .maskAlternate]), "disable") else { return }
        guard
          verify(
            view.string == "甲 ab2 乙" && view.selectedRange() == NSRange(location: 5, length: 0)
              && !view.hasMarkedText() && view.inserts == 2 && view.separatorInserts == 1,
            "oneCommit")
        else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard ready() else { return }
        guard verify(view.undoManager?.groupingLevel == 0, "tokenEventBoundary") else { return }
        view.undoManager?.undo()
        guard
          verify(
            view.string == "甲乙" && view.selectedRange() == NSRange(location: 1, length: 0),
            "oneUndo")
        else { return }
        view.undoManager?.removeAllActions()
        guard verify(send(1, flags: [.maskControl, .maskAlternate]), "editingEnable") else {
          return
        }
        for code in [CGKeyCode(0), 11, 51] {
          try? await Task.sleep(nanoseconds: 100_000_000)
          guard verify(send(code), "editingKey") else { return }
        }
        guard
          verify(
            view.string == "甲 a 乙" && view.selectedRange() == NSRange(location: 3, length: 0)
              && view.hasMarkedText(), "backspace")
        else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard verify(send(53), "escapeKey") else { return }
        guard verify(view.string == "甲乙" && !view.hasMarkedText(), "escapeClean") else { return }
        for code in [CGKeyCode(0), 51] {
          try? await Task.sleep(nanoseconds: 100_000_000)
          guard verify(send(code), "emptyBackspaceKey") else { return }
        }
        guard verify(view.string == "甲乙" && !view.hasMarkedText(), "emptyBackspaceClean") else {
          return
        }
        view.undoManager?.removeAllActions()
        for code in [CGKeyCode(0), 49] {
          try? await Task.sleep(nanoseconds: 100_000_000)
          guard verify(send(code), "spaceKey") else { return }
        }
        guard
          verify(
            view.string == "甲 a 乙" && view.selectedRange() == NSRange(location: 4, length: 0)
              && !view.hasMarkedText(), "spaceBoundary")
        else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard ready() else { return }
        guard verify(view.undoManager?.groupingLevel == 0, "spaceEventBoundary") else { return }
        view.undoManager?.undo()
        if !verify(
          view.string == "甲乙" && view.selectedRange() == NSRange(location: 1, length: 0)
            && view.undoManager?.canUndo == false, "spaceUndo")
        {
          // Diagnose reversibility without suppressing the failed one-Undo
          // assertion or sending any further keys through this write path.
          guard
            verify(
              view.string == "甲 乙" && !view.hasMarkedText() && view.undoManager?.canUndo == true,
              "spaceOnlySeparatorRemains")
          else { return }
          view.undoManager?.undo()
          guard
            verify(
              view.string == "甲乙" && view.selectedRange() == NSRange(location: 1, length: 0)
                && view.undoManager?.canUndo == false, "spaceSecondUndo")
          else { return }
          view.undoManager?.redo()
          view.undoManager?.redo()
          _ = verify(
            view.string == "甲 a 乙" && view.selectedRange() == NSRange(location: 4, length: 0)
              && !view.hasMarkedText() && view.undoManager?.canRedo == false, "spaceTwoRedos")
          return
        }
        guard verify(send(1, flags: [.maskControl, .maskAlternate]), "spacingComplete") else {
          return
        }
      }
      view.string = "x7"
      view.setSelectedRange(NSRange(location: 1, length: 0))
      view.undoManager?.removeAllActions()
      view.inserts = 0
      view.separatorInserts = 0
      guard verify(send(1, flags: [.maskControl, .maskAlternate]), "chineseEnable") else { return }
      _ = send(56, flags: [.maskShift], type: .flagsChanged)
      _ = send(56, type: .flagsChanged)
      for code in [CGKeyCode(38), 34, 0] {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard verify(send(code), "pinyinKey") else { return }
        guard verify(view.hasMarkedText() && view.inserts == 0, "pinyinUncommitted") else { return }
      }
      guard verify(send(49), "candidateKey") else { return }
      guard verify(view.string == "x 甲 7" && view.selectedRange() == NSRange(location: 3, length: 0) &&
                   !view.hasMarkedText() && view.inserts == 2 && view.separatorInserts == 1, "chineseBoundary") else { return }
      try? await Task.sleep(nanoseconds: 100_000_000)
      guard ready() else { return }
      guard verify(view.undoManager?.groupingLevel == 0, "chineseEventBoundary") else { return }
      view.undoManager?.undo()
      if !verify(view.string == "x7" && view.selectedRange() == NSRange(location: 1, length: 0) &&
                 view.undoManager?.canUndo == false, "chineseUndo") {
        guard verify(view.string == "x 7" && !view.hasMarkedText() &&
                     view.undoManager?.canUndo == true, "chineseOnlySeparatorRemains") else { return }
        view.undoManager?.undo()
        guard verify(view.string == "x7" && view.selectedRange() == NSRange(location: 1, length: 0) &&
                     view.undoManager?.canUndo == false, "chineseSecondUndo") else { return }
        view.undoManager?.redo()
        view.undoManager?.redo()
        _ = verify(view.string == "x 甲 7" && view.selectedRange() == NSRange(location: 3, length: 0) &&
                   !view.hasMarkedText() && view.undoManager?.canRedo == false, "chineseTwoRedos")
        return
      }
      guard verify(send(1, flags: [.maskControl, .maskAlternate]), "chineseComplete") else { return }
      _ = send(56, flags: [.maskShift], type: .flagsChanged)
      _ = send(56, type: .flagsChanged)
      view.string = "甲乙"
      view.setSelectedRange(NSRange(location: 1, length: 0))
      view.undoManager?.removeAllActions()
      view.inserts = 0
      view.separatorInserts = 0
      // NSTextInputContext also executes ordinary host insertion after the
      // controller returns false; its Bool is not the controller's Bool.
      guard verify(send(0) && view.inserts == 1 && view.separatorInserts == 0 &&
                   view.string == "甲a乙" && view.selectedRange() == NSRange(location: 2, length: 0) && !view.hasMarkedText(),
                   "offPassThrough") else { return }
      view.string = "甲乙"
      view.setSelectedRange(NSRange(location: 1, length: 0))
      view.undoManager?.removeAllActions()
      view.inserts = 0
      guard verify(send(1, flags: [.maskControl, .maskAlternate]), "focusEnable") else { return }
      guard verify(send(0) && view.hasMarkedText(), "focusToken") else { return }
      guard verify(window.makeFirstResponder(nil), "resignResponder") else { return }
      try? await Task.sleep(nanoseconds: 100_000_000)
      guard verify(view.string == "甲 a 乙" && !view.hasMarkedText() && view.inserts == 2 &&
                   view.separatorInserts == 1, "focusCommit") else { return }
      window.makeFirstResponder(view)
      try? await Task.sleep(nanoseconds: 100_000_000)
      guard ready() else { return }
      view.undoManager?.undo()
      guard verify(view.string == "甲乙" && view.selectedRange() == NSRange(location: 1, length: 0), "focusUndo") else { return }
      _ = verify(send(1, flags: [.maskControl, .maskAlternate]), "suiteComplete")
    }
  }

  // Manual foreground/test-source setup only. Never activate or switch input
  // sources here; background testing must not compete with the user's input.
  private static func exerciseContext(_ view: NSTextView, window: NSWindow) {
    let logger = Logger(subsystem: "com.example.SquirrelSyntheticTextHost", category: "fixture")
    let expected = "im.rime.inputmethod.Squirrel.SyntheticTest.Hant"
    guard NSApp.isActive, window.isKeyWindow, window.firstResponder === view,
          let context = view.inputContext, context.selectedKeyboardInputSource == expected else {
      logger.notice("contextSkippedNotActive")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      let sourceMatch = context.selectedKeyboardInputSource == expected
      let active = NSApp.isActive && window.isKeyWindow && window.firstResponder === view
      logger.notice("contextReady source=\(sourceMatch) active=\(active)")
      // Construct a virtual-key event for this context only. No CGEvent.post:
      // this does not inject keyboard events into another process or claim a
      // physical keystroke. Unlike keyEvent(characters:), it has a CGEvent.
      guard sourceMatch, active,
            let key = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let event = NSEvent(cgEvent: key) else {
        return
      }
      let handled = context.handleEvent(event)
      logger.notice("contextOneShot handled=\(handled)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        logger.notice("contextSettled marked=\(view.hasMarkedText()) selection=\(view.selectedRange().location)")
      }
    }
  }
}
