import Foundation
import GRDB
import WhoopPush

/// Čtení dat z databáze NOOPu pro odesílání. Projekce sloupců jsou explicitní podle `Registry`
/// (nikdy `SELECT *`, nikdy reflexe), takže tabulka, která v protokolu není, se neodešle.
/// Chybějící sloupec v tomto schématu (např. `workout.routePolyline`, který má jen Android) se posílá jako `null`.
public final class GRDBPushSource: PushDataSource {
    public enum ReadError: Error, Equatable { case unknownStream(String), unsupportedValue(String) }

    private static let booleanColumns: Set<String> = ["charging", "userEdited", "stagingSparse", "answeredYes"]
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) { self.reader = reader }

    public func deviceIds() throws -> [String] {
        try reader.read { db in
            var parts = ["SELECT id AS deviceId FROM device WHERE id <> ''"]
            for spec in Registry.all where try db.tableExists(spec.name) {
                parts.append("SELECT deviceId FROM \"\(spec.name)\" WHERE deviceId <> ''")
            }
            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " UNION ") + " ORDER BY deviceId")
            return rows.map { $0["deviceId"] as String }
        }
    }

    public func appendRecords(stream: String, deviceId: String, afterRowId: Int64?, limit: Int) throws -> [AppendRecord] {
        let spec = try append(stream)
        return try reader.read { db in
            let cols = try Self.selectList(db, spec)
            let sql = "SELECT rowid AS _pushRowId, \(cols) FROM \"\(spec.name)\" WHERE deviceId = ? AND rowid > ? ORDER BY rowid ASC LIMIT ?"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId ?? 0, limit])
            return try rows.map { row in
                AppendRecord(rowId: row["_pushRowId"] as Int64, key: try Self.values(row, spec.keyColumns), data: try Self.values(row, spec.dataColumns))
            }
        }
    }

    public func appendRecordKey(stream: String, deviceId: String, rowId: Int64) throws -> [(String, JSONValue)]? {
        let spec = try append(stream)
        return try reader.read { db in
            let keyCols = spec.keyColumns.map { "\"\($0)\"" }.joined(separator: ", ")
            let sql = "SELECT \(keyCols) FROM \"\(spec.name)\" WHERE deviceId = ? AND rowid = ?"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
            return try Self.values(row, spec.keyColumns)
        }
    }

    public func mutableRecords(stream: String, deviceId: String, window: SelectorWindow) throws -> [MutableRecord] {
        guard let spec = Registry.spec(stream), spec.delivery == .replaceWindow else { throw ReadError.unknownStream(stream) }
        return try reader.read { db in
            let cols = try Self.selectList(db, spec)
            let order = spec.keyColumns.map { "\"\($0)\"" }.joined(separator: ", ")
            let condition: String
            let args: StatementArguments
            switch window {
            case let .day(from, to):
                condition = "day >= ? AND day <= ?"
                args = [deviceId, from, to]
            case let .startTs(from, toExclusive):
                condition = "startTs >= ? AND startTs < ?"
                args = [deviceId, from, toExclusive]
            }
            let sql = "SELECT \(cols) FROM \"\(spec.name)\" WHERE deviceId = ? AND \(condition) ORDER BY \(order)"
            return try Row.fetchAll(db, sql: sql, arguments: args).map { row in
                MutableRecord(key: try Self.values(row, spec.keyColumns), data: try Self.values(row, spec.dataColumns))
            }
        }
    }

    // MARK: - Pomocné

    private func append(_ stream: String) throws -> StreamSpec {
        guard let spec = Registry.spec(stream), spec.delivery == .append else { throw ReadError.unknownStream(stream) }
        return spec
    }

    private static func selectList(_ db: Database, _ spec: StreamSpec) throws -> String {
        let existing = Set(try db.columns(in: spec.name).map { $0.name })
        return (spec.keyColumns + spec.dataColumns).map { existing.contains($0) ? "\"\($0)\"" : "NULL AS \"\($0)\"" }.joined(separator: ", ")
    }

    private static func values(_ row: Row, _ names: [String]) throws -> [(String, JSONValue)] {
        try names.map { name in
            let value: DatabaseValue = row[name]
            switch value.storage {
            case .null: return (name, .null)
            case let .int64(i): return (name, booleanColumns.contains(name) ? .bool(i != 0) : .int(i))
            case let .double(d): return (name, .double(d))
            case let .string(s): return (name, .string(s))
            case .blob: throw ReadError.unsupportedValue(name)
            }
        }
    }
}
