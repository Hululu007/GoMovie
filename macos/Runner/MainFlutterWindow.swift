import CFNetwork
import Carbon
import Cocoa
import FlutterMacOS
import MediaPlayer
import WebKit

#if arch(x86_64)
private func useSkiaRendering() {
  guard let method = class_getInstanceMethod(
    FlutterDartProject.self, NSSelectorFromString("enableImpeller")) else { return }
  let disabled: @convention(block) (AnyObject) -> ObjCBool = { _ in false }
  method_setImplementation(method, imp_implementationWithBlock(disabled))
}
#endif

private let bossKeyCodes: [String: Int] = [
  "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E,
  "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J,
  "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O,
  "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
  "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y,
  "Z": kVK_ANSI_Z,
  "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
  "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
  "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6,
  "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
]

private var bossKeyRef: EventHotKeyRef?
private var bossKeyHandler: EventHandlerRef?
private var deviceChannel: FlutterMethodChannel?
private var mediaControls: MediaControls?

private func toggleHidden() {
  if NSApp.isHidden {
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
  } else {
    deviceChannel?.invokeMethod("bossKeyHidden", arguments: nil)
    NSApp.hide(nil)
  }
}

private func setBossKey(_ args: [String: Any]?) -> Bool {
  if let ref = bossKeyRef {
    UnregisterEventHotKey(ref)
    bossKeyRef = nil
  }
  guard let args else { return true }
  guard let key = args["key"] as? String, let code = bossKeyCodes[key] else { return false }
  if bossKeyHandler == nil {
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      toggleHidden()
      return noErr
    }, 1, &type, nil, &bossKeyHandler)
  }
  var modifiers: UInt32 = 0
  if args["ctrl"] as? Bool == true { modifiers |= UInt32(controlKey) }
  if args["alt"] as? Bool == true { modifiers |= UInt32(optionKey) }
  if args["shift"] as? Bool == true { modifiers |= UInt32(shiftKey) }
  if args["meta"] as? Bool == true { modifiers |= UInt32(cmdKey) }
  let id = EventHotKeyID(signature: OSType(0x444A424B), id: 1)
  return RegisterEventHotKey(
    UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &bossKeyRef) == noErr
}

class MainFlutterWindow: NSWindow {
  private var webViewBridge: WebViewBridge?

  override func awakeFromNib() {
    #if arch(x86_64)
    useSkiaRendering()
    #endif
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    mediaControls = MediaControls(messenger: flutterViewController.engine.binaryMessenger)
    webViewBridge = WebViewBridge(window: self, messenger: flutterViewController.engine.binaryMessenger)
    let channel = FlutterMethodChannel(
      name: "gomovie/device", binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "windowFrame" {
        guard let window = self, !window.styleMask.contains(.fullScreen),
              !window.isZoomed, !window.isMiniaturized else {
          result(nil)
          return
        }
        let frame = window.frame
        result(["left": frame.origin.x, "top": frame.origin.y,
                "width": frame.size.width, "height": frame.size.height])
        return
      }
      if call.method == "setWindowFrame" {
        guard let window = self, let args = call.arguments as? [String: Any],
              let left = (args["left"] as? NSNumber)?.doubleValue,
              let top = (args["top"] as? NSNumber)?.doubleValue,
              let width = (args["width"] as? NSNumber)?.doubleValue,
              let height = (args["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
          result(FlutterError(code: "bad_args",
                              message: "left, top, width and height are required", details: nil))
          return
        }
        let frame = NSRect(x: left, y: top, width: width, height: height)
        let title = NSRect(x: left, y: top + height - min(height, 40), width: width,
                           height: min(height, 40))
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(title) }) {
          window.setFrame(frame, display: true)
        }
        result(nil)
        return
      }
      if call.method == "setBossKey" {
        result(setBossKey(call.arguments as? [String: Any]))
        return
      }
      guard call.method == "systemProxy" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
      func address(_ prefix: String) -> String {
        guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
              let host = settings["\(prefix)Proxy"] as? String,
              let port = settings["\(prefix)Port"] as? NSNumber,
              !host.isEmpty, port.intValue > 0 else { return "" }
        let name = host.contains(":") ? "[\(host)]" : host
        return "http://\(name):\(port.intValue)"
      }
      let http = address("HTTP")
      let https = address("HTTPS")
      result(["http": http, "https": https.isEmpty ? http : https,
              "bypass": settings["ExceptionsList"] as? [String] ?? [],
              "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
    }

    super.awakeFromNib()
  }
}

final class MediaControls {
  private let channel: FlutterMethodChannel
  private var targets: [(MPRemoteCommand, Any)] = []
  private var artworkPath = ""
  private var artwork: MPMediaItemArtwork?
  private var playing = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gomovie/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "update":
        self?.update(call.arguments as? [String: Any] ?? [:])
      case "clear":
        self?.clear()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
  }

