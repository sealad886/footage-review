import Foundation
import Network

/// A deliberately small HTTP/1.1 server. Its socket never listens beyond this Mac.
final class ReviewHTTPServer: @unchecked Sendable {
    private let token: String
    private let allowedOrigin: String?
    private let handler: @Sendable (APIRequest) async -> APIResponse
    private let queue = DispatchQueue(label: "FootageReview.HTTP")
    private var listener: NWListener?
    private var clients: [UUID: HTTPClient] = [:]

    init(token: String, allowedOrigin: String? = nil,
         handler: @escaping @Sendable (APIRequest) async -> APIResponse) {
        self.token = token
        self.allowedOrigin = allowedOrigin
        self.handler = handler
    }

    func start(port: UInt16, onReady: @escaping @Sendable (UInt16) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) throws {
        guard !token.isEmpty else {
            throw APIProblem(status: 400, code: "invalid_token", message: "An API token is required.")
        }
        let parameters = NWParameters.tcp
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        // requiredLocalEndpoint already supplies the loopback address and port.
        let newListener = try NWListener(using: parameters)
        try queue.sync {
            guard listener == nil else {
                throw APIProblem(status: 409, code: "already_running", message: "The API is already running.")
            }
            listener = newListener
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, self.listener === newListener else { return }
            switch state {
            case .ready:
                if let readyPort = newListener?.port?.rawValue { onReady(readyPort) }
            case .failed:
                self.stopOnQueue()
                onFailure("The local API could not listen. Check whether the port is already in use.")
            case .waiting:
                self.stopOnQueue()
                onFailure("The local API is waiting for its loopback network interface.")
            default: break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            let client = HTTPClient(connection: connection, queue: self.queue,
                                    token: self.token, allowedOrigin: self.allowedOrigin,
                                    handler: self.handler) { [weak self] in
                self?.clients.removeValue(forKey: id)
            }
            guard self.clients.count < 16 else {
                client.start(rejection: httpProblem(503, "server_busy", "The API has too many active requests. Retry shortly."))
                return
            }
            self.clients[id] = client
            client.start()
        }
        newListener.start(queue: queue)
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        let activeClients = Array(clients.values)
        clients.removeAll()
        activeClients.forEach { $0.cancel() }
    }
}

private final class HTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let allowedOrigin: String?
    private let handler: @Sendable (APIRequest) async -> APIResponse
    private let onClose: @Sendable () -> Void
    private var buffer = Data()
    private var request: APIRequest?
    private var bodyStart = 0
    private var bodyLength = 0
    private var responseOrigin: String?
    private var completed = false
    private var responding = false
    private var timeout: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private let requestID = UUID().uuidString
    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 2 * 1024 * 1024

    init(connection: NWConnection, queue: DispatchQueue, token: String, allowedOrigin: String?,
         handler: @escaping @Sendable (APIRequest) async -> APIResponse,
         onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.allowedOrigin = allowedOrigin
        self.handler = handler
        self.onClose = onClose
    }

