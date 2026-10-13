// Real panel, real controller, real librime; anonymous in-process transport.
// No physical events, input-source switching, screen capture or installation.
import AppKit
import InputMethodKit
import Darwin

private var failures = 0
private func check(_ ok: Bool, _ name: String) {
  print("\(ok ? "PASS" : "FAIL") \(name)")
  if !ok { failures += 1 }
}

private final class PanelClient: NSObject, IMKTextInput {
  let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
  var inserts = 0
  func insertText(_ text: Any?, replacementRange: NSRange) { inserts += 1; view.insertText(text ?? "", replacementRange: replacementRange) }
  func setMarkedText(_ text: Any?, selectionRange: NSRange, replacementRange: NSRange) { view.setMarkedText(text ?? "", selectedRange: selectionRange, replacementRange: replacementRange) }
  func selectedRange() -> NSRange { view.selectedRange() }
  func markedRange() -> NSRange { view.markedRange() }
  func attributedSubstring(from range: NSRange) -> NSAttributedString? { nil }
  func length() -> Int { view.string.utf16.count }
  func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>?) -> Int { NSNotFound }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle rect: UnsafeMutablePointer<NSRect>?) -> [AnyHashable: Any]? {
    rect?.pointee = NSRect(x: 300, y: 300, width: 1, height: 20); return [:]
  }
  func validAttributesForMarkedText() -> [Any]? { [] }
  func overrideKeyboard(withKeyboardNamed name: String?) {}
  func selectMode(_ modeIdentifier: String?) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String? { "com.example.AnonymousPanelHost" }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String? { "anonymous-panel" }
  func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
}

