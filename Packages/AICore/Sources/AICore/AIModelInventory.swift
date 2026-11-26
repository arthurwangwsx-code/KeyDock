import Foundation

/// Swift String 的等价规范化不能用于服务返回的准确模型标识。
public struct AIModelID: Hashable, Sendable, Identifiable {
    public let value: String
    public var id: Self { self }
    public init(_ value: String) { self.value = value }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value.utf8.elementsEqual(rhs.value.utf8) }
    public func hash(into hasher: inout Hasher) { hasher.combine(Data(value.utf8)) }
}

public struct AIModelInventory: Sendable, Equatable {
    public let models: [AIModelID]
    public let fetchedAt: Date
    public let isPartial: Bool
    public init(models: [AIModelID], fetchedAt: Date = Date(), isPartial: Bool = false) {
        self.models = models; self.fetchedAt = fetchedAt; self.isPartial = isPartial
    }
}

public enum AIModelInventoryError: Error { case unsupportedEndpoint, invalidResponse, limitExceeded }

/// 只获取模型 ID，不推断能力、推荐级别、价格或实际调用资格。
public struct AIModelInventoryClient: Sendable {
    private let transport: any AIHTTPTransport
    public init(transport: any AIHTTPTransport = URLSessionAITransport()) { self.transport = transport }

    public static func listEndpoint(for endpoint: URL, allowsLocalHTTP: Bool) throws -> URL {
        try AIProviderConfiguration(endpoint: endpoint, model: "inventory", allowsLocalHTTP: allowsLocalHTTP).validate()
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), parts.query == nil,
              parts.fragment == nil else { throw AIModelInventoryError.unsupportedEndpoint }
        let path = parts.percentEncodedPath
        guard let suffix = ["/chat/completions", "/responses"].first(where: { path.hasSuffix($0) }) else {
            throw AIModelInventoryError.unsupportedEndpoint
        }
        parts.percentEncodedPath = String(path.dropLast(suffix.count)) + "/models"
        guard let result = parts.url else { throw AIModelInventoryError.unsupportedEndpoint }
        return result
    }

    public func list(endpoint: URL, allowsLocalHTTP: Bool, apiKey: String) async throws -> AIModelInventory {
        let url = try Self.listEndpoint(for: endpoint, allowsLocalHTTP: allowsLocalHTTP)
        guard apiKey.utf8.count <= 16_384, !apiKey.contains(where: { $0.isNewline || $0 == "\0" }) else { throw AIProviderError.invalidRequest }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: AIModelInventory.self) { group in
            group.addTask { try await fetch(url: url, apiKey: apiKey) }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func fetch(url: URL, apiKey: String) async throws -> AIModelInventory {
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let response = try await transport.open(request)
        do {
            let result = try await withTaskCancellationHandler {
                guard (200..<300).contains(response.statusCode) else { throw AIProviderError.httpStatus(response.statusCode) }
                guard response.contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                    throw AIProviderError.invalidContentType
                }
                var bytes = Data()
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    guard chunk.count <= 1_048_576 - bytes.count else { throw AIModelInventoryError.limitExceeded }
                    bytes.append(chunk)
                }
                try Task.checkCancellation()
                return try Self.decode(bytes)
            } onCancel: { response.cancel() }
            response.cancel(); await response.waitForCompletion()
            try Task.checkCancellation()
            return result
        } catch {
            response.cancel(); await response.waitForCompletion(); throw error
        }
    }

    public static func decode(_ bytes: Data) throws -> AIModelInventory {
        struct Document: Decodable {
            struct Entry: Decodable { let id: String }
            let object: String
            let data: [Entry]
            let has_more: Bool?
        }
        guard bytes.count <= 1_048_576 else { throw AIModelInventoryError.limitExceeded }
        let value: Document
        do { value = try JSONDecoder().decode(Document.self, from: bytes) }
        catch { throw AIModelInventoryError.invalidResponse }
        guard value.object == "list" else { throw AIModelInventoryError.invalidResponse }
        guard value.data.count <= 512 else { throw AIModelInventoryError.limitExceeded }
        var seen = Set<AIModelID>(), models: [AIModelID] = []
        for entry in value.data {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.id.utf8.count <= 256,
                  !entry.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AIModelInventoryError.invalidResponse
            }
            let id = AIModelID(entry.id)
            if seen.insert(id).inserted { models.append(id) }
        }
        models.sort { $0.value.utf8.lexicographicallyPrecedes($1.value.utf8) }
        return AIModelInventory(models: models, isPartial: value.has_more == true)
    }
}
