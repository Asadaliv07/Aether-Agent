import Foundation
import WebKit
import AppKit

/// High-performance, native macOS browser automation engine backed by WebKit `WKWebView`.
///
/// Executes headless out-of-process web browsing, DOM inspection, element interactions,
/// semantic markdown extraction, and snapshot generation directly within macOS 14+.
@MainActor
public final class WebKitBrowserAutomationProvider: NSObject, BrowserAutomationProvider, Sendable {
    public static let shared = WebKitBrowserAutomationProvider()

    // Tab state record
    private final class TabEntry: NSObject, WKNavigationDelegate {
        let id: UUID
        let webView: WKWebView
        var title: String = ""
        var url: URL = URL(string: "about:blank")!
        var continuation: CheckedContinuation<Void, Error>?

        init(id: UUID, webView: WKWebView) {
            self.id = id
            self.webView = webView
            super.init()
            self.webView.navigationDelegate = self
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let title = webView.title { self.title = title }
            if let u = webView.url { self.url = u }
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private var tabs: [UUID: TabEntry] = [:]
    private var activeTabId: UUID?
    private var elementIdCounter: Int = 1

    public override init() {
        super.init()
    }

    // MARK: - Tab Management

    private func getOrCreateActiveTab() -> TabEntry {
        if let activeId = activeTabId, let entry = tabs[activeId] {
            return entry
        }
        return createTab()
    }

    private func createTab(initialURL: URL? = nil) -> TabEntry {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 AetherBrowser/1.0"

        let newId = UUID()
        let entry = TabEntry(id: newId, webView: webView)
        tabs[newId] = entry
        activeTabId = newId

        if let url = initialURL {
            let req = URLRequest(url: url, timeoutInterval: 20.0)
            webView.load(req)
        }
        return entry
    }

    // MARK: - BrowserAutomationProvider Protocol Implementation

    public func open(url: URL) async throws -> BrowserPageMetadata {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "about" else {
            throw BrowserAutomationError.invalidURL("Only http, https, and about schemes are permitted: \(url.absoluteString)")
        }

        let tab = getOrCreateActiveTab()
        tab.url = url

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tab.continuation = continuation
            let request = URLRequest(url: url, timeoutInterval: 25.0)
            tab.webView.load(request)
        }

        let title = tab.webView.title ?? ""
        tab.title = title
        let currentURL = tab.webView.url?.absoluteString ?? url.absoluteString

        let desc = try? await tab.webView.evaluateJavaScript(
            "document.querySelector('meta[name=\"description\"]')?.getAttribute('content') || ''"
        ) as? String

        return BrowserPageMetadata(
            title: title.isEmpty ? "Page" : title,
            url: currentURL,
            pageDescription: desc?.isEmpty == true ? nil : desc,
            statusCode: 200
        )
    }

