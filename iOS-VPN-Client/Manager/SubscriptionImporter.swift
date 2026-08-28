import Foundation

enum SubscriptionImporter {
    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private static let maximumNodeCount = 500

    static func fetchNodes(from subscription: ImportedSubscriptionCandidate) async throws -> [ImportedNodeCandidate] {
        do {
            return try await fetchNodes(from: subscription, userAgent: "AuraTunnel/1.0")
        } catch let error as SubscriptionImportError where error.allowsCompatibilityRetry {
            // Some provider panels use the User-Agent only to select their
            // Shadowrocket-compatible Base64 representation. If the first app
            // launch briefly reports an offline path after paste authorization,
            // wait once before retrying. This is bounded and never polls.
            if error.isTransportFailure {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return try await fetchNodes(
                from: subscription,
                userAgent: "Shadowrocket/2.2 AuraTunnel/1.0"
            )
        }
    }

    private static func fetchNodes(
        from subscription: ImportedSubscriptionCandidate,
        userAgent: String
    ) async throws -> [ImportedNodeCandidate] {
        var request = URLRequest(url: subscription.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/plain, text/yaml, application/yaml, application/json, */*",
            forHTTPHeaderField: "Accept"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 14
        configuration.httpMaximumConnectionsPerHost = 1
        // Let URLSession wait for a path transition on first launch instead of
        // immediately returning NSURLErrorNotConnectedToInternet. The resource
        // deadline above keeps the wait bounded to 30 seconds.
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SubscriptionImportError.transportFailure(transportDescription(for: error))
        } catch {
            throw SubscriptionImportError.transportFailure(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionImportError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SubscriptionImportError.httpStatus(httpResponse.statusCode)
        }
        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw SubscriptionImportError.responseTooLarge
        }
        guard data.count <= maximumResponseBytes else {
            throw SubscriptionImportError.responseTooLarge
        }
        guard let body = NodeImportParser.decodeSubscriptionBody(data) else {
            throw SubscriptionImportError.invalidEncoding
        }

        let payloads = extractPayloads(from: body)
        var seenPayloads = Set<String>()
        var seenNodeIDs = Set<UUID>()
        var nodes: [ImportedNodeCandidate] = []
        nodes.reserveCapacity(min(payloads.count, maximumNodeCount))

        for payload in payloads where nodes.count < maximumNodeCount {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenPayloads.insert(trimmed).inserted else { continue }
            guard let parsed = try? NodeImportParser.parse(trimmed) else { continue }
            if case .node(let node) = parsed, seenNodeIDs.insert(node.id).inserted {
                nodes.append(node)
            }
        }

        guard !nodes.isEmpty else {
            throw SubscriptionImportError.noSupportedNodes
        }
        return nodes
    }

    private static func extractPayloads(from body: String) -> [String] {
        if
            let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        {
            var values: [String] = []
            collectStrings(from: json, depth: 0, into: &values)
            if !values.isEmpty {
                return values
            }
        }

        return body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func collectStrings(from value: Any, depth: Int, into result: inout [String]) {
        guard depth <= 8, result.count < maximumNodeCount else { return }
        if let string = value as? String, string.contains("://") {
            result.append(string)
            return
        }
        if let array = value as? [Any] {
            for item in array where result.count < maximumNodeCount {
                collectStrings(from: item, depth: depth + 1, into: &result)
            }
        } else if let dictionary = value as? [String: Any] {
            for item in dictionary.values where result.count < maximumNodeCount {
                collectStrings(from: item, depth: depth + 1, into: &result)
            }
        }
    }

    private static func transportDescription(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            "网络暂时不可用；AuraTunnel 已等待网络恢复并自动重试一次。"
        case .networkConnectionLost:
            "下载过程中网络连接中断，请保持 Wi-Fi 或蜂窝网络可用后重试。"
        case .timedOut:
            "等待订阅服务器响应超时。"
        case .cannotFindHost, .dnsLookupFailed:
            "无法解析订阅服务器地址。"
        case .cannotConnectToHost:
            "无法连接订阅服务器。"
        default:
            error.localizedDescription
        }
    }
}

enum SubscriptionImportError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case invalidEncoding
    case noSupportedNodes
    case transportFailure(String)

    var allowsCompatibilityRetry: Bool {
        switch self {
        case .httpStatus(403), .httpStatus(406), .invalidEncoding, .noSupportedNodes,
             .transportFailure:
            true
        default:
            false
        }
    }

    var isTransportFailure: Bool {
        if case .transportFailure = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "订阅服务器返回了无效响应。"
        case .httpStatus(let status):
            "订阅服务器请求失败（HTTP \(status)）。"
        case .responseTooLarge:
            "订阅内容超过 4 MB，已停止导入。"
        case .invalidEncoding:
            "订阅内容不是可识别的文本或 Base64 节点列表。"
        case .noSupportedNodes:
            "订阅中没有找到当前支持的节点。"
        case .transportFailure(let reason):
            "无法下载订阅：\(reason)"
        }
    }
}
