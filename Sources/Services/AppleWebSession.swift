import AppKit
import WebKit

/// Apple handles passwords, two-factor authentication, agreements, and provider
/// selection in its own page. Cookies stay in WebKit; never extract or log them.
@MainActor
final class AppleWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = AppleWebSession()
    private var urlObservation: NSKeyValueObservation?
    let webView: WKWebView
    @Published private(set) var canUseSession = false
    @Published private(set) var pageError: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateSessionState() }
        }
        openApps()
    }

    func openApps() { webView.load(URLRequest(url: URL(string: "https://appstoreconnect.apple.com/apps")!)) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateSessionState()
        pageError = nil
    }

    private func updateSessionState() {
        canUseSession = webView.url?.host == "appstoreconnect.apple.com"
            && webView.url?.path.hasPrefix("/apps") == true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageError = error.localizedDescription
        canUseSession = false
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, Self.allows(url) else {
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
        else { decisionHandler(.allow) }
    }

    func ensureApp(_ record: AppStoreAppRecord) async throws -> String {
        let record = try record.validated()
        guard canUseSession, webView.url?.host == "appstoreconnect.apple.com" else {
            throw AppStoreConnectError.requestFailed(401, L10n.text("Sign in to Apple and select the correct team first."))
        }
        // Read before each explicit attempt. Never automatically retry a POST after
        // a lost response: the next attempt first checks whether Apple created it.
        let result = try await webView.callAsyncJavaScript("""
            const query = new URLSearchParams({'filter[bundleId]': bundleID, limit: '2'});
            const existing = await fetch('/iris/v1/apps?' + query, {credentials: 'same-origin'});
            const found = await existing.json();
            if (!existing.ok) return {status: existing.status, body: found};
            if (found.data && found.data.length) return {status: 200, body: {data: found.data[0]}};
            const response = await fetch('/iris/v1/apps', {
                method: 'POST', credentials: 'same-origin',
                headers: {'Content-Type': 'application/vnd.api+json', Accept: 'application/json'},
                body: JSON.stringify(payload)
            });
            return {status: response.status, body: await response.json()};
            """, arguments: ["bundleID": record.bundleID, "payload": try record.payload()],
            in: nil, contentWorld: .page)
        guard let result = result as? [String: Any], let status = result["status"] as? Int,
              let body = result["body"] as? [String: Any] else {
            throw AppStoreConnectError.invalidResponse
        }
        guard (200..<300).contains(status) else {
            let errors = body["errors"] as? [[String: Any]] ?? []
            let message = errors.compactMap { ($0["detail"] ?? $0["title"]) as? String }.joined(separator: "\n")
            throw AppStoreConnectError.requestFailed(status, message.isEmpty
                ? L10n.text("Apple could not create the app. Complete any required account setup in the Apple page, then try again.") : message)
        }
        guard let data = body["data"] as? [String: Any], let id = data["id"] as? String else {
            throw AppStoreConnectError.invalidResponse
        }
        return id
    }
}
