import Foundation

/// Napodobuje `java.lang.Double.toString`: Android jím zapisuje čísla do kanonického JSON,
/// a z kanonického JSON se počítá `batchId`. Jiný zápis by dal jiný `batchId` pro stejná data.
public enum JavaDouble {
    public struct NonFinite: Error, Equatable {}

    public static func checked(_ d: Double) throws -> String {
        guard d.isFinite else { throw NonFinite() }
        return string(d)
    }

    public static func string(_ d: Double) -> String {
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let sign = d < 0 ? "-" : ""
        let (digits, pointPos) = decimalDigits(abs(d))
        let sciExp = pointPos - 1
        if sciExp >= -3 && sciExp < 7 {
            if pointPos <= 0 {
                return sign + "0." + String(repeating: "0", count: -pointPos) + digits
            }
            if pointPos >= digits.count {
                return sign + digits + String(repeating: "0", count: pointPos - digits.count) + ".0"
            }
            let i = digits.index(digits.startIndex, offsetBy: pointPos)
            return sign + digits[..<i] + "." + digits[i...]
        }
        let first = digits.prefix(1)
        let rest = digits.dropFirst()
        return sign + first + "." + (rest.isEmpty ? "0" : String(rest)) + "E" + String(sciExp)
    }

    /// Nejkratší desetinné číslice a pozice desetinné čárky (počet číslic před ní) ze Swiftova `description`.
    private static func decimalDigits(_ d: Double) -> (digits: String, pointPos: Int) {
        let text = d.description
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exponent = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = intPart + fracPart
        var pointPos = intPart.count + exponent
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            pointPos -= 1
        }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        return (digits, pointPos)
    }
}
