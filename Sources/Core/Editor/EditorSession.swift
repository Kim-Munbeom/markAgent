import AppKit
import WebKit

/// 문서별 편집 순서와 WebKit 수명을 소유한다. 저장 baseline은 문서에 남는다.
@MainActor
final class EditorSession: NSObject, WKNavigationDelegate {
    let id = UUID().uuidString
    private(set) var epoch = 0
    private(set) var sequence = -1
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var webView: WKWebView?
    weak var document: MarkdownDocument?
    var onSelection: ((NSRange) -> Void)?
    var onReady: (() -> Void)?
    var onToggleViewMode: (() -> Void)?
    var onFormat: ((MarkdownEditAction) -> Void)?
    private var ready = false
    private var failure: Error?
    private var assetURL: URL?
    private var initialConfiguration: [String: Any] = [:]
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var loadDeadline: Task<Void, Never>?
    private var imageTasks: [Int: Task<Void, Never>] = [:]

    init(document: MarkdownDocument) {
        self.document = document
    }

    func mount(in container: NSView, assetURL: URL?, configuration: [String: Any]) {
        guard webView == nil else { return }
        self.assetURL = assetURL
        initialConfiguration = configuration
        ready = false
        failure = nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(EditorMessageProxy(session: self), name: "markAgentEditor")
        let view = EditorWKWebView(frame: container.bounds, configuration: config)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        webView = view
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        guard let assetURL else {
            fail(EditorSessionError.assetMissing)
            return
        }
        loadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.fail(EditorSessionError.timeout)
        }
        view.loadFileURL(assetURL, allowingReadAccessTo: assetURL.deletingLastPathComponent())
    }

    func waitUntilReady() async throws {
        if let failure { throw failure }
        if ready { return }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func flush() async throws {
        try await waitUntilReady()
        try await request(["kind": "flush"])
    }

    func apply(text: String, selection: NSRange, preservingUndo: Bool) async throws {
        let location = min(selection.location, text.utf16.count)
        let selection = NSRange(location: location, length: min(selection.length, text.utf16.count - location))
        if !preservingUndo { epoch += 1 }
        try await request([
            "kind": "apply", "operation": preservingUndo ? "format" : "replace",
            "text": text, "selection": Self.wireRange(selection)
        ])
        self.selection = selection
        onSelection?(selection)
    }

    func setHostSelection(_ range: NSRange) {
        selection = range
    }

    func configure(_ configuration: [String: Any]) async throws {
        try await waitUntilReady()
        var command = configuration
        command["kind"] = "apply"
        command["operation"] = "configure"
        try await request(command)
    }

    func resume() async throws {
        try await send(["kind": "resume"])
    }

    func dispose() async {
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        if ready { try? await send(["kind": "dispose"]) }
        loadDeadline?.cancel()
        fail(EditorSessionError.disposed, report: false)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "markAgentEditor")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        onSelection = nil
        onReady = nil
        onToggleViewMode = nil
        onFormat = nil
        ready = false
    }

    private func request(_ command: [String: Any]) async throws {
        if let failure { throw failure }
        let requestID = UUID().uuidString
        var command = command
        command["requestID"] = requestID
        try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            deadlines[requestID] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.fail(EditorSessionError.timeout)
            }
            Task { [weak self] in
                guard let self else { return }
                do { try await send(command) } catch { fail(error) }
            }
        }
    }

    private func send(_ command: [String: Any]) async throws {
        guard let webView else { throw EditorSessionError.disposed }
        var envelope = command
        envelope["version"] = 1
        envelope["sessionID"] = id
        envelope["epoch"] = epoch
        _ = try await webView.callAsyncJavaScript(
            "await window.markAgentEditor(command)",
            arguments: ["command": envelope], in: nil, contentWorld: .page
        )
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView else { return }
        receiveEnvelope(message.body)
    }

    // 실제 메시지와 decoder 회귀가 같은 승인 경로를 사용한다.
    func receiveEnvelope(_ body: Any) {
        guard failure == nil, let body = body as? [String: Any],
              integer(body["version"]) == 1,
              body["sessionID"] as? String == id,
              integer(body["epoch"]) == epoch,
              let seq = integer(body["seq"]), seq > sequence,
              let type = body["type"] as? String,
              ["ready", "state", "snapshot", "applied", "modeToggle", "format", "image", "openLink"].contains(type)
        else { return }
        if type == "image" {
            guard let imageID = integer(body["imageID"]),
                  let source = body["source"] as? String,
                  imageTasks[imageID] == nil else { return }
            let path = URL(string: source).flatMap { $0.isFileURL ? $0.path : nil } ?? source
            let reference = MarkdownImageReference.resolve(
                source: path,
                baseURL: document?.fileURL?.deletingLastPathComponent()
            )
            guard let url = reference.resolvedURL, url.isFileURL else { return }
            sequence = seq
            let imageEpoch = epoch
            imageTasks[imageID] = Task { [weak self] in
                let data = await Task.detached(priority: .utility) {
                    MarkdownImageThumbnailLoader.thumbnailData(for: url, maxPixelSize: 1440)
                }.value
                guard !Task.isCancelled, let self else { return }
                defer { imageTasks.removeValue(forKey: imageID) }
                guard failure == nil, epoch == imageEpoch else { return }
                let src = data.map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
                do {
                    try await send(["kind": "image", "imageID": imageID, "src": src, "url": url.absoluteString])
                } catch {
                    NSLog("Markdown 이미지 전달 실패: %@", error.localizedDescription)
                }
            }
            return
        }
        if type == "openLink" {
            guard ready, let raw = body["url"] as? String, let url = URL(string: raw),
                  ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
            sequence = seq
            NSWorkspace.shared.open(url)
            return
        }
        if type == "modeToggle" {
            guard ready else { return }
            sequence = seq
            onToggleViewMode?()
            return
        }
        if type == "format" {
            guard ready, let name = body["action"] as? String else { return }
            let action: MarkdownEditAction
            switch name {
            case "heading": action = .heading
            case "bold": action = .bold
            case "italic": action = .italic
            case "link": action = .link
            case "unorderedList": action = .unorderedList
            case "orderedList": action = .orderedList
            case "checklist": action = .checklist
            case "quote": action = .quote
            case "inlineCode": action = .inlineCode
            default: return
            }
            sequence = seq
            onFormat?(action)
            return
        }
        if type == "applied" {
            guard let request = body["requestID"] as? String, pending[request] != nil else { return }
        }
        if type == "state" || type == "snapshot" {
            guard let text = body["text"] as? String,
                  let range = body["selection"] as? [String: Any],
                  let location = integer(range["location"]), let length = integer(range["length"]),
                  location >= 0, length >= 0, location <= text.utf16.count,
                  length <= text.utf16.count - location else { return }
            if type == "snapshot" {
                guard let request = body["requestID"] as? String, pending[request] != nil else { return }
            }
            selection = NSRange(location: location, length: length)
            document?.editableContent = text
            onSelection?(selection)
        }
        sequence = seq
        if type == "ready" {
            ready = true
            loadDeadline?.cancel()
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            onReady?()
        }
        if type == "snapshot" || type == "applied",
           let requestID = body["requestID"] as? String {
            deadlines.removeValue(forKey: requestID)?.cancel()
            pending.removeValue(forKey: requestID)?.resume()
        }
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return nil }
        return number.intValue
    }

    private func fail(_ error: Error, report: Bool = true) {
        failure = error
        loadDeadline?.cancel()
        deadlines.values.forEach { $0.cancel() }
        deadlines.removeAll()
        let requests = pending.values
        pending.removeAll()
        requests.forEach { $0.resume(throwing: error) }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
        if report {
            document?.editorFailure = error
            document?.errorMessage = error.localizedDescription
        }
    }

    static func wireRange(_ range: NSRange) -> [String: Int] {
        ["location": range.location, "length": range.length]
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        var configuration = initialConfiguration
        configuration["kind"] = "initialize"
        configuration["text"] = document?.editableContent ?? ""
        configuration["selection"] = Self.wireRange(selection)
        Task { [weak self] in
            guard let self else { return }
            do { try await send(configuration) } catch { fail(error) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == assetURL ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(EditorSessionError.terminated) }
}

final class EditorWKWebView: WKWebView {
    var onRelease: (@Sendable () -> Void)?
    deinit { onRelease?() }
}

@MainActor
private final class EditorMessageProxy: NSObject, WKScriptMessageHandler {
    weak var session: EditorSession?
    init(session: EditorSession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receive(message)
    }
}

enum EditorSessionError: LocalizedError {
    case assetMissing, timeout, disposed, terminated
    var errorDescription: String? {
        switch self {
        case .assetMissing: "편집기 자산을 찾을 수 없습니다."
        case .timeout: "편집기 응답 시간이 초과되어 작업을 취소했습니다."
        case .disposed: "편집기가 닫혔습니다."
        case .terminated: "편집기 프로세스가 종료되어 작업을 취소했습니다."
        }
    }
}
