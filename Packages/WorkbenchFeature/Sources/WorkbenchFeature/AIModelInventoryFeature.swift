import Foundation
import AICore

extension WorkbenchModel {
    func invalidateModelInventories() {
        savedServiceModels = []
        modelInventoryEpoch = UUID()
        for id in modelInventoryOperationIDs { configurationOperations[id]?.cancel() }
    }

    /// 凭据只在用户明确刷新之后读取。新服务不借用旧服务槽位；Preview从不读钥匙串。
    func fetchModelInventory(endpoint: String, localHTTP: Bool, draftKey: String,
                             client: AIModelInventoryClient) async throws -> AIModelInventory {
        try requireGeneralRuntime()
        guard !isShuttingDown, !Task.isCancelled, modelInventoryOperationIDs.isEmpty, let url = URL(string: endpoint) else { throw CancellationError() }
        _ = try AIModelInventoryClient.listEndpoint(for: url, allowsLocalHTTP: localHTTP)
        _ = try authorizeHostAction(id: "ai.models", operation: .discoverModels,
                                    resource: endpoint + "|" + modelInventoryEpoch.uuidString)
        guard allowContextCapture || draftKey.isEmpty else { throw AIProviderError.invalidConfiguration }
        // 有界解码、JSON和HTTP临时副本共享会话预算；元数据刷新不逐出用户历史。
        guard !isClearingHistory, !mutatingSession, retainedSessionBytes() + 4_194_304 <= sessionLimits.textBytes else { throw SessionAdmissionError.capacity }
        modelInventoryWorkingBytes = 4_194_304
        let operation = UUID()
        let worker = Task { @MainActor in
            defer { configurationOperations[operation] = nil; modelInventoryOperationIDs.remove(operation); modelInventoryWorkingBytes = 0 }
            do {
                try Task.checkCancellation()
                let key = draftKey.isEmpty && allowContextCapture && endpoint.utf8.elementsEqual(configuration.endpoint.utf8)
                    ? (try credentialReader(configuration.endpoint) ?? "") : draftKey
                return Result<AIModelInventory, Error>.success(try await client.list(endpoint: url, allowsLocalHTTP: localHTTP, apiKey: key))
            }
            catch { return Result<AIModelInventory, Error>.failure(error) }
        }
        trackConfigurationOperation(worker, id: operation); modelInventoryOperationIDs.insert(operation)
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return try result.get()
    }
}

extension SettingsSession {
    func invalidateModelInventory(clear: Bool = true) {
        modelInventoryRequestID = UUID(); modelInventoryTask?.cancel()
        // 取消仅撤销发布资格；上一worker真正drain前不能再提交新的列表请求。
        modelInventoryBusy = modelInventoryTask != nil; modelInventoryNotice = .none
        if clear { modelInventory = nil }
    }

    func refreshModelInventory(in store: WorkbenchModel, client: AIModelInventoryClient = .init()) {
        guard modelInventoryVisible, pane == .aiService, !modelInventoryBusy, !store.isShuttingDown, !store.isDesktopReview else { return }
        let requestID = UUID(), epoch = store.modelInventoryEpoch
        let endpoint = self.endpoint, localHTTP = self.localHTTP, key = apiKey
        // 先校验路径，避免向不明确的自定义服务猜测鉴权地址。
        guard let url = URL(string: endpoint), (try? AIModelInventoryClient.listEndpoint(for: url, allowsLocalHTTP: localHTTP)) != nil else {
            modelInventoryNotice = noticeKey("This endpoint has no unambiguous models URL. Keep using exact model IDs."); return
        }
        modelInventoryTask?.cancel(); modelInventoryRequestID = requestID; modelInventoryBusy = true; modelInventoryNotice = .none
        modelInventoryTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            defer { modelInventoryBusy = false; modelInventoryTask = nil }
            do {
                let value = try await store.fetchModelInventory(endpoint: endpoint, localHTTP: localHTTP, draftKey: key, client: client)
                guard !Task.isCancelled, modelInventoryRequestID == requestID, store.modelInventoryEpoch == epoch, !store.isShuttingDown else { return }
                modelInventory = value
                // 只有保存服务当前凭据返回的清单可供定义编辑器复用；草稿连接不污染它。
                if key.isEmpty, endpoint.utf8.elementsEqual(store.configuration.endpoint.utf8), localHTTP == store.configuration.localHTTP {
                    store.savedServiceModels = value.models
                }
                modelInventoryNotice = noticeKey(value.isPartial ? "Partial model list received. Existing selections are preserved." : "Model list refreshed. Existing selections are preserved.")
            } catch {
                guard !Task.isCancelled, modelInventoryRequestID == requestID, store.modelInventoryEpoch == epoch, !store.isShuttingDown else { return }
                modelInventoryNotice = modelInventoryFailureNotice(error)
            }
        }
    }
}

/// 仅展示白名单错误类别，不拼接服务端正文、URL、密钥或任意Error.description。
func modelInventoryFailureNotice(_ error: Error) -> LocalizedNotice {
    if let value = error as? AIProviderError {
        switch value {
        case .httpStatus(401), .httpStatus(403): return noticeKey("Model-list authentication was rejected. Check the key for this endpoint. The last list and selections are preserved.")
        case .httpStatus(429): return noticeKey("The service rate-limited the model list. Try again later. The last list and selections are preserved.")
        case .outputLimit: return noticeKey("The model-list response exceeded its limits. The last list and selections are preserved.")
        case .invalidContentType: return noticeKey("The service did not return a supported model list. Keep using exact model IDs.")
        default: break
        }
    }
    if let value = error as? AIModelInventoryError {
        switch value {
        case .limitExceeded: return noticeKey("The model-list response exceeded its limits. The last list and selections are preserved.")
        case .invalidResponse: return noticeKey("The service did not return a supported model list. Keep using exact model IDs.")
        case .unsupportedEndpoint: return noticeKey("This endpoint has no unambiguous models URL. Keep using exact model IDs.")
        }
    }
    if (error as? URLError)?.code == .timedOut { return noticeKey("The model-list request timed out. The last list and selections are preserved.") }
    return noticeKey("Model list could not be refreshed. Check the endpoint, credentials or connection. Existing selections and the last successful list are preserved.")
}
