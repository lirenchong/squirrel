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
    func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
      _ = controller.handle(event, client: client)
    }
    func type(_ text: String) { for char in text { key(String(char)) } }
    type(mode == "unsupported" ? "zz" : "xk")
    guard let initial = controller.candidateDeletionTarget(index: nil) else { print("BLOCK no candidates"); exit(2) }
    let session = initial.session
    func property(_ name: String) -> String {
      var buffer = [CChar](repeating: 0, count: 256)
      return api.get_property(session, name, &buffer, buffer.count) ? String(cString: buffer) : ""
    }
    func query(_ input: String) { api.clear_composition(session); key("", code: 53); type(input) }
    func snapshot(_ name: String) {
      guard let content = panel.contentView else { return }
      content.layoutSubtreeIfNeeded()
      content.displayIfNeeded()
      guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let artifacts = appDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts")
      try! bitmap.representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("panel-\(mode)-\(name).png"))
    }
    func mouse(_ row: Int) -> NSEvent {
      panel.contentView?.layoutSubtreeIfNeeded()
      panel.contentView?.displayIfNeeded()
      let view = panel.contentView!.subviews.compactMap { $0 as? SquirrelView }.first!
      view.textLayoutManager.textViewportLayoutController.layoutViewport()
      // Find a real hit, rather than bypassing SquirrelView's layout/hit testing.
      for y in stride(from: 1.0, to: view.bounds.height, by: 2) {
        for x in stride(from: 1.0, to: view.bounds.width, by: 2) {
          let point = NSPoint(x: x, y: y)
          if view.click(at: point).0 == row {
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
    snapshot("before")
    check(initial.highlighted == 0 && initial.candidates.first == (mode == "unsupported" ? "孤舟" : "杏"), "anonymous engine highlights intended first row")
    print("Lua runtime \(property("panel_lua_runtime")); anonymous profile \(userDir.path)")
    if mode == "mismatch" {
      check(!menu(1).items[0].isEnabled, "wrong runtime menu disabled")
      api.set_property(session, "suppression_action", "sentinel")
      key("\u{f728}", code: 117, flags: .control)
      check(property("suppression_action") == "sentinel" && controller.candidateDeletionTarget(index: nil)?.candidates == initial.candidates,
            "wrong runtime keyboard sends no bridge and preserves candidates")
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
        check(!menu(0).items[0].isEnabled, "missing/wrong protocol disables menu")
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
