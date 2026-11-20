import Foundation

/// Kategorie chyb. Nikdy nenese volný text (tělo odpovědi, výjimky, adresy), aby se do stavu nedostala zdravotní data ani tajemství.
public enum PushFailure: Error, Equatable {
    case transport
    case http(Int)
    case badAcknowledgement
    case invalidCapabilities
    case encoding
    case cursor
    case disabled

    /// Opakuje se jen přechodné: síť, 408, 429 a 5xx. Zbytek je chyba nastavení nebo protokolu.
    public var retryable: Bool {
        switch self {
        case .transport: return true
        case let .http(status): return status == 408 || status == 429 || (500...599).contains(status)
        case .badAcknowledgement, .invalidCapabilities, .encoding, .cursor, .disabled: return false
        }
    }

    public var safeCode: String {
        switch self {
        case .transport: return "transport"
        case let .http(s): return "http_\(s)"
        case .badAcknowledgement: return "bad_acknowledgement"
        case .invalidCapabilities: return "invalid_capabilities"
        case .encoding: return "encoding"
        case .cursor: return "cursor"
        case .disabled: return "disabled"
        }
    }
}
