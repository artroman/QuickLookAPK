//
//  PreviewViewController.swift
//  QuickLookAPKPreview
//
//  Created by Roman on 7. 7. 2026.
//

import Cocoa
import Quartz
import WebKit

/// View-based preview: hosts our own WKWebView so the extension owns the view
/// holding the selection and can handle Cmd-C itself. With a data-based HTML
/// preview, the Quick Look host consumes Cmd-C as a key equivalent (macOS 27+)
/// before the page ever sees it, so copying from the page is impossible.
class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {

    private var webView: CopyingWebView!
    private var loadContinuation: CheckedContinuation<Bool, Never>?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true

        webView = CopyingWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        view = webView
        preferredContentSize = NSSize(width: 800, height: 800)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
        stopHostDelayingClicks()
    }

    /// Quick Look's container view above ours carries a double-click recognizer (opens
    /// the file) and a press recognizer, both set to delay mouse events until they fail,
    /// which holds back every click in the page by the double-click interval. Let the
    /// events through right away; the recognizers themselves keep working.
    private func stopHostDelayingClicks() {
        var ancestor = view.superview
        while let current = ancestor {
            for recognizer in current.gestureRecognizers where recognizer.delaysPrimaryMouseButtonEvents {
                let isDoubleClick = (recognizer as? NSClickGestureRecognizer)?.numberOfClicksRequired ?? 0 >= 2
                if isDoubleClick || recognizer is NSPressGestureRecognizer {
                    recognizer.delaysPrimaryMouseButtonEvents = false
                }
            }
            ancestor = current.superview
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let path = url.path
        let labelLanguage = LabelLanguageSettings.language
        let html = try await Task.detached(priority: .userInitiated) { () throws -> String in
            guard let apk = AndroidPackage(path: path) else {
                throw CocoaError(.fileReadUnknown)
            }
            return androidPackageHTMLPreview(apk, labelLanguage: labelLanguage)
        }.value

        _ = view // make sure loadView() ran
        let loaded = await withCheckedContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        if !loaded {
            throw CocoaError(.fileReadUnknown)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(success: false)
    }

    /// Called when the WebContent process crashes or fails to launch (e.g. a
    /// missing sandbox entitlement); no navigation callback fires in that case.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading(success: false)
    }

    /// Only the initial HTML load is allowed; the preview never navigates away.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }

    private func finishLoading(success: Bool) {
        loadContinuation?.resume(returning: success)
        loadContinuation = nil
    }
}

/// WKWebView that copies the selected text on Cmd-C, whether the shortcut
/// arrives as a key equivalent, a key down, or a `copy:` action.
final class CopyingWebView: WKWebView {

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCopyShortcut(event) {
            copySelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isCopyShortcut(event) {
            copySelection()
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(copy(_:)) { return true }
        return super.responds(to: aSelector)
    }

    private static func isCopyShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private func copySelection() {
        evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else {
                NSSound.beep()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