    public func getPageContent(format: String = "markdown", maxLength: Int? = nil) async throws -> String {
        let tab = getOrCreateActiveTab()

        let script: String
        if format.lowercased() == "text" {
            script = "document.body ? document.body.innerText : ''"
        } else {
            // Semantic Markdown Extractor: Extracts structured text, headings, links, inputs, and buttons
            script = """
            (function() {
                function extractMarkdown(node) {
                    if (!node) return '';
                    let tag = node.tagName ? node.tagName.toLowerCase() : '';
                    if (['script', 'style', 'noscript', 'svg'].includes(tag)) return '';

                    // Check visibility
                    if (node.nodeType === 1) {
                        let style = window.getComputedStyle(node);
                        if (style && (style.display === 'none' || style.visibility === 'hidden')) return '';
                    }

                    if (node.nodeType === 3) {
                        return node.textContent.replace(/\\s+/g, ' ');
                    }

                    let childrenText = Array.from(node.childNodes).map(extractMarkdown).join('');
                    childrenText = childrenText.trim();

                    if (!childrenText && !['input', 'img', 'hr', 'button'].includes(tag)) return '';

                    switch(tag) {
                        case 'h1': return '\\n# ' + childrenText + '\\n\\n';
                        case 'h2': return '\\n## ' + childrenText + '\\n\\n';
                        case 'h3': return '\\n### ' + childrenText + '\\n\\n';
                        case 'h4':
                        case 'h5':
                        case 'h6': return '\\n#### ' + childrenText + '\\n\\n';
                        case 'p': return '\\n' + childrenText + '\\n\\n';
                        case 'li': return '\\n* ' + childrenText;
                        case 'a':
                            let href = node.getAttribute('href') || '';
                            return '[' + (childrenText || href) + '](' + href + ')';
                        case 'button':
                            return '[Button: ' + (childrenText || node.getAttribute('aria-label') || 'Submit') + ']';
                        case 'input':
                            let type = node.getAttribute('type') || 'text';
                            let name = node.getAttribute('name') || node.getAttribute('placeholder') || '';
                            let val = node.value || '';
                            return '[Input type=' + type + (name ? ' name=' + name : '') + (val ? ' value=\"' + val + '\"' : '') + ']';
                        case 'textarea':
                            return '[Textarea: ' + (node.value || '') + ']';
                        default:
                            return childrenText;
                    }
                }
                let body = document.body;
                if (!body) return '';
                let md = extractMarkdown(body).replace(/\\n{3,}/g, '\\n\\n').trim();
                return md || body.innerText || '';
            })()
            """
        }

        let rawResult = try await tab.webView.evaluateJavaScript(script)
        var resultText = (rawResult as? String) ?? ""

        if let max = maxLength, max > 0, resultText.count > max {
            resultText = String(resultText.prefix(max)) + "\n\n... [Content truncated at \(max) characters]"
        }
        return resultText
    }

    public func getPageMetadata() async throws -> BrowserPageMetadata {
        let tab = getOrCreateActiveTab()
        let title = tab.webView.title ?? ""
        let currentURL = tab.webView.url?.absoluteString ?? tab.url.absoluteString

        let desc = try? await tab.webView.evaluateJavaScript(
            "document.querySelector('meta[name=\"description\"]')?.getAttribute('content') || ''"
        ) as? String

        return BrowserPageMetadata(
            title: title.isEmpty ? "Page" : title,
            url: currentURL,
            pageDescription: desc?.isEmpty == true ? nil : desc,
            statusCode: 200
        )
    }

    public func findElement(query: String, by: String = "text") async throws -> [BrowserElementInfo] {
        let tab = getOrCreateActiveTab()

        let script = """
        (function(query, by) {
            let results = [];
            let nodes = [];

            if (by === 'css') {
                try {
                    nodes = Array.from(document.querySelectorAll(query));
                } catch(e) { nodes = []; }
            } else if (by === 'xpath') {
                try {
                    let iter = document.evaluate(query, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                    for (let i = 0; i < iter.snapshotLength; i++) {
                        nodes.push(iter.snapshotItem(i));
                    }
                } catch(e) { nodes = []; }
            } else if (by === 'label' || by === 'role') {
                let all = document.querySelectorAll('*');
                let q = query.toLowerCase();
                for (let el of all) {
                    let label = (el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || '').toLowerCase();
                    let role = (el.getAttribute('role') || el.tagName || '').toLowerCase();
                    if (label.includes(q) || role.includes(q)) {
                        nodes.push(el);
                    }
                }
            } else {
                // Default: text search
                let all = document.querySelectorAll('a, button, input, textarea, select, [role], p, h1, h2, h3, li, span, div');
                let q = query.toLowerCase();
                for (let el of all) {
                    let text = (el.innerText || el.textContent || '').trim().toLowerCase();
                    if (text.includes(q) && text.length < 500) {
                        nodes.push(el);
                    }
                }
            }

            // Deduplicate and synthesize IDs
            let count = 0;
            for (let el of nodes.slice(0, 25)) {
                count++;
                let aid = el.getAttribute('data-aether-id') || ('aether_el_' + count);
                el.setAttribute('data-aether-id', aid);

                let tag = el.tagName ? el.tagName.toLowerCase() : '';
                let text = (el.innerText || el.textContent || el.value || '').trim().replace(/\\s+/g, ' ').substring(0, 100);
                let role = el.getAttribute('role') || tag;
                let isClick = (tag === 'a' || tag === 'button' || el.getAttribute('role') === 'button' || el.onclick != null);
                let isInput = (tag === 'input' || tag === 'textarea' || tag === 'select');

                results.push({
                    id: aid,
                    tagName: tag,
                    text: text,
                    role: role,
                    isClickable: isClick,
                    isInput: isInput
                });
            }
            return JSON.stringify(results);
        })('\(escapeJS(query))', '\(escapeJS(by))')
        """

        let jsonString = try await tab.webView.evaluateJavaScript(script) as? String ?? "[]"
        guard let data = jsonString.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var elements: [BrowserElementInfo] = []
        for dict in jsonArray {
            let id = dict["id"] as? String ?? UUID().uuidString
            let tag = dict["tagName"] as? String ?? ""
            let text = dict["text"] as? String ?? ""
            let role = dict["role"] as? String
            let isClick = dict["isClickable"] as? Bool ?? false
            let isInput = dict["isInput"] as? Bool ?? false
            elements.append(BrowserElementInfo(
                id: id,
                tagName: tag,
                text: text,
                role: role,
                isClickable: isClick,
                isInput: isInput
            ))
        }
        return elements
    }

