import Foundation

/// base64url ⇄ Data. The self-hosted server speaks base64url on the wire (App Attest payloads,
/// key ids, nonces); `Data.base64EncodedString()` is standard base64, so we translate the
/// alphabet and strip padding.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Injectable `URLSession` seam so `SelfHostedCatalogRemote` and `AppAttestSessionProvider` are
/// unit-testable without a live server (tests provide a fake conformance).
protocol HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streaming variant: `onBytes` receives the cumulative byte count as the body downloads
    /// (drives the catalog download toast). Conformers without streaming fall back to `send`.
    func send(_ request: URLRequest,
              onBytes: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse)
}

extension HTTPClient {
    func send(_ request: URLRequest,
              onBytes: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
}

struct URLSessionHTTPClient: HTTPClient {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        return (data, http)
    }

    func send(_ request: URLRequest,
              onBytes: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.dataReportingProgress(for: request, onBytes: onBytes)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        return (data, http)
    }
}

extension URLSession {
    /// `data(for:)` with cumulative byte progress, reported every 64 KiB and once at the end.
    // ponytail: per-byte AsyncBytes loop (~1s/60MB in release); switch to a delegate-based
    // task if artifact sizes ever make this the bottleneck.
    func dataReportingProgress(for request: URLRequest,
                               onBytes: @Sendable (Int) -> Void) async throws -> (Data, URLResponse) {
        let (stream, response) = try await bytes(for: request)
        var data = Data()
        let expected = Int(response.expectedContentLength)
        if expected > 0 { data.reserveCapacity(expected) }
        var received = 0
        for try await byte in stream {
            data.append(byte)
            received += 1
            if received & 0xFFFF == 0 { onBytes(received) }
        }
        onBytes(received)
        return (data, response)
    }
}
