import Foundation
import Security
import WhoopPush
import WhoopPushStore
import WhoopStore

// MARK: - Settings

/// Nastavení jednosměrného odesílání na vlastní přijímač (Experimental, ve výchozím stavu vypnuto).
/// Protokol: docs/PUSH_PROTOCOL.md v1. Token je v Keychainu, ostatní v UserDefaults.
enum SelfHostedPushSettings {
    private static let enabledKey = "selfHostedPush.enabled"
    private static let endpointKey = "selfHostedPush.endpoint"
    private static let wifiOnlyKey = "selfHostedPush.wifiOnly"
    private static let sourceIdKey = "selfHostedPush.sourceId"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: endpointKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey) }
    }

    /// Výchozí je jen Wi-Fi.
    static var wifiOnly: Bool {
        get { UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: wifiOnlyKey) }
    }

    /// Náhodné UUID této instalace (není to účet). Po přeinstalaci vznikne nové a odesílá se od začátku.
    static var sourceId: String {
        if let id = UserDefaults.standard.string(forKey: sourceIdKey), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: sourceIdKey)
        return id
    }
}

// MARK: - Token (Keychain)

enum PushTokenStore {
    private static let service = "com.noop.selfhostedpush"
    private static let account = "bearer-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let str = String(data: data, encoding: .utf8), !str.isEmpty else { return nil }
        return str
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    static var hasToken: Bool { read() != nil }
}

// MARK: - Runner

/// Spouští odesílání mimo synchronizaci s páskem: selhání ani pomalý server nikdy nezdrží stahování z pásku,
/// zápis, analýzu ani UI. Souběžné spouštěče se sloučí do jednoho běhu.
@MainActor
final class SelfHostedPush: ObservableObject {
    static let shared = SelfHostedPush()

    enum Status: Equatable {
        case idle
        case running
        case succeeded(Date)
        /// Jen bezpečný kód kategorie (`PushFailure.safeCode`), nikdy text odpovědi ani adresa.
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    private var running = false
    private var rerun = false
    private static let retryDelaysSeconds: [UInt64] = [30, 120, 600]

    /// Spustí odesílání, pokud je zapnuté. Volat po dokončeném stahování, při startu a z „Export now“.
    func trigger(store: WhoopStore) {
        guard SelfHostedPushSettings.enabled else { return }
        if running { rerun = true; return }
        running = true
        status = .running
        Task { [weak self] in
            var attempt = 0
            while true {
                let outcome = await Task.detached(priority: .utility) { Self.execute(store: store) }.value
                guard let self else { return }
                switch outcome {
                case .success:
                    if self.rerun { self.rerun = false; attempt = 0; continue }
                    self.status = .succeeded(Date())
                    self.running = false
                    return
                case let .failure(failure):
                    if failure.retryable, attempt < Self.retryDelaysSeconds.count {
                        let delay = Self.retryDelaysSeconds[attempt]
                        attempt += 1
                        self.status = .failed(failure.safeCode)
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        if !SelfHostedPushSettings.enabled { self.running = false; self.status = .idle; return }
                        continue
                    }
                    self.status = .failed(failure.safeCode)
                    self.running = false
                    return
                }
            }
        }
    }

    /// Jen autentizovaný GET na capabilities. Nečte databázi a neposílá žádnou dávku.
    func testConnection() async -> Status {
        let result: Result<Void, PushFailure> = await Task.detached(priority: .utility) {
            do {
                let transport = try Self.makeTransport()
                _ = try transport.capabilities()
                return .success(())
            } catch let f as PushFailure { return .failure(f) } catch { return .failure(.transport) }
        }.value
        switch result {
        case .success: return .succeeded(Date())
        case let .failure(f): return .failed(f.safeCode)
        }
    }

    // MARK: Vlastní běh (mimo hlavní vlákno)

    private nonisolated static func makeTransport() throws -> URLSessionPushTransport {
        guard SelfHostedPushSettings.enabled || !SelfHostedPushSettings.endpoint.isEmpty else { throw PushFailure.disabled }
        guard let url = try? EndpointPolicy.validate(SelfHostedPushSettings.endpoint) else { throw PushFailure.disabled }
        guard let token = PushTokenStore.read() else { throw PushFailure.disabled }
        return URLSessionPushTransport(endpoint: url, token: token, wifiOnly: SelfHostedPushSettings.wifiOnly)
    }

    private nonisolated static func execute(store: WhoopStore) -> Result<Void, PushFailure> {
        do {
            let transport = try makeTransport()
            let caps = try transport.capabilities()
            let namespace = PushNamespace.make(
                sourceId: SelfHostedPushSettings.sourceId,
                endpoint: SelfHostedPushSettings.endpoint,
                version: PushIdentity.version,
                receiverStateId: caps.receiverStateId
            )
            let coordinator = PushCoordinator(
                source: GRDBPushSource(reader: store.registryWriter),
                transport: transport,
                progress: UserDefaultsPushProgress(namespace: namespace),
                sourceId: SelfHostedPushSettings.sourceId
            )
            // Jedna stránka na proud a zařízení na průchod; dokud zbývají další řádky, pokračujeme (s pojistkou).
            for _ in 0..<50 {
                let report = try coordinator.runOnce(advertised: caps.streams)
                if !report.moreWork { break }
            }
            return .success(())
        } catch let failure as PushFailure {
            return .failure(failure)
        } catch {
            return .failure(.encoding)
        }
    }
}