  private func send(_ command: String, positionMs: Double? = nil) {
    var arguments: [String: Any] = ["command": command]
    if let positionMs { arguments["positionMs"] = positionMs }
    channel.invokeMethod("command", arguments: arguments)
  }

  private func bind(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> Void) {
    let token = command.addTarget { event in
      handler(event)
      return .success
    }
    targets.append((command, token))
  }

  private func update(_ args: [String: Any]) {
    let commands = MPRemoteCommandCenter.shared()
    if targets.isEmpty {
      bind(commands.playCommand) { [weak self] _ in self?.send("play") }
      bind(commands.pauseCommand) { [weak self] _ in self?.send("pause") }
      bind(commands.togglePlayPauseCommand) { [weak self] _ in self?.send("toggle") }
      bind(commands.nextTrackCommand) { [weak self] _ in self?.send("next") }
      bind(commands.previousTrackCommand) { [weak self] _ in self?.send("previous") }
      bind(commands.changePlaybackPositionCommand) { [weak self] event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
        self?.send("seek", positionMs: event.positionTime * 1000)
      }
    }
    playing = args["playing"] as? Bool ?? false
    commands.previousTrackCommand.isEnabled = args["hasPrevious"] as? Bool ?? false
    commands.nextTrackCommand.isEnabled = args["hasNext"] as? Bool ?? false
    let path = args["artwork"] as? String ?? ""
    if path != artworkPath {
      artworkPath = path
      artwork = path.isEmpty ? nil : NSImage(contentsOfFile: path).map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    let duration = ((args["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "",
      MPNowPlayingInfoPropertyElapsedPlaybackTime: ((args["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = playing ? .playing : .paused
  }

  private func clear() {
    for (command, token) in targets { command.removeTarget(token) }
    targets.removeAll()
    playing = false
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }
}

private final class WebViewBridge: NSObject, WKNavigationDelegate {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private var hiddenWebView: WKWebView?
  private var fetchQueue: [(url: String, result: FlutterResult)] = []
  private var fetchBusy = false
  private var activeFetch: (url: String, result: FlutterResult)?
  private var fetchTimeout: DispatchWorkItem?
  private var activeChallenge: ChallengeWindowController?

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    self.channel = FlutterMethodChannel(name: "gomovie/webview", binaryMessenger: messenger)
    super.init()
    self.channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let urlString = (args?["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !urlString.isEmpty, let url = URL(string: urlString) else {
      result(FlutterError(code: "invalid_args", message: "缺少有效地址", details: nil))
      return
    }
    switch call.method {
    case "openChallenge":
      DispatchQueue.main.async { self.presentChallenge(url: url, result: result) }
    case "fetchHtml":
      DispatchQueue.main.async {
        self.fetchQueue.append((url.absoluteString, result))
        self.pumpFetchQueue()
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentChallenge(url: URL, result: @escaping FlutterResult) {
    if activeChallenge != nil {
      result(["ok": false])
      return
    }
    let controller = ChallengeWindowController(url: url) { [weak self] ok, cookies, userAgent in
      self?.activeChallenge = nil
      if ok {
        result(["ok": true, "cookies": cookies, "userAgent": userAgent])
      } else {
        result(["ok": false])
      }
    }
    activeChallenge = controller
    controller.present(from: window)
  }

  private func ensureHiddenWebView() -> WKWebView {
    if let existing = hiddenWebView { return existing }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
    wv.navigationDelegate = self
    hiddenWebView = wv
    return wv
  }

  private func pumpFetchQueue() {
    guard !fetchBusy, !fetchQueue.isEmpty else { return }
    fetchBusy = true
    let item = fetchQueue.removeFirst()
    activeFetch = item
    guard let url = URL(string: item.url) else {
      activeFetch = nil
      fetchBusy = false
      item.result(FlutterError(code: "invalid_args", message: "无效地址", details: nil))
      pumpFetchQueue()
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self, let pending = self.activeFetch else { return }
      self.activeFetch = nil
      self.hiddenWebView?.stopLoading()
      pending.result(FlutterError(code: "timeout", message: "WebView 请求超时", details: nil))
      self.fetchBusy = false
      self.pumpFetchQueue()
    }
    fetchTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 22, execute: work)
    ensureHiddenWebView().load(URLRequest(url: url))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard activeFetch != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, let pending = self.activeFetch else { return }
      webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { value, _ in
        guard let current = self.activeFetch, current.url == pending.url else { return }
        self.activeFetch = nil
        self.fetchTimeout?.cancel()
        self.fetchTimeout = nil
        let html = value as? String ?? ""
        current.result(["ok": true, "html": html, "url": webView.url?.absoluteString ?? pending.url])
        self.fetchBusy = false
        self.pumpFetchQueue()
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishWithError(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finishWithError(error)
  }

  private func finishWithError(_ error: Error) {
    guard let pending = activeFetch else { return }
    activeFetch = nil
    fetchTimeout?.cancel()
    fetchTimeout = nil
    pending.result(FlutterError(code: "load_error", message: error.localizedDescription, details: nil))
    fetchBusy = false
    pumpFetchQueue()
  }
}

private final class ChallengeWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
  private let targetURL: URL
  private let completion: (Bool, String, String) -> Void
  private weak var parentWindow: NSWindow?
  private let sheetWindow: NSWindow
  private let titleLabel: NSTextField
  private let webView: WKWebView
  private var finished = false

  init(url: URL, completion: @escaping (Bool, String, String) -> Void) {
    self.targetURL = url
    self.completion = completion

    let rect = NSRect(x: 0, y: 0, width: 900, height: 640)
    self.sheetWindow = NSWindow(
      contentRect: rect,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    self.sheetWindow.title = "人机验证"
    self.sheetWindow.isReleasedWhenClosed = false

    self.titleLabel = NSTextField(labelWithString: "完成验证后点「完成」")
    self.titleLabel.alignment = .center
    self.titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    self.titleLabel.textColor = .white

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    self.webView = WKWebView(frame: .zero, configuration: config)

    super.init()
    self.sheetWindow.delegate = self
    self.webView.navigationDelegate = self
    setupLayout()
  }

  private func setupLayout() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).cgColor

    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1).cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
    cancelButton.bezelStyle = .rounded
    cancelButton.keyEquivalent = "\u{1b}"
    cancelButton.translatesAutoresizingMaskIntoConstraints = false

    let doneButton = NSButton(title: "完成", target: self, action: #selector(doneTapped))
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"
    doneButton.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    webView.translatesAutoresizingMaskIntoConstraints = false

    toolbar.addSubview(cancelButton)
    toolbar.addSubview(titleLabel)
    toolbar.addSubview(doneButton)
    root.addSubview(toolbar)
    root.addSubview(webView)
    sheetWindow.contentView = root

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 48),

      cancelButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
      cancelButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

      doneButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
      doneButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

      titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cancelButton.trailingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor, constant: -12),
      titleLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),

      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  func present(from parent: NSWindow?) {
    self.parentWindow = parent
    webView.load(URLRequest(url: targetURL))
    if let parent {
      parent.beginSheet(sheetWindow) { _ in }
    } else {
      sheetWindow.center()
      sheetWindow.makeKeyAndOrderFront(nil)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      let hasClearance = cookies.contains {
        $0.name == "cf_clearance" &&
          (host.isEmpty || $0.domain.contains(host) || host.contains($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))))
      }
      let pageTitle = (webView.title ?? "").lowercased()
      if hasClearance && !pageTitle.contains("just a moment") {
        DispatchQueue.main.async {
          self?.titleLabel.stringValue = "验证已通过，可点「完成」"
          self?.titleLabel.textColor = NSColor(red: 1.0, green: 0.62, blue: 0.17, alpha: 1)
        }
      }
    }
  }

  @objc private func cancelTapped() {
    finish(ok: false)
  }

  @objc private func doneTapped() {
    finish(ok: true)
  }

  func windowWillClose(_ notification: Notification) {
    finish(ok: false)
  }

  private func closeSheet() {
    if let parent = parentWindow, sheetWindow.sheetParent != nil {
      parent.endSheet(sheetWindow)
    }
    sheetWindow.orderOut(nil)
  }

  private func finish(ok: Bool) {
    guard !finished else { return }
    finished = true
    if !ok {
      closeSheet()
      completion(false, "", "")
      return
    }
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let matched = cookies.filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty || host == domain || host.hasSuffix("." + domain)
      }
      let cookieHeader = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      DispatchQueue.main.async {
        self.webView.evaluateJavaScript("navigator.userAgent") { uaVal, _ in
          let ua = uaVal as? String ?? ""
          DispatchQueue.main.async {
            self.closeSheet()
            self.completion(true, cookieHeader, ua)
          }
        }
      }
    }
  }
}
