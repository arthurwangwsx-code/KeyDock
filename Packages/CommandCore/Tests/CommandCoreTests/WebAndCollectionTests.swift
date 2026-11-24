import Foundation
import Testing
@testable import CommandCore

@Suite struct WebActionDefinitionTests {
    private func action(_ template: String) throws -> WebActionDefinition {
        try WebActionDefinition(name: "Synthetic web action", urlTemplate: template)
    }
    @Test func fixedHTTPAndHTTPSURLsKeepQueryAndFragmentWithoutInput() throws {
        for text in ["https://example.test/docs?language=en#intro", "http://localhost:8080/status", "https://127.0.0.1/path"] {
            let definition = try action(text)
            let resolved = try definition.resolvedURL()
            #expect(!definition.requiresQuery && resolved.absoluteString == text)
        }
        #expect(throws: WebActionValidationError.unexpectedQuery) { try action("https://example.test").resolvedURL(query: "secret") }
    }
    @Test func templateEncodesReservedCharactersAsOneQueryValue() throws {
        let definition = try action("https://example.test/search?q={query}&mode=exact#results")
        let input = "a+b &next=https://evil.test/#x?y=1%"
        let url = try definition.resolvedURL(query: input)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "example.test" && components.fragment == "results")
        #expect(components.queryItems?.count == 2 && components.queryItems?.first?.value == input)
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        #expect(components.percentEncodedQuery?.contains("%26next%3Dhttps%3A%2F%2F") == true)
    }
    @Test func unicodeQueryUsesUTF8AndDoesNotExpandNewPlaceholders() throws {
        let definition = try action("https://example.test/?q={query}")
        let url = try definition.resolvedURL(query: "你好 🌍 {query} %0A")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first?.value == "你好 🌍 {query} %0A")
        #expect(components.percentEncodedQuery?.contains("%E4%BD%A0%E5%A5%BD%20%F0%9F%8C%8D") == true)
        #expect(components.percentEncodedQuery?.contains("%250A") == true)
    }
    @Test func templateMustBeOneLiteralTokenInsideTheQuery() {
        for text in ["https://{query}.test/", "https://example.test/{query}", "https://example.test/#?q={query}", "https://example.test/?q=1#{query}", "https://example.test/?q={query}&other={query}", "https://example.test/?q={{query}}", "https://example.test/?q={other}"] {
            #expect(throws: WebActionValidationError.invalidPlaceholder) { try action(text) }
        }
    }
    @Test func encodedPlaceholderIsLiteralFixedURLData() throws {
        let definition = try action("https://example.test/?q=%7Bquery%7D")
        #expect(!definition.requiresQuery)
        #expect(try definition.resolvedURL().absoluteString.contains("%7Bquery%7D"))
    }
    @Test func credentialsAndNonWebSchemesAreRejected() {
        for text in ["https://alice:secret@example.test/", "https://@example.test/", "https://alice@example.test/"] {
            #expect(throws: WebActionValidationError.credentialsNotAllowed) { try action(text) }
        }
        for text in ["file:///tmp/synthetic", "javascript://example.test/test", "ftp://example.test/file"] {
            #expect(throws: WebActionValidationError.unsupportedScheme) { try action(text) }
        }
    }
    @Test func invalidAndAmbiguousHostsAndPortsAreNotRepaired() {
        for text in ["https:///path", "https://-bad.test/", "https://bad..test/", "https://bad_host.test/", "https://256.0.0.1/", "https://127.01.0.1/", "https://2130706433/", "https://0x7f000001/", "https://example.123/", "https://%65xample.test/", "https://[::1]/"] {
            #expect(throws: WebActionValidationError.invalidHost) { try action(text) }
        }
        for text in ["https://example.test:/", "https://example.test:0/", "https://example.test:65536/", "https://example.test:abc/"] {
            #expect(throws: WebActionValidationError.invalidURL) { try action(text) }
        }
    }
    @Test func userInfoIsRejectedEvenWhenEmptyOrPercentEncoded() {
        for text in ["https://user@example.test/", "https://user:secret@example.test/", "https://@example.test/", "https://user%3Asecret@example.test/"] {
            #expect(throws: WebActionValidationError.credentialsNotAllowed) { try action(text) }
        }
    }
    @Test func controlsAndMalformedEscapesCannotReachAURL() {
        for text in ["https://example.test/\npath", "https://example.test/?q=%0A", "https://example.test/%00"] {
            #expect(throws: WebActionValidationError.controlCharacters) { try action(text) }
        }
        for text in ["https://example.test/%", "https://example.test/%GG", "https://example.test/a b", "https://example.test/%FF", "https://example.test/\\path"] {
            #expect(throws: WebActionValidationError.invalidURL) { try action(text) }
        }
        #expect(throws: WebActionValidationError.controlCharacters) { try action("https://example.test/?q={query}").resolvedURL(query: "a\tb") }
    }
    @Test func queryAndDefinitionBudgetsUseUTF8Bytes() throws {
        let definition = try action("https://example.test/?q={query}")
        #expect(throws: WebActionValidationError.missingQuery) { try definition.resolvedURL() }
        #expect(throws: WebActionValidationError.missingQuery) { try definition.resolvedURL(query: "") }
        #expect(throws: WebActionValidationError.queryTooLong) { try definition.resolvedURL(query: String(repeating: "你", count: 342)) }
        #expect(try definition.resolvedURL(query: String(repeating: "a", count: 1_024)).host == "example.test")
        #expect(throws: WebActionValidationError.urlTooLong) { try action("https://example.test/" + String(repeating: "a", count: 4_096)) }
        #expect(throws: WebActionValidationError.nameTooLong) { try WebActionDefinition(name: String(repeating: "你", count: 67), urlTemplate: "https://example.test") }
    }
    @Test func decodingReusesURLValidationAndPreservesIdentity() throws {
        let original = try action("https://example.test/?q={query}")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(WebActionDefinition.self, from: data) == original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["urlTemplate"] = "javascript://example.test/path"
        #expect(throws: WebActionValidationError.unsupportedScheme) {
            try JSONDecoder().decode(WebActionDefinition.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}

@Suite struct CommandCollectionTests {
    @Test func collectionPreservesOrderAndActualApplicationPathIDs() throws {
        let ids = ["utility.tasks", "app./Applications/Synthetic App.app", "app./Applications/合成.app", "command." + UUID().uuidString]
        let collection = try CommandCollection(name: "  Synthetic group  ", commandIDs: ids)
        #expect(collection.name == "Synthetic group" && collection.commandIDs == ids)
        #expect(try JSONDecoder().decode(CommandCollection.self, from: JSONEncoder().encode(collection)) == collection)
    }
    @Test func emptyGroupAndMaximumDistinctReferencesAreValid() throws {
        #expect(try CommandCollection(name: "Synthetic empty group").commandIDs.isEmpty)
        let ids = (0..<32).map { "utility.synthetic-\($0)" }
        #expect(try CommandCollection(name: "Synthetic group", commandIDs: ids).commandIDs == ids)
        #expect(throws: CommandCollectionValidationError.tooManyCommands) { try CommandCollection(name: "Synthetic", commandIDs: ids + ["utility.extra"]) }
    }
    @Test func duplicatesAreRejectedInsteadOfSilentlyCollapsed() {
        #expect(throws: CommandCollectionValidationError.duplicateCommandID) { try CommandCollection(name: "Synthetic", commandIDs: ["utility.tasks", "utility.tasks"]) }
    }
    @Test func malformedReferencesAndNamesCannotBeSaved() {
        for id in ["tasks", ".tasks", "utility.", " utility.tasks", "utility.tasks ", "utility.\nmalformed", "utility..tasks", "utility.a/b", "utility." + String(repeating: "a", count: 512)] {
            #expect(throws: CommandCollectionValidationError.invalidCommandID) { try CommandCollection(name: "Synthetic", commandIDs: [id]) }
        }
        #expect(throws: CommandCollectionValidationError.invalidName) { try CommandCollection(name: " \t ") }
        #expect(throws: CommandCollectionValidationError.nameTooLong) { try CommandCollection(name: String(repeating: "你", count: 67)) }
    }
    @Test func decoderRejectsDuplicateAndOversizedArrays() throws {
        let original = try CommandCollection(name: "Synthetic", commandIDs: ["utility.tasks"])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["commandIDs"] = ["utility.tasks", "utility.tasks"]
        #expect(throws: CommandCollectionValidationError.duplicateCommandID) { try JSONDecoder().decode(CommandCollection.self, from: JSONSerialization.data(withJSONObject: json)) }
        json["commandIDs"] = (0..<33).map { "utility.synthetic-\($0)" }
        #expect(throws: CommandCollectionValidationError.tooManyCommands) { try JSONDecoder().decode(CommandCollection.self, from: JSONSerialization.data(withJSONObject: json)) }
    }
}