    public func click(elementId: String) async throws -> String {
        let tab = getOrCreateActiveTab()

        let script = """
        (function(targetId) {
            let el = document.querySelector('[data-aether-id=\"' + targetId + '\"]') ||
                     document.getElementById(targetId) ||
                     document.querySelector(targetId);

            if (!el) {
                // Fuzzy text fallback
                let all = document.querySelectorAll('button, a, input[type=\"submit\"], [role=\"button\"]');
                for (let candidate of all) {
                    if ((candidate.innerText || candidate.textContent || '').trim().toLowerCase() === targetId.toLowerCase()) {
                        el = candidate;
                        break;
                    }
                }
            }

            if (!el) return { success: false, reason: 'Element not found' };

            el.scrollIntoView({ behavior: 'instant', block: 'center' });
            el.focus();
            el.click();
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));

            return {
                success: true,
                tagName: el.tagName,
                text: (el.innerText || el.textContent || '').substring(0, 60),
                href: el.getAttribute('href') || null
            };
        })('\(escapeJS(elementId))')
        """

        guard let dict = try await tab.webView.evaluateJavaScript(script) as? [String: Any] else {
            throw BrowserAutomationError.actionFailed("Failed to execute click script.")
        }

        guard let success = dict["success"] as? Bool, success else {
            let reason = dict["reason"] as? String ?? "Element '\(elementId)' could not be located on the page."
            throw BrowserAutomationError.elementNotFound(reason)
        }

        let tag = dict["tagName"] as? String ?? "element"
        let text = dict["text"] as? String ?? ""
        return "Successfully clicked <\(tag)> \(text.isEmpty ? "" : "'\(text)'") (id: \(elementId))."
    }

    public func typeText(text: String, elementId: String? = nil) async throws -> String {
        let tab = getOrCreateActiveTab()

        let script = """
        (function(text, targetId) {
            let el = null;
            if (targetId) {
                el = document.querySelector('[data-aether-id=\"' + targetId + '\"]') ||
                     document.getElementById(targetId) ||
                     document.querySelector(targetId);
            }
            if (!el) {
                el = document.activeElement;
            }
            if (!el || el === document.body) {
                el = document.querySelector('input:not([type=\"hidden\"]), textarea');
            }

            if (!el) return { success: false, reason: 'No editable element focused or located' };

            el.focus();
            el.value = text;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));

            return { success: true, tagName: el.tagName, name: el.name || el.id || '' };
        })('\(escapeJS(text))', \(elementId != nil ? "'\(escapeJS(elementId!))'" : "null"))
        """

        guard let dict = try await tab.webView.evaluateJavaScript(script) as? [String: Any],
              let success = dict["success"] as? Bool, success else {
            throw BrowserAutomationError.actionFailed("Could not enter text: element not found or not editable.")
        }

        return "Successfully entered '\(text)' into field."
    }

    public func fillForm(fields: [String: String]) async throws -> String {
        let tab = getOrCreateActiveTab()

        guard let jsonData = try? JSONSerialization.data(withJSONObject: fields),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            throw BrowserAutomationError.actionFailed("Invalid form fields JSON.")
        }

