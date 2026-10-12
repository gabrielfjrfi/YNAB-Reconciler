import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw NetworkError.timedOut
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public protocol RetrySleeper: Sendable {
    func sleep(seconds: UInt64) async throws
}

public struct TaskRetrySleeper: RetrySleeper {
    public init() {}

    public func sleep(seconds: UInt64) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

public enum NetworkError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidToken
    case wrongPlanOrAccount
    case rateLimited
    case serverFailure(statusCode: Int)
    case clientFailure(statusCode: Int)
    case invalidURL
    case decodingFailure
    case timedOut
    case paginationLoop
}

public struct RetryingHTTPClient: Sendable {
    private let transport: any HTTPTransport
    private let sleeper: any RetrySleeper
    private let maximumAttempts: Int
    private let initialBackoffSeconds: UInt64

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        sleeper: any RetrySleeper = TaskRetrySleeper(),
        maximumAttempts: Int = 5,
        initialBackoffSeconds: UInt64 = 1
    ) {
        self.transport = transport
        self.sleeper = sleeper
        self.maximumAttempts = maximumAttempts
        self.initialBackoffSeconds = initialBackoffSeconds
    }

    public func execute(_ request: URLRequest) async throws -> Data {
        var backoff = initialBackoffSeconds
        for attempt in 1...maximumAttempts {
            let (data, response) = try await transport.data(for: request)
            switch response.statusCode {
            case 200...299:
                return data
            case 401, 403:
                throw NetworkError.invalidToken
            case 404:
                throw NetworkError.wrongPlanOrAccount
            case 429:
                guard attempt < maximumAttempts else { throw NetworkError.rateLimited }
                let delay = retryDelay(from: response) ?? backoff
                try await sleeper.sleep(seconds: delay)
                backoff = backoff.multipliedReportingOverflow(by: 2).overflow ? UInt64.max : backoff * 2
            case 500...599:
                guard attempt < maximumAttempts else {
                    throw NetworkError.serverFailure(statusCode: response.statusCode)
                }
                let delay = retryDelay(from: response) ?? backoff
                try await sleeper.sleep(seconds: delay)
                backoff = backoff.multipliedReportingOverflow(by: 2).overflow ? UInt64.max : backoff * 2
            default:
                throw NetworkError.clientFailure(statusCode: response.statusCode)
            }
        }
        throw NetworkError.invalidResponse
    }

    private func retryDelay(from response: HTTPURLResponse) -> UInt64? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        if let seconds = UInt64(value) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return UInt64(max(0, date.timeIntervalSinceNow.rounded(.up)))
    }
}

extension URLRequest {
    static func authenticated(
        url: URL,
        token: String,
        method: String = "GET",
        body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