    func start(rejection: APIResponse? = nil) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [self] in
            if responding { cancel() }
            else { send(httpProblem(408, "request_timeout", "The request exceeded ten seconds.")) }
        }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + 10, execute: deadline)
        if let rejection { send(rejection) } else { receive() }
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }

    private func receive() {
        guard !completed && !responding else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            guard !completed && !responding else { return }
            if let data { buffer.append(data) }
            do {
                if request == nil { try parseHeaders() }
                if let request, buffer.count >= bodyStart + bodyLength {
                    guard buffer.count == bodyStart + bodyLength else {
                        throw APIProblem(status: 400, code: "invalid_request", message: "Send one request per connection.")
                    }
                    let ready = APIRequest(method: request.method, target: request.target, headers: request.headers,
                                           body: Data(buffer[bodyStart...]))
                    buffer.removeAll(keepingCapacity: false)
                    task = Task { [self] in
                        let result = await self.handler(ready)
                        self.queue.async { [self] in self.send(result) }
                    }
                    return
                }
                if error != nil || isComplete {
                    send(httpProblem(400, "incomplete_request", "The HTTP request ended before its complete body arrived."))
                } else { receive() }
            } catch let problem as APIProblem {
                send(httpProblem(problem.status, problem.code, problem.message))
            } catch {
                send(httpProblem(400, "invalid_request", "The HTTP request could not be parsed."))
            }
        }
    }

    private func parseHeaders() throws {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.headerLimit {
                throw APIProblem(status: 431, code: "headers_too_large", message: "HTTP headers exceed 16 KiB.")
            }
            return
        }
        bodyStart = end.upperBound
        guard bodyStart <= Self.headerLimit,
              let header = String(data: buffer[..<end.lowerBound], encoding: .ascii) else {
            throw APIProblem(status: 431, code: "invalid_headers", message: "Use ASCII HTTP headers no larger than 16 KiB.")
        }
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1", parts[1].hasPrefix("/"),
              !parts[1].hasPrefix("//"), !parts[1].contains("#"),
              parts[0].allSatisfy({ $0.isASCII && $0.isLetter && $0.isUppercase }) else {
            throw APIProblem(status: 400, code: "invalid_request", message: "Use an HTTP/1.1 request with an origin-form path.")
        }
        var headers: [String: String] = [:]
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw APIProblem(status: 400, code: "invalid_headers", message: "A header is missing its colon.")
            }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }),
                  headers[name] == nil else {
                throw APIProblem(status: 400, code: "invalid_headers", message: "Header names must be valid and may appear only once.")
            }
            headers[name] = value
        }
        guard headers["host"]?.isEmpty == false else {
            throw APIProblem(status: 400, code: "invalid_headers", message: "The Host header is required.")
        }
        guard headers["transfer-encoding"] == nil else {
            throw APIProblem(status: 400, code: "unsupported_transfer_encoding", message: "Use Content-Length; Transfer-Encoding is unsupported.")
        }
        if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length) else {
                throw APIProblem(status: 400, code: "invalid_content_length", message: "Content-Length must be a nonnegative decimal integer.")
            }
            guard count <= Self.bodyLimit else {
                throw APIProblem(status: 413, code: "body_too_large", message: "The request body exceeds 2 MiB.")
            }
            bodyLength = count
        }
        let method = String(parts[0])
        if let origin = headers["origin"] {
            guard let allowedOrigin, origin == allowedOrigin else {
                throw APIProblem(status: 403, code: "origin_not_allowed", message: "This browser origin is not allowed.")
            }
            responseOrigin = origin
            if method == "OPTIONS" {
                let requestedMethod = headers["access-control-request-method"] ?? ""
                let requestedHeaders = (headers["access-control-request-headers"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard ["GET", "POST", "OPTIONS"].contains(requestedMethod),
                      requestedHeaders.allSatisfy({ ["authorization", "content-type"].contains($0) }) else {
                    throw APIProblem(status: 403, code: "preflight_not_allowed", message: "The requested browser method or headers are not allowed.")
                }
                send(APIResponse(status: 204, headers: ["Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                     "Access-Control-Allow-Headers": "Authorization, Content-Type", "Access-Control-Max-Age": "600"], body: Data()))
                return
            }
        }
        let authorization = headers["authorization"] ?? ""
        let credentials = authorization.split(separator: " ", omittingEmptySubsequences: false)
        guard credentials.count == 2, credentials[0].lowercased() == "bearer",
              constantTimeEqual(String(credentials[1]), token) else {
            send(httpProblem(401, "unauthorized", "A valid Bearer API token is required.", headers: ["WWW-Authenticate": "Bearer"]))
            return
        }
        request = APIRequest(method: method, target: String(parts[1]), headers: headers, body: Data())
    }

    private func send(_ response: APIResponse) {
        guard !completed && !responding else { return }
        responding = true
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Request-ID"] = requestID
        if let responseOrigin {
            headers["Access-Control-Allow-Origin"] = responseOrigin
            headers["Vary"] = "Origin"
            headers["Access-Control-Expose-Headers"] = "X-Request-ID"
        }
        let reasons = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                       403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
                       409: "Conflict", 410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type",
                       422: "Unprocessable Content", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
                       503: "Service Unavailable"]
        var output = Data("HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Response")\r\n".utf8)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            output.append(Data("\(name): \(value)\r\n".utf8))
        }
        output.append(Data("\r\n".utf8))
        output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { [self] _ in cancel() })
    }
}

private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let lhs = Array(left.utf8), rhs = Array(right.utf8)
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
}

private func httpProblem(_ status: Int, _ code: String, _ message: String,
                         headers: [String: String] = [:]) -> APIResponse {
    var response = APIResponse.json(status: status, value: ["code": code, "message": message])
    response.headers.merge(headers) { _, new in new }
    return response
}
