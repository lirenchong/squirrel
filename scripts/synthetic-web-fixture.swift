// Local WebKit surface inside the already-allowlisted synthetic host only.
// No browser profile, external page, IME selection or keyboard injection.
import AppKit
import WebKit

final class SyntheticWebFixture: NSObject, WKNavigationDelegate {
  private let web: WKWebView
  private let window: NSWindow
  private var initialNavigation = true
  private var deniedNavigation = false
  private var finished = false
  private let output = Bundle.main.bundleURL.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".amp/in/artifacts/browser-fixture.png")

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 580, height: 260), configuration: configuration)
    window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    web.navigationDelegate = self
    window.isReleasedWhenClosed = false
    window.title = "Synthetic WebKit Input Fixture — no IMK acceptance yet"
    window.contentView = web
  }

  func start() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    web.loadHTMLString("""
      <!doctype html><html lang="zh-CN"><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
      <title>Synthetic input fixture</title>
      <style>body{font:16px system-ui;margin:28px}textarea{font:24px system-ui;width:95%;height:80px}small{display:block;margin-top:16px}</style>
      <label for="synthetic">独立合成输入框（不是 Chrome / 微信验收）</label>
      <textarea id="synthetic" spellcheck="false">甲乙</textarea>
      <small>仅本地固定页面 · 临时存储 · 禁止外部导航 · 不切换输入法</small>
      </html>
      """, baseURL: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
      if !finished { finish(false) }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if initialNavigation, navigationAction.request.url?.absoluteString == "about:blank" {
      initialNavigation = false
      decisionHandler(.allow)
    } else {
      deniedNavigation = true
      decisionHandler(.cancel)
      // The negative probe is canceled before WebKit may load its destination.
      DispatchQueue.main.async { [self] in verifyAndCapture() }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    web.evaluateJavaScript("document.getElementById('synthetic').focus(); document.getElementById('synthetic').setSelectionRange(1,1)") { [self] _, error in
      guard error == nil else { finish(false); return }
      // Reserved invalid domain; the navigation delegate must deny it. This
      // probes the gate rather than loading or reading any real page.
      web.load(URLRequest(url: URL(string: "https://example.invalid/synthetic-denied")!))
    }
  }

  private func verifyAndCapture() {
    guard !finished, deniedNavigation else { return }
    web.evaluateJavaScript("""
      (() => { const t = document.getElementById('synthetic');
        return location.href === 'about:blank' && t.value === '甲乙' &&
          t.selectionStart === 1 && t.selectionEnd === 1 &&
          document.activeElement === t && document.querySelectorAll('textarea').length === 1;
      })()
      """) { [self] result, error in
      guard error == nil, result as? Bool == true, !web.configuration.websiteDataStore.isPersistent else {
        finish(false); return
      }
      web.takeSnapshot(with: nil) { [self] image, error in
        guard error == nil, let tiff = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { finish(false); return }
        do { try png.write(to: output, options: .atomic); finish(true) }
        catch { finish(false) }
      }
    }
  }

  private func finish(_ success: Bool) {
    guard !finished else { return }
    finished = true
    print("WEB fixture pass=\(success) ephemeral=\(!web.configuration.websiteDataStore.isPersistent) navigationDenied=\(deniedNavigation) imeProof=false")
    if NSApp.isActive { NSApp.hide(nil) }
    window.close()
    exit(success ? 0 : 1)
  }
}