        let script = """
        (function(fieldDict) {
            let filledCount = 0;
            let report = [];

            for (let [key, val] of Object.entries(fieldDict)) {
                let el = document.querySelector('[name=\"' + key + '\"]') ||
                         document.getElementById(key) ||
                         document.querySelector('[placeholder*=\"' + key + '\" i]') ||
                         document.querySelector('[data-aether-id=\"' + key + '\"]');

                if (el) {
                    el.focus();
                    el.value = val;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    filledCount++;
                    report.push(key + ' -> filled');
                } else {
                    report.push(key + ' -> not found');
                }
            }
            return { filledCount: filledCount, report: report };
        })(\(jsonStr))
        """

        guard let dict = try await tab.webView.evaluateJavaScript(script) as? [String: Any],
              let count = dict["filledCount"] as? Int,
              let report = dict["report"] as? [String] else {
            throw BrowserAutomationError.actionFailed("Failed to execute form-filling script.")
        }

        return "Filled \(count) form fields: \(report.joined(separator: ", "))"
    }

    public func scroll(direction: BrowserScrollDirection, amount: Int? = nil) async throws -> String {
        let tab = getOrCreateActiveTab()
        let amt = amount ?? 500

        let script: String
        switch direction {
        case .up:
            script = "window.scrollBy({ top: -\(amt), behavior: 'instant' });"
        case .down:
            script = "window.scrollBy({ top: \(amt), behavior: 'instant' });"
        case .top:
            script = "window.scrollTo({ top: 0, behavior: 'instant' });"
        case .bottom:
            script = "window.scrollTo({ top: document.body.scrollHeight, behavior: 'instant' });"
        }

        _ = try await tab.webView.evaluateJavaScript(script)
        return "Scrolled \(direction.rawValue) by \(amt)px."
    }

    public func goBack() async throws -> BrowserPageMetadata {
        let tab = getOrCreateActiveTab()
        guard tab.webView.canGoBack else {
            return try await getPageMetadata()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tab.continuation = continuation
            tab.webView.goBack()
        }
        return try await getPageMetadata()
    }

    public func goForward() async throws -> BrowserPageMetadata {
        let tab = getOrCreateActiveTab()
        guard tab.webView.canGoForward else {
            return try await getPageMetadata()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tab.continuation = continuation
            tab.webView.goForward()
        }
        return try await getPageMetadata()
    }

