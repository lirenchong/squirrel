//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit
#if SYNTHETIC_IMK_PROBE
import OSLog
#endif

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  // One switch for every session, menu action and keyboard shortcut. This
  // development build starts off; it does not change global user preferences.
  private static var autoSpacing = false
  private static let controllers = NSHashTable<SquirrelInputController>.weakObjects()
  private var spacingToken: SpacingComposition?
  private var spacingFault = false
  #if SYNTHETIC_IMK_PROBE
  private enum ProbeMode { case off, composed, targeted, rightFirst, emptyMark }
  private var probeMode: ProbeMode = .off
  private static let syntheticHostID = "com.example.SquirrelSyntheticTextHost"
  private static let lifecycleLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SquirrelTests", category: "lifecycle")
  #endif

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    #if SYNTHETIC_IMK_PROBE
    if (sender as? IMKTextInput)?.bundleIdentifier() == Self.syntheticHostID {
      Self.lifecycleLog.notice("handle")
    }
    #endif
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      let wasASCII = rimeAPI.get_option(session, "ascii_mode")
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15 (#715)
      // Some remote desktop software (e.g. Parsec) sends flagsChanged events with
      // keyCode defaulting to 0 (kVK_ANSI_A) instead of the actual modifier keycode,
      // causing a ghost 'a' keypress. Validate and infer the correct keycode from
      // the changed modifier flags when necessary. (#825)
      var keyCode = event.keyCode
      if !SquirrelKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = SquirrelKeycode.inferModifierKeycode(from: changes) else {
          lastModifiers = modifiers
          rimeUpdate()
          handled = true
          break
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      if spacingToken != nil && wasASCII != rimeAPI.get_option(session, "ascii_mode") {
        finishSpacingToken()
      }
      rimeUpdate()

    case .keyDown:
      let shortcutFlags = modifiers.intersection([.control, .option, .shift, .command])
      if event.keyCode == 1 && shortcutFlags == [.control, .option] {
        if !event.isARepeat { toggleAutoSpacing() }
        return true
      }
      #if SYNTHETIC_IMK_PROBE
      if client?.bundleIdentifier() == Self.syntheticHostID {
        Self.lifecycleLog.notice("keyState ascii=\(self.rimeAPI.get_option(self.session, "ascii_mode")) spacing=\(self.spacingAllowed) config=\(NSApp.squirrelAppDelegate.config?.isOpen == true) plain=\(modifiers.isSubset(of: [.shift, .capsLock]))")
      }
      #endif
      if let result = handleSpacingKey(event) { return result }
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      #if SYNTHETIC_IMK_PROBE
      // Only intercept printable synthetic-host ASCII input while Rime is idle.
      // A failed preflight leaves the original key event on its old pass-through path.
      if probeMode != .off, client?.bundleIdentifier() == Self.syntheticHostID,
         rimeAPI.get_option(session, "ascii_mode"),
         modifiers.isSubset(of: [.shift, .capsLock]),
         (rimeAPI.get_input(session).map { String(cString: $0).isEmpty } ?? true),
         let characters = event.characters, characters.count == 1,
         let char = characters.first, char.isASCII && (char.isLetter || char.isNumber),
         probeCommit(characters, passthrough: true) {
        handled = true
        break
      }
      #endif

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          #if SYNTHETIC_IMK_PROBE
          traceIMKState("beforeRimeKeyDown")
          #endif
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          if !handled && beginSpacingToken(event) { return true }
          if spacingToken != nil { finishSpacingToken() }
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    #if SYNTHETIC_IMK_PROBE
    if client?.bundleIdentifier() == Self.syntheticHostID {
      Self.lifecycleLog.notice("activateServer")
      // Observe the actual remote proxy, not a local NSTextView adapter.
      // Capability discovery only: never invoke these host-side methods here.
      let object = client as? NSObjectProtocol
      let textClient = client as? NSTextInputClient
      let unmark = object?.responds(to: #selector(NSTextInputClient.unmarkText)) == true
      let command = object?.responds(to: #selector(NSTextInputClient.doCommand(by:))) == true
      Self.lifecycleLog.notice("publicClientCapability object=\(object != nil) textClient=\(textClient != nil) unmark=\(unmark) command=\(command)")
      traceIMKState("activateServer")
    }
    #endif
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
    Self.controllers.add(self)
    #if SYNTHETIC_IMK_PROBE
    if self.client?.bundleIdentifier() == Self.syntheticHostID {
      Self.lifecycleLog.notice("controllerInit")
    }
    #endif
  }

  override func deactivateServer(_ sender: Any!) {
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    hidePalettes()
    commitComposition(sender)
    client = nil
    spacingFault = false
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    if spacingToken != nil {
      finishSpacingToken()
      return
    }
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    //  commit raw input
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let spacing = NSMenuItem(title: "自动中英数字空格", action: #selector(toggleAutoSpacing), keyEquivalent: "s")
    spacing.keyEquivalentModifierMask = [.control, .option]
    spacing.target = self
    spacing.state = Self.autoSpacing ? .on : .off
    #if SYNTHETIC_IMK_PROBE
    let menu = NSMenu()
    menu.addItem(spacing)
    menu.addItem(.separator())
    let modes: [(String, Selector, Bool)] = [
      ("Synthetic probe off", #selector(probeOff), probeMode == .off),
      ("A: composed boundary commit", #selector(probeComposed), probeMode == .composed),
      ("B: targeted boundary inserts", #selector(probeTargeted), probeMode == .targeted),
      ("C: right boundary, then ASCII commit", #selector(probeRightFirst), probeMode == .rightFirst),
      ("D: empty mark caret hypothesis", #selector(probeEmptyMark), probeMode == .emptyMark)
    ]
    for (title, selector, active) in modes {
      let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
      item.target = self
      item.state = active ? .on : .off
      menu.addItem(item)
    }
    return menu
    #else
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(spacing)
    menu.addItem(.separator())
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
    #endif
  }

  @objc func toggleAutoSpacing() {
    for controller in Self.controllers.allObjects { controller.finishSpacingToken() }
    Self.autoSpacing.toggle()
  }

  private var spacingAllowed: Bool {
    guard Self.autoSpacing, !spacingFault else { return false }
    #if SYNTHETIC_IMK_PROBE
    // The disposable IME must never inspect text in a user's real application.
    return client?.bundleIdentifier() == Self.syntheticHostID && probeMode == .off
    #else
    return true
    #endif
  }

  private func idleSpacingComposition() -> SpacingComposition? {
    guard spacingAllowed, let client, session != 0, preedit.isEmpty,
          (rimeAPI.get_input(session).map { $0.pointee == 0 } ?? true) else { return nil }
    let marked = client.markedRange()
    // A zero-length mark alone says nothing about ownership. The controller
    // and librime must both be idle, and only the current insertion is replaced.
    guard marked.location == NSNotFound || marked.length == 0 else { return nil }
    let selected = client.selectedRange()
    guard selected.length == 0 else { return nil }
    return SpacingComposition(client: client, replacing: selected)
  }

  private func beginSpacingToken(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.isSubset(of: [.shift, .capsLock]),
          let characters = event.characters, characters.count == 1,
          let char = characters.first, char.isASCII, let client else { return false }
    if let token = spacingToken {
      spacingFault = !token.update(token.text + characters, in: client)
      return true
    }
    guard char.isLetter || char.isNumber, let composition = idleSpacingComposition() else { return false }
    spacingToken = composition
    spacingFault = !composition.update(characters, in: client)
    return true // A write was attempted. Never also pass the same key through.
  }

  // nil continues normal Rime routing, false passes straight to the host.
  private func handleSpacingKey(_ event: NSEvent) -> Bool? {
    if spacingFault { return false }
    guard let token = spacingToken, let client else { return nil }
    guard token.isCurrent(in: client) else {
      spacingToken = nil
      spacingFault = true
      return false // Host moved/changed the mark; never overwrite stale offsets.
    }
    let plain = event.modifierFlags.isSubset(of: [.shift, .capsLock])
    if plain && event.keyCode == 53 {
      finishSpacingToken(cancel: true)
      return true
    }
    if plain && event.keyCode == 51 {
      let remaining = String(token.text.dropLast())
      if remaining.isEmpty { finishSpacingToken(cancel: true) }
      else { spacingFault = !token.update(remaining, in: client) }
      return true
    }
    if plain && event.keyCode == 49 {
      finishSpacingToken(space: true)
      return true
    }
    if plain, let characters = event.characters, characters.unicodeScalars.count == 1,
       let scalar = characters.unicodeScalars.first, (0x21...0x7E).contains(scalar.value) {
      // Let librime observe every key (including Shift-use and Pinyin). Only
      // its unhandled text extends our token; handled text ends it first.
      return nil
    }
    finishSpacingToken()
    return spacingFault ? false : nil
  }

  private func finishSpacingToken(space: Bool = false, cancel: Bool = false) {
    guard let token = spacingToken, let client else { return }
    spacingToken = nil
    guard !spacingFault else { return }
    spacingFault = !token.finish(in: client, space: space, cancel: cancel)
  }

  #if SYNTHETIC_IMK_PROBE
  @objc private func probeOff() { probeMode = .off }
  @objc private func probeComposed() { probeMode = .composed }
  @objc private func probeTargeted() { probeMode = .targeted }
  @objc private func probeRightFirst() { probeMode = .rightFirst }
  @objc private func probeEmptyMark() { probeMode = .emptyMark }

  // Numeric ranges and booleans only. Never fetch document text or log key/Rime content.
  private func traceIMKState(_ phase: StaticString) {
    guard let client, client.bundleIdentifier() == Self.syntheticHostID else { return }
    let dapy = client.supportsProperty(UInt32(kTSMDocumentSupportDocumentAccessPropertyTag))
    let rimeInputNonEmpty = session != 0 && (rimeAPI.get_input(session).map { $0.pointee != 0 } ?? false)
    print("IMKState phase=\(phase) selected=\(client.selectedRange()) marked=\(client.markedRange()) dapy=\(dapy) rimeInputNonEmpty=\(rimeInputNonEmpty) preeditNonEmpty=\(!preedit.isEmpty)")
  }

  // Experiment only: never log document text, committed text, key characters, or app identifiers.
  // The bundle gate prevents even a read when the test input source is selected in a real app.
  private func probeCommit(_ text: String, passthrough: Bool) -> Bool {
    guard probeMode != .off, let client, client.bundleIdentifier() == Self.syntheticHostID else { return false }
    if probeMode == .rightFirst || probeMode == .emptyMark {
      guard passthrough, text.utf16.count == 1, let character = text.first,
            character.isASCII && (character.isLetter || character.isNumber) else { return false }
    }
    let access = client.supportsProperty(UInt32(kTSMDocumentSupportDocumentAccessPropertyTag))
    let selected = client.selectedRange()
    let marked = client.markedRange()
    guard access, !text.isEmpty, selected.location != NSNotFound, selected.length == 0 else {
      print("IMKProbe status=skip access=\(access) selection=\(selected)")
      return false
    }
    let length = client.length()
    guard length != NSNotFound, length >= 0 else {
      print("IMKProbe status=skip-length selection=\(selected)")
      return false
    }
    let span = marked.location == NSNotFound ? selected : marked
    guard span.location <= length, span.length != NSNotFound, span.length <= length - span.location,
          selected.location >= span.location, selected.location <= span.location + span.length,
          let adjacent = probeNeighbors(client, span: span, length: length) else {
      print("IMKProbe status=skip-neighbors selection=\(selected) marked=\(marked)")
      return false
    }
    let decision = spacesAroundInsertion(text, left: adjacent.0, right: adjacent.1)
    print("IMKProbe status=preflight selection=\(selected) marked=\(marked) before=\(decision.before) after=\(decision.after) passthrough=\(passthrough)")
    guard client.selectedRange() == selected, client.markedRange() == marked else { return false }

    if probeMode == .emptyMark {
      guard marked.location == NSNotFound, length <= Int.max - 3 else { return false }
      let combined = (decision.before ? " " : "") + text + (decision.after ? " " : "")
      client.insertText(combined, replacementRange: .empty)
      let committed = client.attributedSubstring(from: NSRange(location: selected.location, length: combined.utf16.count))
      let contentMatch = committed?.string == combined && client.length() == length + combined.utf16.count
      guard contentMatch, client.markedRange().location == NSNotFound else {
        print("IMKProbe status=empty-mark-commit-unconfirmed selection=\(client.selectedRange()) marked=\(client.markedRange()) contentMatch=\(contentMatch)")
        return true // already wrote; do not pass the key through or retry
      }
      // Experimental hypothesis only: IMK does not promise an empty marked
      // string is a selection setter. Observe the result without retrying.
      let desired = selected.location + combined.utf16.count - (decision.after ? 1 : 0)
      client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: desired, length: 0))
      let actual = client.selectedRange()
      let markedAfter = client.markedRange()
      let textAfter = client.attributedSubstring(from: NSRange(location: selected.location, length: combined.utf16.count))
      print("IMKProbe status=empty-mark selection=\(actual) marked=\(markedAfter) caretMatch=\(actual == NSRange(location: desired, length: 0)) markClear=\(markedAfter.location == NSNotFound) textMatch=\(textAfter?.string == combined && client.length() == length + combined.utf16.count)")
      return true
    }

    if probeMode == .rightFirst {
      guard marked.location == NSNotFound, length <= Int.max - 3 else { return false }
      let insertion = NSRange(location: selected.location, length: 0)
      if decision.after {
        client.insertText(" ", replacementRange: insertion)
        let spacedLength = client.length()
        let rightSpace = client.attributedSubstring(from: NSRange(location: selected.location, length: 1))
        guard spacedLength == length + 1, rightSpace?.length == 1, rightSpace?.string == " ",
              client.markedRange().location == NSNotFound,
              let neighbors = probeNeighbors(client, span: NSRange(location: selected.location, length: 1), length: spacedLength),
              neighbors.0 == adjacent.0, neighbors.1 == adjacent.1 else {
          print("IMKProbe status=right-first-unconfirmed selection=\(client.selectedRange())")
          return true // space may already exist; do not pass the key through as well
        }
      }
      // The targeted first write may move the host caret. Insert at the original
      // document position; a host that ignores this range can fail this experiment.
      let combined = (decision.before ? " " : "") + text
      client.insertText(combined, replacementRange: insertion)
      let afterCommit = client.selectedRange()
      let committed = client.attributedSubstring(from: NSRange(location: selected.location, length: combined.utf16.count))
      print("IMKProbe status=right-first selection=\(afterCommit) contentMatch=\(committed?.string == combined) caretMatch=\(afterCommit == NSRange(location: selected.location + combined.utf16.count, length: 0))")
      return true
    }

    if probeMode == .composed {
      let combined = (decision.before ? " " : "") + text + (decision.after ? " " : "")
      client.insertText(combined, replacementRange: .empty)
      print("IMKProbe status=composed selection=\(client.selectedRange())")
      return true
    }

    client.insertText(text, replacementRange: .empty)
    let post = client.selectedRange()
    let postLength = client.length()
    let units = text.utf16.count
    guard client.markedRange().location == NSNotFound, post.length == 0,
          post.location != NSNotFound, post.location >= units,
          postLength != NSNotFound, post.location <= postLength,
          let committed = client.attributedSubstring(from: NSRange(location: post.location - units, length: units)),
          committed.length == units, committed.string == text,
          let neighbors = probeNeighbors(client, span: NSRange(location: post.location - units, length: units), length: postLength),
          neighbors.0 == adjacent.0, neighbors.1 == adjacent.1 else {
      print("IMKProbe status=committed-only selection=\(post)")
      return true // original text is already committed; do not commit twice
    }

    // Record the outcome; these are *not* an atomic transaction or an Undo guarantee.
    if decision.after {
      client.insertText(" ", replacementRange: NSRange(location: post.location, length: 0))
      let result = client.attributedSubstring(from: NSRange(location: post.location, length: 1))
      guard result?.length == 1, result?.string == " " else {
        print("IMKProbe status=targeted-right-unconfirmed selection=\(client.selectedRange())")
        return true
      }
    }
    if decision.before {
      client.insertText(" ", replacementRange: NSRange(location: post.location - units, length: 0))
    }
    print("IMKProbe status=targeted selection=\(client.selectedRange()) before=\(decision.before) after=\(decision.after)")
    return true
  }

  private func probeNeighbors(_ client: IMKTextInput, span: NSRange, length: Int)
    -> (Character?, Character?)? {
    let leftCount = min(2, span.location)
    let rightCount = min(2, length - span.location - span.length)
    let left = NSRange(location: span.location - leftCount, length: leftCount)
    let right = NSRange(location: span.location + span.length, length: rightCount)
    var before: Character?
    var after: Character?
    if leftCount != 0 {
      guard let substring = client.attributedSubstring(from: left), substring.length == leftCount else { return nil }
      before = substring.string.last
    }
    if rightCount != 0 {
      guard let substring = client.attributedSubstring(from: right), substring.length == rightCount else { return nil }
      after = substring.string.first
    }
    return (before, after)
  }
  #endif

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
#if SYNTHETIC_IMK_PROBE
    print("createSession: status=true")
#else
    print("createSession: \(app)")
#endif
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
#if !SYNTHETIC_IMK_PROBE
        print("set app option: \(key) = \(value)")
#endif
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    if spacingToken != nil || spacingFault { return }
    rimeConsumeCommittedText()
    if spacingFault { return }

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client, !spacingFault else { return }
    if string.isEmpty { return }
    // print("[DEBUG] commitString: \(string)")
    #if SYNTHETIC_IMK_PROBE
    traceIMKState("beforeRimeCommit")
    if probeCommit(string, passthrough: false) {
      preedit = ""
      hidePalettes()
      traceIMKState("afterRimeCommit")
      return
    }
    #endif
    if spacingAllowed {
      var composition: SpacingComposition?
      let marked = client.markedRange()
      if !preedit.isEmpty, marked.length == preedit.utf16.count,
         client.attributedSubstring(from: marked)?.string == preedit {
        composition = SpacingComposition(client: client, replacing: marked)
      } else if preedit.isEmpty {
        composition = idleSpacingComposition()
      }
      if var composition, composition.requiresSpacing(for: string) {
        if !preedit.isEmpty {
          // Remote IMK ignores replacement ranges while a mark is active.
          // Close only the verified Rime preedit before establishing the final
          // candidate's separator and mark. The candidate is committed once.
          guard composition.finish(in: client, cancel: true),
                let insertion = SpacingComposition(client: client, replacing: client.selectedRange()) else {
            spacingFault = true
            return
          }
          composition = insertion
        }
        spacingFault = !composition.update(string, in: client)
        if !spacingFault { spacingFault = !composition.finish(in: client) }
        preedit = ""
        selRange = NSRange(location: 0, length: 0)
        caretPos = 0
        hidePalettes()
        return
      }
    }
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
    #if SYNTHETIC_IMK_PROBE
    traceIMKState("afterRimeCommit")
    #endif
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    // An idle ASCII pass-through must not start an empty Cocoa composition.
    // Even though hasMarkedText remains false, that empty mark can change the
    // Undo baseline of the next real composition.
    if preedit.isEmpty && self.preedit.isEmpty {
      self.caretPos = caretPos
      self.selRange = selRange
      return
    }
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    #if SYNTHETIC_IMK_PROBE
    traceIMKState("beforeRimeMark")
    #endif
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
    #if SYNTHETIC_IMK_PROBE
    traceIMKState("afterRimeMark")
    #endif
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }
}
