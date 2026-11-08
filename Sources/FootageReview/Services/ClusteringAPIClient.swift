import Foundation

private final class ClusteringSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ClusteringAPIProblem: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let detail: Detail
}

/// One in-memory cookie jar for this owned backend. Credentials never become URLs or files.
@MainActor
final class ClusteringAPIClient {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard Self.validEndpoint(endpoint) else { throw ClusteringFailure("The tool did not provide a valid local endpoint.") }
        self.endpoint = endpoint
        configuration.httpShouldSetCookies = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration, delegate: ClusteringSessionDelegate(), delegateQueue: nil)
    }

    static func validEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "http" && components.host == "127.0.0.1"
            && components.port.map { (1...65535).contains($0) } == true
            && components.user == nil && components.password == nil
            && components.query == nil && components.fragment == nil
            && (components.path.isEmpty || components.path == "/")
    }

    static func segment(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func request<T: Decodable>(_ method: String, _ path: String, body: ClusterJSON? = nil,
                               bootstrapToken: String? = nil) async throws -> T {
        guard path.hasPrefix("/api/"), let url = URL(string: path, relativeTo: endpoint)?.absoluteURL,
              url.host == endpoint.host, url.port == endpoint.port else {
            throw ClusteringFailure("Invalid clustering request path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if path.hasSuffix("/control") { request.timeoutInterval = 5 }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body ?? .object([:]))
        }
        if let bootstrapToken { request.setValue("Bearer \(bootstrapToken)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw ClusteringFailure("The clustering tool could not be reached. Start or reconnect the tool, then retry.")
        }
        guard let http = response as? HTTPURLResponse, data.count <= 64 * 1024 * 1024 else {
            throw ClusteringFailure("The clustering tool returned an invalid or oversized response.")
        }
        guard http.url?.host == endpoint.host, http.url?.port == endpoint.port else {
            throw ClusteringFailure("The clustering tool redirected outside its local endpoint.")
        }
        guard (200...299).contains(http.statusCode) else {
            if let issue = try? JSONDecoder().decode(ClusteringAPIProblem.self, from: data) {
                throw ClusteringFailure("\(issue.detail.message.prefix(600)) (\(issue.detail.code.prefix(100)))")
            }
            throw ClusteringFailure("The clustering tool rejected the request (HTTP \(http.statusCode)).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ClusteringFailure("The clustering tool response does not match its API contract.") }
    }

    func status() async throws -> ClusterBackendStatus { try await request("GET", "/api/status") }
    func bootstrap(token: String) async throws -> ClusterBackendStatus {
        try await request("POST", "/api/session", bootstrapToken: token)
    }
    func connect(endpoint: String, token: String) async throws -> ClusterBackendStatus {
        try await request("POST", "/api/connect", body: .object(["endpoint": .string(endpoint), "token": .string(token)]))
    }
    func workspace(_ id: String) async throws -> ClusterWorkspace {
        try await request("GET", "/api/workspaces/\(Self.segment(id))")
    }
    func job(_ id: String) async throws -> ClusterJob {
        try await request("GET", "/api/jobs/\(Self.segment(id))")
    }
    func control(_ id: String, action: String) async throws -> ClusterJob {
        try await request("POST", "/api/jobs/\(Self.segment(id))/control", body: .object(["action": .string(action)]))
    }
    func invalidate() { session.invalidateAndCancel() }
}
