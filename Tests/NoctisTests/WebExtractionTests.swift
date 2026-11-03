import Foundation
import Testing
@testable import Noctis

struct WebExtractionTests {
    private let paragraph = String(repeating: "Un article détaillé, avec du contenu Unicode : café 日本語 👩🏽‍💻. ", count: 30)

    private func extract(_ html: String, maximum: Int = 20_000,
                         contentType: String = "text/html; charset=utf-8",
                         encoding: String.Encoding = .utf8) throws -> WebPage {
        let url = try #require(URL(string: "https://www.swift.org/article"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                   headerFields: ["Content-Type": contentType]))
        return try HTTPWebPageService(maximumCharacters: maximum).extract(
            data: #require(html.data(using: encoding)), response: response)
    }

    @Test func articleAndUnicode() throws {
        let page = try extract("<html><head><title>Mon article</title></head><body><article><p>\(paragraph)</p></article></body></html>")
        #expect(page.title.contains("Mon article"))
        #expect(page.content.contains("日本語"))
        #expect(page.content.contains("👩🏽‍💻"))
        #expect(!page.isTruncated)
        #expect(page.url == "https://www.swift.org/article")
    }

    @Test func noTitleAndMalformedHTML() throws {
        let page = try extract("<html><body><article><p>\(paragraph)")
        #expect(!page.title.isEmpty)
        #expect(!page.content.isEmpty)
    }

    @Test(arguments: ["", "   ", "<html><body></body></html>", "<html><head><script>doSomething()</script></head></html>"])
    func noContent(_ html: String) {
        #expect(throws: WebPageError.noContent) { try extract(html) }
    }

    @Test func truncationBoundary() throws {
        let html = "<html><body><article><p>\(paragraph)</p></article></body></html>"
        let full = try extract(html)
        let exact = try extract(html, maximum: full.content.count)
        #expect(!exact.isTruncated)
        let shorter = try extract(html, maximum: 40)
        #expect(shorter.content.count == 40)
        #expect(shorter.isTruncated)
        #expect(shorter.content == String(full.content.prefix(40)))
    }

    @Test func windowsEncoding() throws {
        let html = "<html><body><article><p>" + String(repeating: "Un café, un résumé et une histoire. ", count: 50) + "</p></article></body></html>"
        let page = try extract(html, contentType: "text/html; charset=windows-1252", encoding: .windowsCP1252)
        #expect(page.content.contains("café"))
    }

    @Test func unsupportedEncodingAndMIME() {
        #expect(throws: WebPageError.invalidEncoding) { try extract("hello", contentType: "text/html; charset=made-up") }
        #expect(throws: WebPageError.unsupportedContentType) { try extract("hello", contentType: "application/pdf") }
    }

    @Test func oversizedOfflineInput() throws {
        let url = try #require(URL(string: "https://www.swift.org"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                   headerFields: ["Content-Type": "text/html"]))
        #expect(throws: WebPageError.responseTooLarge) {
            try HTTPWebPageService().extract(data: Data(repeating: 65, count: 2_097_153), response: response)
        }
    }
}
