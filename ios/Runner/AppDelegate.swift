import Flutter
import UIKit
import WebKit
import GoMovieCore
import CFNetwork
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var originalBrightness: CGFloat?
  private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
  private var mediaControls: MediaControls?
  private var webViewBridge: WebViewBridge?

  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private var screen: UIScreen? { keyWindow?.screen }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaControls") {
      mediaControls = MediaControls(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WebViewBridge") {
      webViewBridge = WebViewBridge(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "gomovie/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "battery" {
          let device = UIDevice.current
          device.isBatteryMonitoringEnabled = true
          guard device.batteryLevel >= 0 else {
            result(nil)
            return
          }
          result(["level": Int((device.batteryLevel * 100).rounded()),
                  "charging": device.batteryState == .charging || device.batteryState == .full])
          return
        }
        let arguments = call.arguments as? [String: Any]
        switch call.method {
        case "getBrightness":
          result(self.screen.map { Double($0.brightness) })
          return
        case "setBrightness":
          guard let screen = self.screen, let value = arguments?["brightness"] as? Double else {
            result(nil)
            return
          }
          if self.originalBrightness == nil { self.originalBrightness = screen.brightness }
          screen.brightness = CGFloat(min(max(value, 0.01), 1))
          result(true)
          return
        case "resetBrightness":
          if let original = self.originalBrightness { self.screen?.brightness = original }
          self.originalBrightness = nil
          result(true)
          return
        case "volume":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
          return
        case "setVolume":
          if let value = arguments?["volume"] as? Double {
            if self.volumeView.superview == nil { self.keyWindow?.addSubview(self.volumeView) }
            let slider = self.volumeView.subviews.first { $0 is UISlider } as? UISlider
            slider?.value = Float(min(max(value, 0), 1))
          }
          result(nil)
          return
        default:
          break
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
    }
  }
}

final class MediaControls {
  private let channel: FlutterMethodChannel
  private var targets: [(MPRemoteCommand, Any)] = []
  private var observers: [NSObjectProtocol] = []
  private var artworkPath = ""
  private var artwork: MPMediaItemArtwork?
  private var playing = false
  private var resumeAfterInterruption = false

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
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, !self.targets.isEmpty,
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if type == .began {
        self.resumeAfterInterruption = self.playing
        if self.playing { self.send("pause") }
        return
      }
      let options = AVAudioSession.InterruptionOptions(
        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      if self.resumeAfterInterruption && options.contains(.shouldResume) { self.send("play") }
      self.resumeAfterInterruption = false
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self, self.playing,
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self.send("pause")
    })
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
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playback, mode: .moviePlayback)
      try? session.setActive(true)
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
      artwork = path.isEmpty ? nil : UIImage(contentsOfFile: path).map { image in
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
  }

  private func clear() {
    for (command, token) in targets { command.removeTarget(token) }
    targets.removeAll()
    playing = false
    resumeAfterInterruption = false
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
  }
}

private final class WebViewBridge: NSObject, WKNavigationDelegate {
  private let channel: FlutterMethodChannel
  private var hiddenWebView: WKWebView?
  private var fetchQueue: [(url: String, result: FlutterResult)] = []
  private var fetchBusy = false
  private var activeFetch: (url: String, result: FlutterResult)?
  private var fetchTimeout: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
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

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private func presentChallenge(url: URL, result: @escaping FlutterResult) {
    guard let presenter = topViewController() else {
      result(["ok": false])
      return
    }
    let controller = ChallengeViewController(url: url) { ok, cookies, userAgent in
      if ok {
        result(["ok": true, "cookies": cookies, "userAgent": userAgent])
      } else {
        result(["ok": false])
      }
    }
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .pageSheet
    presenter.present(nav, animated: true)
  }

  private func ensureHiddenWebView() -> WKWebView {
    if let existing = hiddenWebView { return existing }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
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

private final class ChallengeViewController: UIViewController, WKNavigationDelegate {
  private let targetURL: URL
  private let completion: (Bool, String, String) -> Void
  private var webView: WKWebView!
  private var finished = false

  init(url: URL, completion: @escaping (Bool, String, String) -> Void) {
    self.targetURL = url
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "完成验证后点「完成」"
    view.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))

    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    webView = WKWebView(frame: view.bounds, configuration: config)
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.navigationDelegate = self
    view.addSubview(webView)
    webView.load(URLRequest(url: targetURL))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      let hasClearance = cookies.contains { $0.name == "cf_clearance" && (host.isEmpty || $0.domain.contains(host) || host.contains($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))) }
      let pageTitle = (webView.title ?? "").lowercased()
      if hasClearance && !pageTitle.contains("just a moment") {
        DispatchQueue.main.async {
          self?.title = "验证已通过，可点「完成」"
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

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed && !finished {
      finish(ok: false)
    }
  }

  private func finish(ok: Bool) {
    guard !finished else { return }
    finished = true
    if !ok {
      dismiss(animated: true) { self.completion(false, "", "") }
      return
    }
    let host = (webView.url ?? targetURL).host ?? ""
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let matched = cookies.filter { cookie in
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty || host == domain || host.hasSuffix("." + domain)
      }
      let cookieHeader = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      self.webView.evaluateJavaScript("navigator.userAgent") { uaVal, _ in
        let ua = uaVal as? String ?? ""
        DispatchQueue.main.async {
          self.dismiss(animated: true) { self.completion(true, cookieHeader, ua) }
        }
      }
    }
  }
}
