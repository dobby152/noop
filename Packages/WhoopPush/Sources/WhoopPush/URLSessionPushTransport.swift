import Foundation

/// Přenos přes URLSession: bez přesměrování (token se nikdy nepřeposílá), bez gzipu (protokol dovoluje identitu).
/// Volat z pracovního vlákna, nikdy z hlavního: čeká na odpověď synchronně.
public final class URLSessionPushTransport: NSObject, PushTransport, URLSessionTaskDelegate {
    private let endpoint: URL
    private let token: String
    private var session: URLSession!

    public init(endpoint: URL, token: String, timeout: TimeInterval = 15, wifiOnly: Bool = false) {
        self.endpoint = endpoint
        self.token = token
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        // Wi-Fi only: žádná mobilní data ani drahá/omezená síť (hotspot).
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func capabilities() throws -> PushCapabilities {
        let (status, data) = try send(method: "GET", body: nil, headers: ["Accept": "application/json", "NOOP-Push-Accept-Version": PushIdentity.version])
        guard (200...299).contains(status) else { throw PushFailure.http(status) }
        do { return try PushCapabilities.parse(data) } catch { throw PushFailure.invalidCapabilities }
    }

    public func post(_ batch: Batch) throws -> Data {
        let (status, data) = try send(method: "POST", body: batch.body, headers: ["Content-Type": "application/x-ndjson; charset=utf-8", "Accept": "application/json"])
        guard (200...299).contains(status) else { throw PushFailure.http(status) }
        return data
    }

    private func send(method: String, body: Data?, headers: [String: String]) throws -> (Int, Data) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        session.dataTask(with: request) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        guard let r = result else { throw PushFailure.transport }
        guard r.1.count <= 16 * 1024 else { throw PushFailure.badAcknowledgement }
        return r
    }

    // Přesměrování nikdy nenásledovat.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