    public func refresh() async throws -> BrowserPageMetadata {
        let tab = getOrCreateActiveTab()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tab.continuation = continuation
            tab.webView.reload()
        }
        return try await getPageMetadata()
    }

    public func takeScreenshot(savePath: String? = nil) async throws -> String {
        let tab = getOrCreateActiveTab()

        let image = try await tab.webView.takeSnapshot(configuration: nil)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserAutomationError.actionFailed("Failed to encode page snapshot.")
        }

        if let path = savePath, !path.isEmpty {
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try pngData.write(to: fileURL)
            return "Saved page screenshot (\(Int(image.size.width))x\(Int(image.size.height))) to '\(fileURL.path)'."
        } else {
            let base64 = pngData.base64EncodedString()
            return "Captured page snapshot (\(Int(image.size.width))x\(Int(image.size.height)), \(pngData.count) bytes, base64 length: \(base64.count))."
        }
    }

    public func listTabs() async throws -> [BrowserTabInfo] {
        tabs.values.map { entry in
            BrowserTabInfo(
                id: entry.id,
                title: entry.title.isEmpty ? "Tab" : entry.title,
                url: entry.url.absoluteString,
                isActive: (entry.id == activeTabId)
            )
        }
    }

    public func closeTab(tabId: UUID? = nil) async throws -> String {
        let targetId = tabId ?? activeTabId
        guard let id = targetId, let entry = tabs.removeValue(forKey: id) else {
            throw BrowserAutomationError.tabNotFound(targetId?.uuidString ?? "active")
        }

        entry.webView.stopLoading()
        if activeTabId == id {
            activeTabId = tabs.keys.first
        }
        return "Closed browser tab '\(entry.title)' (id: \(id))."
    }

    public func waitForElement(selector: String, timeoutSeconds: Double = 5.0) async throws -> Bool {
        let tab = getOrCreateActiveTab()
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        let script = "document.querySelector('\(escapeJS(selector))') != null;"

        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if let found = try? await tab.webView.evaluateJavaScript(script) as? Bool, found {
                return true
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return false
    }

    public func hover(elementId: String) async throws -> String {
        let tab = getOrCreateActiveTab()
        let script = """
        (function(targetId) {
            let el = document.querySelector('[data-aether-id="' + targetId + '"]') ||
                     document.getElementById(targetId) ||
                     document.querySelector(targetId);
            if (!el) return { success: false, reason: 'Element not found' };
            el.scrollIntoView({ behavior: 'instant', block: 'center' });
            el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true }));
            el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true }));
            return { success: true, tagName: el.tagName };
        })('\(escapeJS(elementId))')
        """
        guard let dict = try await tab.webView.evaluateJavaScript(script) as? [String: Any],
              let success = dict["success"] as? Bool, success else {
            throw BrowserAutomationError.elementNotFound(elementId)
        }
        return "Hovered over element '\(elementId)'."
    }

    public func pressKey(key: String, elementId: String? = nil) async throws -> String {
        let tab = getOrCreateActiveTab()
        let script = """
        (function(key, targetId) {
            let el = targetId ? (document.querySelector('[data-aether-id="' + targetId + '"]') ||
                                 document.getElementById(targetId) ||
                                 document.querySelector(targetId)) : document.activeElement;
            if (!el || el === document.body) el = document.querySelector('input, textarea, [tabindex]') || document.body;
            el.dispatchEvent(new KeyboardEvent('keydown', { key: key, bubbles: true, cancelable: true }));
            el.dispatchEvent(new KeyboardEvent('keypress', { key: key, bubbles: true, cancelable: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', { key: key, bubbles: true, cancelable: true }));
            return true;
        })('\(escapeJS(key))', \(elementId != nil ? "'\(escapeJS(elementId!))'" : "null"))
        """
        _ = try await tab.webView.evaluateJavaScript(script)
        return "Dispatched key '\(key)' to \(elementId != nil ? "element '\(elementId!)'" : "active element")."
    }

    public func selectOption(elementId: String, value: String) async throws -> String {
        let tab = getOrCreateActiveTab()
        let script = """
        (function(targetId, val) {
            let el = document.querySelector('[data-aether-id="' + targetId + '"]') ||
                     document.getElementById(targetId) ||
                     document.querySelector(targetId);
            if (!el) return { success: false, reason: 'Select element not found' };
            el.value = val;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.dispatchEvent(new Event('input', { bubbles: true }));
            return { success: true };
        })('\(escapeJS(elementId))', '\(escapeJS(value))')
        """
        guard let dict = try await tab.webView.evaluateJavaScript(script) as? [String: Any],
              let success = dict["success"] as? Bool, success else {
            throw BrowserAutomationError.elementNotFound(elementId)
        }
        return "Selected option '\(value)' in element '\(elementId)'."
    }

    public func getHTML(selector: String? = nil) async throws -> String {
        let tab = getOrCreateActiveTab()
        let script: String
        if let sel = selector, !sel.isEmpty {
            script = "document.querySelector('\(escapeJS(sel))')?.outerHTML || ''"
        } else {
            script = "document.documentElement ? document.documentElement.outerHTML : ''"
        }
        let result = try await tab.webView.evaluateJavaScript(script) as? String ?? ""
        return result
    }

    public func evaluate(script: String) async throws -> String {
        let tab = getOrCreateActiveTab()
        let wrapped = """
        (function() {
            try {
                let res = eval(\(escapeJS(script)));
                if (typeof res === 'object') return JSON.stringify(res);
                return String(res);
            } catch(e) {
                return 'Error: ' + e.message;
            }
        })()
        """
        let raw = try await tab.webView.evaluateJavaScript(wrapped)
        return (raw as? String) ?? "\(String(describing: raw))"
    }

    private func escapeJS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "'", with: "\\'")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
    }
}

