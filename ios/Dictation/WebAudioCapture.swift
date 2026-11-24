import UIKit
import WebKit

@MainActor protocol KeyboardAudioCapture: AnyObject {
    var onAudio: ((UUID, Data, Double) -> Void)? { get set }
    var onFailure: ((UUID, String) -> Void)? { get set }
    func start(id: UUID)
    func stop()
}

/// On-demand WebKit capture. The bundled page has no network access or credentials.
/// Technique: stephancill/ios-keyboard-dictation (MIT), see WebAudioCapture-NOTICE.txt.
@MainActor final class WebAudioCapture: NSObject, KeyboardAudioCapture, WKUIDelegate, WKNavigationDelegate {
    var onAudio: ((UUID, Data, Double) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    private weak var container: UIView?
    private var webView: WKWebView?
    private var ready = false
    private var activeID: UUID?
    private var heartbeat: Timer?
    private var startedAt = Date.distantPast
    private var receivedAudio = false
    private static let origin = "vvhisper-capture.invalid"

    func attach(to view: UIView) {
        container = view
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(CaptureMessageHandler(self), name: "capture")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.alpha = 0.01; webView.isUserInteractionEnabled = false; webView.accessibilityElementsHidden = true
        webView.uiDelegate = self; webView.navigationDelegate = self
        self.webView = webView
        view.addSubview(webView); view.sendSubviewToBack(webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://\(Self.origin)/"))
    }
    func start(id: UUID) {
        stop()
        guard container?.window != nil, webView != nil else { onFailure?(id, "Microphone unavailable. Reopen the keyboard and try again."); return }
        activeID = id; startedAt = Date(); receivedAudio = false
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pulse() }
        }
        heartbeat = timer; RunLoop.main.add(timer, forMode: .common)
        if ready { startPage(id) }
    }
    private func startPage(_ id: UUID) {
        // UUID is generated natively; no transcript, key or user-controlled JS interpolation.
        webView?.evaluateJavaScript("startCapture('\(id.uuidString)')") { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.fail(id, "Couldn’t start the microphone. Try again.") }
        }
    }
    private func pulse() {
        guard let id = activeID else { return }
        guard container?.window != nil else { fail(id, "Recording stopped because the keyboard closed."); return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= 120 else { fail(id, "Dictation reached its two-minute limit."); return }
        guard receivedAudio || elapsed < 10 else { fail(id, "Microphone did not start. Check microphone access in vvhisper Settings."); return }
        webView?.evaluateJavaScript("captureHeartbeat('\(id.uuidString)'); 0")
    }
    func stop() {
        let id = activeID; activeID = nil
        heartbeat?.invalidate(); heartbeat = nil
        if let id { webView?.evaluateJavaScript("stopCapture('\(id.uuidString)'); 0") }
    }
    func detach() {
        stop(); ready = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "capture")
        webView?.stopLoading(); webView?.removeFromSuperview(); webView = nil; container = nil
    }
    private func fail(_ id: UUID, _ message: String) {
        guard activeID == id else { return }
        stop(); onFailure?(id, message)
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            ready = true
            if let id = activeID { startPage(id) }
            return
        }
        guard let token = body["id"] as? String, let id = UUID(uuidString: token), activeID == id else { return }
        switch type {
        case "audio":
            guard let value = body["data"] as? String, value.utf8.count <= 32768,
                  let data = Data(base64Encoded: value), !data.isEmpty, data.count <= 16384, data.count.isMultiple(of: 2),
                  let rms = body["rms"] as? Double, rms.isFinite, (0...1).contains(rms) else { return }
            receivedAudio = true; onAudio?(id, data, rms)
        case "denied": fail(id, "Allow microphone access in Settings, then reopen vvhisper once.")
        case "failed": fail(id, "Microphone unavailable. Try again.")
        case "interrupted": fail(id, "Recording was interrupted. Try again.")
        default: break
        }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(webView === self.webView && activeID != nil && frame.isMainFrame &&
                        origin.protocol == "https" && origin.host == Self.origin && type == .microphone ? .grant : .deny)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Only the initial bundled document may load. Never navigate to external content.
        let url = action.request.url
        decisionHandler(action.navigationType == .other &&
                        (url?.absoluteString == "about:blank" || (url?.scheme == "https" && url?.host == Self.origin)) ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        if let id = activeID { fail(id, "Microphone stopped. Hold again to retry.") }
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://\(Self.origin)/"))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ready = false
        if let id = activeID { fail(id, "Couldn’t prepare the microphone. Reopen the keyboard.") }
    }
    isolated deinit { heartbeat?.invalidate() }

    static let page = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; media-src blob:"></head><body><script>
    const post = message => window.webkit.messageHandlers.capture.postMessage(message);
    let current = null;
    const encode = samples => {
      const bytes = new Uint8Array(samples.buffer, 0, samples.length * 2);
      let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
      return btoa(binary);
    };
    const cleanup = s => {
      s.stopping = true; clearInterval(s.watchdog);
      if (s.processor) { s.processor.onaudioprocess = null; try { s.processor.disconnect(); } catch (_) {} }
      try { s.source?.disconnect(); s.sink?.disconnect(); } catch (_) {}
      s.stream?.getTracks().forEach(t => t.stop());
      if (s.context && s.context.state !== 'closed') s.context.close().catch(() => {});
      if (current === s) {
        current = null;
        try { if (navigator.audioSession) { navigator.audioSession.onstatechange = null; navigator.audioSession.type = s.previousType; } } catch (_) {}
      }
    };
    window.stopCapture = id => { if (current?.id === id) cleanup(current); };
    window.captureHeartbeat = id => { if (current?.id === id) current.heartbeat = performance.now(); };
    window.startCapture = id => { capture(id); return 0; };
    async function capture(id) {
      if (current) cleanup(current);
      const s = { id, stopping: false, heartbeat: performance.now(), began: performance.now(), previousType: navigator.audioSession?.type ?? 'auto' };
      current = s;
      const valid = () => current === s && !s.stopping;
      const interrupted = () => { if (valid()) { cleanup(s); post({type:'interrupted', id}); } };
      // Watch from before the permission promise: suspension during startup also expires.
      s.watchdog = setInterval(() => { if (performance.now()-s.heartbeat > 3000 || performance.now()-s.began > 120000) interrupted(); }, 500);
      try {
        if (navigator.audioSession) navigator.audioSession.type = 'play-and-record';
        s.stream = await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:false,noiseSuppression:false,autoGainControl:false}});
        if (!valid()) { cleanup(s); return; }
        s.stream.getAudioTracks()[0].onended = interrupted;
        s.context = new AudioContext({latencyHint:'interactive'});
        await s.context.resume();
        if (!valid()) { cleanup(s); return; }
        s.processor = s.context.createScriptProcessor(1024,1,1);
        s.sink = s.context.createGain(); s.sink.gain.value = 0;
        s.processor.connect(s.sink); s.sink.connect(s.context.destination);
        s.source = s.context.createMediaStreamSource(s.stream); s.source.connect(s.processor);
        s.context.onstatechange = () => { if (s.context.state !== 'running') interrupted(); };
        if (navigator.audioSession) navigator.audioSession.onstatechange = () => { if (navigator.audioSession.state === 'interrupted') interrupted(); };
        const step = s.context.sampleRate / 16000;
        let position = 0, sum = 0, count = 0;
        s.processor.onaudioprocess = event => {
          if (!valid()) return;
          const input = event.inputBuffer.getChannelData(0);
          const output = new Int16Array(Math.ceil(input.length / step)+1);
          let written = 0, energy = 0;
          for (const sample of input) {
            const value = Number.isFinite(sample) ? Math.max(-1,Math.min(1,sample)) : 0;
            energy += value*value; sum += value; count++; position++;
            if (position >= step) { position -= step; output[written++] = Math.max(-1,Math.min(1,sum/count))*32767; sum=0;count=0; }
          }
          if (written) post({type:'audio',id,data:encode(output.subarray(0,written)),rms:Math.sqrt(energy/input.length)});
        };
      } catch (e) {
        if (valid()) { cleanup(s); post({type:e.name === 'NotAllowedError' ? 'denied':'failed',id}); }
        else cleanup(s);
      }
    }
    window.addEventListener('pagehide', () => { if (current) cleanup(current); });
    document.addEventListener('visibilitychange', () => { if (document.hidden && current) cleanup(current); });
    post({type:'ready'});
    </script></body></html>
    """#
}
private final class CaptureMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebAudioCapture?
    init(_ owner: WebAudioCapture) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { owner?.receive(message) }
    }
}
