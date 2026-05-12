import Foundation
import AppKit
import WebKit

/// Renders an HTML string to PDF data via an off-screen WKWebView's print operation.
/// Must be invoked on the main actor (WebKit requirement).
enum PDFExporter {

    enum PDFError: Error {
        case loadFailed(Error)
        case printFailed
        case readFailed(Error)
    }

    /// Render the given HTML to PDF data.
    /// - Parameters:
    ///   - html: complete HTML document
    ///   - pageWidth: in points (default US Letter 612)
    ///   - pageHeight: in points (default US Letter 792)
    ///   - margins: per-side margin in points (default 36 = 0.5")
    @MainActor
    static func renderPDF(html: String,
                          pageWidth: CGFloat = 612,
                          pageHeight: CGFloat = 792,
                          margins: CGFloat = 36) async throws -> Data {
        let bridge = PDFRenderBridge(pageWidth: pageWidth, pageHeight: pageHeight, margins: margins)
        return try await bridge.render(html: html)
    }
}

@MainActor
private final class PDFRenderBridge: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let pageWidth: CGFloat
    private let pageHeight: CGFloat
    private let margins: CGFloat
    private var continuation: CheckedContinuation<Data, Error>?

    init(pageWidth: CGFloat, pageHeight: CGFloat, margins: CGFloat) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.margins = margins
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
                                 configuration: config)
        super.init()
        self.webView.navigationDelegate = self
    }

    func render(html: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.continuation = cont
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            await self.printToPDF()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(.failure(PDFExporter.PDFError.loadFailed(error)))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.finish(.failure(PDFExporter.PDFError.loadFailed(error)))
        }
    }

    private func printToPDF() async {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: pageWidth, height: pageHeight)
        info.topMargin = margins
        info.bottomMargin = margins
        info.leftMargin = margins
        info.rightMargin = margins
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        // Write PDF to a temp file then read.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wattmeter-\(UUID().uuidString).pdf")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp as NSURL

        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        // Run synchronously off the print panel; runModal performs the save.
        let ok = op.run()
        if !ok {
            finish(.failure(PDFExporter.PDFError.printFailed))
            return
        }
        do {
            let data = try Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            finish(.success(data))
        } catch {
            finish(.failure(PDFExporter.PDFError.readFailed(error)))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        switch result {
        case .success(let d): cont.resume(returning: d)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}