@main
struct SquirrelApp {
  static let appDir = Bundle.main.bundleURL
  static let userDir = appDir.deletingLastPathComponent().appendingPathComponent("profile")
  static let logDir = userDir.appendingPathComponent("logs")
  static func main() {
    setbuf(stdout, nil)
    let mode = CommandLine.arguments.dropFirst().first ?? "normal"
    let app = NSApplication.shared
    let delegate = SquirrelApplicationDelegate()
    app.delegate = delegate
    delegate.panel = SquirrelPanel(position: NSRect(x: 300, y: 300, width: 400, height: 100))
    let plugin = appDir.appendingPathComponent("Contents/Frameworks/librime-lua.dylib").path
    if FileManager.default.fileExists(atPath: plugin), dlopen(plugin, RTLD_NOW | RTLD_GLOBAL) == nil {
      print("BLOCK plugin: \(String(cString: dlerror()))"); exit(2)
    }
    delegate.setupRime()
    delegate.startRime(fullCheck: true)
    let api = delegate.rimeAPI
    api.join_maintenance_thread()
    api.find_module("lua")?.pointee.initialize?()
    delegate.loadSettings()
    print("runtime \(String(cString: api.get_version()!)); lua_module \(api.find_module("lua") != nil)")
    let server = IMKServer(name: "Squirrel_AnonymousPanelTests", bundleIdentifier: Bundle.main.bundleIdentifier!)!
    let client = PanelClient()
    let controller = SquirrelInputController(server: server, delegate: nil, client: nil)!
    controller.activateServer(client)
    guard let panel = delegate.panel else { print("BLOCK panel unavailable"); exit(2) }
    func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], receiver: SquirrelInputController? = nil) {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
      _ = (receiver ?? controller).handle(event, client: client)
    }
    func type(_ text: String) { for char in text { key(String(char)) } }
    type(mode == "unsupported" ? "zz" : "xk")
    guard let initial = controller.candidateDeletionTarget(index: nil) else { print("BLOCK no candidates"); exit(2) }
    let session = initial.session
    func property(_ name: String) -> String {
      guard let bytes = rimePropertyBytes(api, session: session, name: name, capacity: 128) else { return "" }
      return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    func query(_ input: String) { api.clear_composition(session); key("", code: 53); type(input) }
    func snapshot(_ name: String, content supplied: NSView? = nil) {
      guard let content = supplied ?? panel.contentView else { return }
      content.layoutSubtreeIfNeeded()
      content.displayIfNeeded()
      guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let artifacts = appDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts")
      try! bitmap.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("panel-restore-\(mode)-\(name).png"))
    }
    func mouse(_ row: Int) -> NSEvent {
      panel.contentView?.layoutSubtreeIfNeeded()
      panel.contentView?.displayIfNeeded()
      let view = panel.contentView!.subviews.compactMap { $0 as? SquirrelView }.first!
      view.textLayoutManager.textViewportLayoutController.layoutViewport()
      view.needsDisplay = true
      view.displayIfNeeded()
      // Find a real hit, rather than bypassing SquirrelView's layout/hit testing.
      for y in stride(from: 1.0, to: view.bounds.height, by: 2) {
        for x in stride(from: 1.0, to: view.bounds.width, by: 2) {
          let point = NSPoint(x: x, y: y)
          let hit = view.click(at: point)
          if (row == -1 && hit.1 != nil) || hit.0 == row {
            return NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil),
              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
              context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
          }
        }
      }
      print("missing hit bounds \(view.bounds), preedit \(view.preeditRange), candidates \(view.candidateRanges), text \(view.textView.string)")
      fatalError("No actual hit for row \(row)")
    }
    func menu(_ row: Int) -> NSMenu { panel.candidateMenu(for: mouse(row))! }
    func invoke(_ menu: NSMenu) { menu.performActionForItem(at: 0) }
    func restoreMenu(_ parent: NSMenu) -> NSMenu { parent.items.first { $0.submenu != nil }!.submenu! }
    func restoreIndex(_ menu: NSMenu, code: String, text: String) -> Int {
      menu.items.firstIndex { item in
        guard let target = item.representedObject as? SquirrelInputController.CandidateRestorationTarget else { return false }
        return target.entry.code == code && target.entry.text == text
      }!
    }
    func restore(_ submenu: NSMenu, code: String, text: String) { submenu.performActionForItem(at: restoreIndex(submenu, code: code, text: text)) }
    func captureOwnMenu(_ name: String) {
      // Public views of only this anonymous process's visible popup windows.
      // No CGWindow/screen capture, AX, private menu API or permission request.
      for (index, window) in NSApp.windows.filter({ $0.isVisible && $0.className == "NSPopupMenuWindow" }).enumerated() {
        if let content = window.contentView { snapshot("\(name)-menu-\(index)", content: content) }
      }
    }
    func nativeInspect(_ row: Int, name: String) {
      let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
        MainActor.assumeIsolated {
          guard let active = note.object as? NSMenu else { return }
          let action: @MainActor () -> Void = {
            print("native \(name): \(active.items.map { ($0.title, $0.isEnabled) })")
            captureOwnMenu(name)
            active.cancelTracking()
          }
          RunLoop.current.add(Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
          }, forMode: .eventTracking)
        }
      }
      panel.sendEvent(mouse(row))
      NotificationCenter.default.removeObserver(observer)
    }
    var restoreNumber = 0
    func nativeRestore(_ row: Int, code: String, text: String) {
      restoreNumber += 1
      var pending: NSMenu?
      let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
        MainActor.assumeIsolated {
          guard let active = note.object as? NSMenu else { return }
          let action: @MainActor () -> Void = {
            print("native menu count \(active.items.count), first titles \(active.items.prefix(3).map(\.title))")
            captureOwnMenu("native-\(restoreNumber)-\(pending == nil ? "parent" : "entries")")
            if let submenu = active.items.first(where: { $0.submenu != nil })?.submenu {
              pending = submenu
            } else {
              restore(active, code: code, text: text)
            }
            active.cancelTracking()
          }
          RunLoop.current.add(Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
          }, forMode: .eventTracking)
        }
      }
      panel.sendEvent(mouse(row))
      if let pending {
        _ = pending.popUp(positioning: pending.items[restoreIndex(pending, code: code, text: text)],
          at: NSPoint(x: 20, y: 20), in: panel.contentView)
      }
      NotificationCenter.default.removeObserver(observer)
    }
    snapshot("before")
    check(initial.highlighted == 0 && initial.candidates.first == (mode == "unsupported" ? "孤舟" : "杏"), "anonymous engine highlights intended first row")
    print("Lua runtime \(property("panel_lua_runtime")); anonymous profile \(userDir.path)")
    let canonical = userDir.appendingPathComponent("suppressed.tsv")
    let header = "# rime-candidate-suppression-v1\n"
    if mode == "restore-large" {
      let before = try! Data(contentsOf: canonical)
      let date = try! FileManager.default.attributesOfItem(atPath: canonical.path)[.modificationDate] as! Date
      let context = controller.candidateDeletionTarget(index: -1)!
      let entries = restoreMenu(menu(0))
      check(entries.items.count == 603 && before.count == 21070, "603 entries / 21070 UTF-8 bytes fully read")
      check(context == controller.candidateDeletionTarget(index: -1) && client.inserts == 0, "large list preserves context and commits")
      check(before == (try! Data(contentsOf: canonical)) && date == (try! FileManager.default.attributesOfItem(atPath: canonical.path)[.modificationDate] as! Date), "list does not touch canonical")
      let expected = "匿名0421%\t\r\n🧪"
      let target = entries.items[restoreIndex(entries, code: "shu cai", text: expected)].representedObject as! SquirrelInputController.CandidateRestorationTarget
      check(target.entry.text == expected, "percent/control/emoji decoded exactly once")
      nativeRestore(0, code: "shu cai", text: expected)
      let escapedRow = "shu cai\t匿名0421%25%09%0D%0A🧪\n"
      var expectedBytes = before
      expectedBytes.removeSubrange(before.range(of: Data(escapedRow.utf8))!)
      check(controller.candidateRestorationResult == "ok" && (try! Data(contentsOf: canonical)) == expectedBytes, "selected exact large-list pair restored")
      snapshot("restored")
    } else if mode == "restore-wire" {
      // Test fixture writes only its generated canonical, never production UI.
      let source = header + "lü%25\t百分%2509号\nxing\t行\n"
      try! Data(source.utf8).write(to: canonical)
      let valid = restoreMenu(menu(0))
      check(valid.items.count == 2, "fresh valid list before response faults")
      for fault in ["short", "long", "metadata", "overflow", "allocation", "utf8", "escape", "lower", "duplicate", "order", "blank", "tab", "fold", "fold-accent", "empty", "nul", "header", "tail"] {
        api.set_property(session, "panel_wire_fault", fault)
        let failed = menu(0)
        check(!failed.items.last!.isEnabled && failed.items[0].isEnabled && controller.candidateRestorationResult == "invalid_payload",
              "reject public response \(fault), deletion remains available")
        api.set_property(session, "suppression_action", "sentinel")
        restore(valid, code: "xing", text: "行")
        check(controller.candidateRestorationResult == "stale_target" && property("suppression_action") == "sentinel" && (try! Data(contentsOf: canonical)) == Data(source.utf8),
              "\(fault) does not restore stale snapshot")
      }
      snapshot("invalid-payload")
      api.set_property(session, "panel_wire_fault", "")
      let fresh = restoreMenu(menu(0))
      restore(fresh, code: "lü%", text: "百分%09号")
      check(controller.candidateRestorationResult == "ok" && (try! String(contentsOf: canonical, encoding: .utf8)) == header + "xing\t行\n", "one percent unescape, original pair restored")
    } else if mode == "restore-old" {
      api.set_property(session, "suppression_entries", header + "xing\t行\n")
      api.set_property(session, "suppression_entries_bytes", "41")
      api.set_property(session, "suppression_result", "ok")
      let old = menu(1)
      check(controller.candidateRestorationResult == "invalid_action" && !old.items.last!.isEnabled && old.items[0].isEnabled,
            "actual old protocol1 backend list fails without using old payload")
      nativeInspect(1, name: "old-list-failure")
      snapshot("old-list-failure")
      invoke(old)
      check(controller.candidateDeletionResult == "ok" && controller.candidateDeletionTarget(index: nil)?.candidates == ["杏"], "old backend deletion still usable")
    } else if mode == "restore-learning" {
      query("uucd")
      _ = api.highlight_candidate_on_current_page(session, 1)
      let before = controller.candidateDeletionTarget(index: -1)!
      let empty = menu(1)
      check(!empty.items.last!.isEnabled && empty.items.last!.title.contains("暂无记录") && before == controller.candidateDeletionTarget(index: -1), "empty list preserves nonfirst highlight")
      check(client.inserts == 0 && !FileManager.default.fileExists(atPath: canonical.path), "empty list no commit or canonical creation")
      snapshot("empty")
      key(" ", code: 49)
      check(client.view.string == "蔬菜", "list preserved the nonfirst candidate through Space commit")
      key("\u{8}", code: 51) // immediate physical-key mapping, process-local NSEvent only
      query("uucd")
      print("after BackSpace \(controller.candidateDeletionTarget(index: nil)?.candidates ?? [])")
      check(controller.candidateDeletionTarget(index: nil)?.candidates.first == "树才", "BackSpace immediately undoes learning after list")
      _ = api.highlight_candidate_on_current_page(session, 1)
      key(" ", code: 49)
      query("uucd")
      print("learning control \(controller.candidateDeletionTarget(index: nil)?.candidates ?? [])")
      check(controller.candidateDeletionTarget(index: nil)?.candidates.first == "蔬菜", "control: learning still enabled without BackSpace")
    } else if mode == "restore" || mode == "restore-page" {
      let empty = menu(0)
      check(!empty.items.last!.isEnabled && empty.items.last!.title.contains("暂无记录") && !FileManager.default.fileExists(atPath: canonical.path), "empty list clearly disabled without creating canonical")
      nativeInspect(0, name: "empty")
      snapshot("empty")
      func deleteReading(_ input: String) {
        query(input)
        if mode == "restore-page" { _ = controller.page(up: false) }
        invoke(menu(mode == "restore-page" ? 0 : 1))
        check(controller.candidateDeletionResult == "ok", "actual deletion before restore \(input)")
      }
      deleteReading("xk")
      deleteReading("hh")
      let homographs = restoreMenu(menu(0))
      check(homographs.items.map(\.title) == ["行（hang）", "行（xing）"], "same-text stored readings distinguishable")
      snapshot("homographs")
      nativeRestore(0, code: "xing", text: "行")
      check(controller.candidateRestorationResult == "ok" && controller.candidateDeletionTarget(index: nil)?.candidates == ["航"], "restore xing while current input hh leaves hang suppressed")
      query("xk")
      if mode == "restore-page" { _ = controller.page(up: false) }
      check(controller.candidateDeletionTarget(index: nil)?.candidates.contains("行") == true, "restored xing returns on requery")
      if mode == "restore-page" { _ = controller.page(up: true) }
      if mode == "restore-page" {
        let old = restoreMenu(menu(0))
        _ = controller.page(up: false); _ = controller.page(up: true)
        api.set_property(session, "suppression_action", "sentinel")
        restore(old, code: "hang", text: "行")
        check(controller.candidateRestorationResult == "stale_target" && property("suppression_action") == "sentinel", "page away/back refuses stale restoration")
      }
      nativeRestore(0, code: "hang", text: "行")
      check(controller.candidateRestorationResult == "ok" && (try! String(contentsOf: canonical, encoding: .utf8)) == header, "restore hang independently, not current input xk")
      snapshot("restored")
      query("xk")
      if mode == "restore-page" { _ = controller.page(up: false) }
      invoke(menu(mode == "restore-page" ? 0 : 1))
      invoke(menu(0))
      check(controller.candidateDeletionTarget(index: nil) == nil && panel.isVisible, "zero candidates still show composing panel")
      let zero = restoreMenu(menu(-1))
      check(zero.items.count == 2, "preedit right-click retains recovery entrance")
      snapshot("zero-candidates")
      nativeRestore(-1, code: "xing", text: "杏")
      check(controller.candidateRestorationResult == "ok" && controller.candidateDeletionTarget(index: nil)?.candidates == ["杏"], "recover exact entry from empty candidate page")
      let valid = restoreMenu(menu(0))
      let saved = try! Data(contentsOf: canonical)
      let temporary = userDir.appendingPathComponent("suppressed.tsv.tmp")
      try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
      restore(valid, code: "xing", text: "行")
      check(controller.candidateRestorationResult == "storage_write_failed" && saved == (try! Data(contentsOf: canonical)) && restoreMenu(menu(0)).items.count == 1, "failed restore keeps persistent record and candidate suppression")
      snapshot("write-failure")
      try! FileManager.default.removeItem(at: temporary)
      let oldSchema = restoreMenu(menu(0))
      _ = api.select_schema(session, "synthetic_other")
      restore(oldSchema, code: "xing", text: "行")
      check(controller.candidateRestorationResult == "stale_target" && saved == (try! Data(contentsOf: canonical)), "schema change refuses stale restoration")
      _ = api.select_schema(session, "synthetic"); query("xk")
      let oldComposition = restoreMenu(menu(0))
      query("hh")
      restore(oldComposition, code: "xing", text: "行")
      check(controller.candidateRestorationResult == "stale_target", "composition change refuses stale restoration")
      let oldMenu = restoreMenu(menu(0))
      _ = menu(0)
      api.set_property(session, "suppression_action", "sentinel")
      restore(oldMenu, code: "xing", text: "行")
      check(controller.candidateRestorationResult == "stale_target" && property("suppression_action") == "sentinel", "new menu invalidates older list even with unchanged engine context")
      for badStore in ["corrupt", "unreadable"] {
        let old = restoreMenu(menu(0))
        if badStore == "corrupt" { try! Data((header + "truncated").utf8).write(to: canonical) }
        else { try! FileManager.default.removeItem(at: canonical); try! FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false) }
        let failed = menu(0)
        let reason = badStore == "corrupt" ? "storage_invalid" : "storage_read_failed"
        check(controller.candidateRestorationResult == reason && !failed.items.last!.isEnabled && failed.items.first!.isEnabled, "\(badStore) list fails while deletion remains available")
        nativeInspect(0, name: badStore)
        snapshot(badStore)
        api.set_property(session, "suppression_action", "sentinel")
        restore(old, code: "xing", text: "行")
        check(controller.candidateRestorationResult == "stale_target" && property("suppression_action") == "sentinel", "\(badStore) never consumes old list")
        if badStore == "unreadable" { try! FileManager.default.removeItem(at: canonical) }
        try! saved.write(to: canonical)
      }
      let oldSession = restoreMenu(menu(0))
      let other = SquirrelInputController(server: server, delegate: nil, client: nil)!
      other.activateServer(client)
      for char in "hh" { key(String(char), receiver: other) }
      restore(oldSession, code: "xing", text: "行")
      check(other.candidateRestorationResult == "stale_target" && saved == (try! Data(contentsOf: canonical)), "replaced controller/session cannot restore old menu")
      if let context = other.candidateDeletionTarget(index: -1) { api.clear_composition(context.session) }
      other.deactivateServer(client)
      check(client.inserts == 0, "list/delete/restore/failures never commit")
    } else if mode == "mismatch" {
      check(!menu(1).items[0].isEnabled, "runtime without live processor disables menu")
      api.set_property(session, "suppression_action", "sentinel")
      key("\u{f728}", code: 117, flags: .control)
      check(property("suppression_action") == "sentinel" && controller.candidateDeletionTarget(index: nil)?.candidates == initial.candidates,
            "runtime without live processor sends no bridge and preserves candidates")
    } else if mode == "failure" {
      invoke(menu(1))
      check(controller.candidateDeletionResult == "storage_write_failed" && controller.candidateDeletionTarget(index: nil)?.candidates.contains("行") == true && client.inserts == 0,
            "write failure remains a failure with candidate present")
      print("write result \(controller.candidateDeletionResult)")
      snapshot("failure")
    } else if mode == "unsupported" {
      invoke(menu(0))
      check(controller.candidateDeletionResult == "unsupported_dictionary" && controller.candidateDeletionTarget(index: nil)?.candidates == ["孤舟"] && client.inserts == 0,
            "independent native stabledb remains visibly unsupported, no commit")
      snapshot("unsupported")
      check(controller.candidateDeletionResult == "ok" && controller.candidateDeletionTarget(index: nil) == nil,
            "UNMET independent candidate must be persistently deletable")
    } else {
      check(controller.candidateDeletionUnavailableReason == nil && property("suppression_protocol") == "1" && property("panel_lua_runtime") == "Lua 5.4", "matching runtime and live processor handshake")
      if mode == "page" {
        let oldPage = menu(0)
        _ = controller.page(up: false)
        _ = controller.page(up: true)
        invoke(oldPage)
        check(controller.candidateDeletionResult == "stale_target", "page away and back rejects stale target")
        _ = controller.page(up: false)
      }
      let row = mode == "page" ? 0 : 1
      snapshot("target")
      let event = mouse(row)
      let saved = menu(row)
      check((saved.items[0].representedObject as? SquirrelInputController.CandidateDeletionTarget)?.candidates[row] == "行", "clicked row is actual intended target")
      // Exercise sendEvent and native NSMenu tracking, using in-process menu action only.
      let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
        guard let active = note.object as? NSMenu else { return }
        RunLoop.current.add(Timer(timeInterval: 0.1, repeats: false) { _ in
          active.performActionForItem(at: 0)
          active.cancelTracking()
        }, forMode: .eventTracking)
      }
      panel.sendEvent(event)
      NotificationCenter.default.removeObserver(observer)
      check(controller.candidateDeletionResult == "ok", "panel request reads real ok")
      check(controller.candidateDeletionTarget(index: nil)?.candidates.contains("行") != true && client.inserts == 0, "immediate removal without commit")
      snapshot("deleted")
      query("xk")
      check(controller.candidateDeletionTarget(index: nil)?.candidates.contains("行") != true, "same-code requery suppressed")
      query("hh")
      if mode == "page" { _ = controller.page(up: false) }
      check(controller.candidateDeletionTarget(index: nil)?.candidates.contains("行") == true, "homograph other code retained")
      let stale = menu(0)
      query("xk")
      invoke(stale)
      check(controller.candidateDeletionResult == "stale_target", "changed composition rejects stale menu")
      snapshot("stale")
      let oldSchema = menu(0)
      _ = api.select_schema(session, "synthetic_other")
      invoke(oldSchema)
      check(controller.candidateDeletionResult == "stale_target", "schema change rejects stale target")
      _ = api.select_schema(session, "synthetic")
      query("xk")
      for protocolValue in ["", "2"] {
        api.set_property(session, "suppression_protocol", protocolValue)
        api.set_property(session, "suppression_action", "sentinel")
        let disabled = menu(0)
        check(!disabled.items[0].isEnabled && !disabled.items.last!.isEnabled, "missing/wrong protocol disables delete and restore without list request")
        key("\u{f728}", code: 117, flags: .control)
        check(property("suppression_action") == "sentinel", "missing/wrong protocol keyboard has no native bypass")
      }
      api.set_property(session, "suppression_protocol", "1")
      key("\u{f728}", code: 117, flags: .control)
      print("keyboard result \(controller.candidateDeletionResult), remaining \(String(describing: controller.candidateDeletionTarget(index: nil))), inserts \(client.inserts)")
      check(controller.candidateDeletionResult == "ok" && controller.candidateDeletionTarget(index: nil) == nil && client.inserts == 0,
            "real NSEvent Control+ForwardDelete uses shared result, no commit")
      let persisted = try! String(contentsOf: userDir.appendingPathComponent("suppressed.tsv"), encoding: .utf8)
      check(persisted == "# rime-candidate-suppression-v1\nxing\t杏\nxing\t行\n", "real dictionary identity persisted, not current xk input")
      query("hh")
      let oldSession = menu(0)
      let other = SquirrelInputController(server: server, delegate: nil, client: nil)!
      other.activateServer(client)
      for char in "xk" {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, characters: String(char), charactersIgnoringModifiers: String(char), isARepeat: false, keyCode: 0)!
        _ = other.handle(event, client: client)
      }
      check(other.candidateDeletionTarget(index: nil) == nil, "fresh session requery retains persistent suppression")
      // Show a different anonymous candidate in the new session, then invoke
      // the old menu against this panel's replacement controller.
      let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
      _ = other.handle(escape, client: client)
      for char in "hh" {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, characters: String(char), charactersIgnoringModifiers: String(char), isARepeat: false, keyCode: 0)!
        _ = other.handle(event, client: client)
      }
      invoke(oldSession)
      check(other.candidateDeletionResult == "stale_target", "replacement session rejects old menu")
      if let target = other.candidateDeletionTarget(index: nil) { api.clear_composition(target.session) }
      api.clear_composition(session)
      api.cleanup_all_sessions() // Release this anonymous process's LevelDB lock before export.
      if let custom = api.find_module("levers")?.pointee.get_api?() {
        let levers = UnsafeRawPointer(custom).assumingMemoryBound(to: RimeLeversApi_stdbool.self).pointee
        let count = levers.export_user_dict("synthetic", userDir.appendingPathComponent("anonymous-learning-export.txt").path)
        check(count == 0, "public userdict export contains zero learned entries")
      } else {
        check(false, "public userdict export available for no-learning proof")
      }
      other.deactivateServer(client)
    }
    print("EVIDENCE in-process Cocoa + actual Squirrel panel + real librime; remote/real host pending")
    api.clear_composition(session)
    controller.deactivateServer(client)
    panel.hide()
    api.finalize()
    exit(failures == 0 ? 0 : 1)
  }
}
