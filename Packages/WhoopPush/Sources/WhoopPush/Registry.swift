import Foundation

/// Registr proudů protokolu v1. Pořadí sloupců je pořadí z PUSH_PROTOCOL.md; Android exportuje vždy všechny.
public struct StreamSpec {
    public enum Delivery { case append, replaceWindow }
    public enum Selector: String { case day, startTs }
    public let name: String
    public let delivery: Delivery
    public let selector: Selector?
    public let keyColumns: [String]
    public let dataColumns: [String]
}

public enum Registry {
    public static let all: [StreamSpec] = [
        append("hrSample", ["ts"], ["bpm"]),
        append("rrInterval", ["ts", "rrMs", "seq"], ["ord", "srcChannel", "tsSuspect"]),
        append("event", ["ts", "kind"], ["payloadJSON"]),
        append("battery", ["ts"], ["soc", "mv", "charging"]),
        append("spo2Sample", ["ts"], ["red", "ir"]),
        append("skinTempSample", ["ts"], ["raw", "aux1Raw", "aux2Raw"]),
        append("respSample", ["ts"], ["raw"]),
        append("gravitySample", ["ts"], ["x", "y", "z", "dynAccel"]),
        replace("dailyMetric", .day, ["day"], ["totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances", "restingHr", "avgHrv",
                                               "recovery", "strain", "exerciseCount", "spo2Pct", "skinTempDevC", "respRateBpm", "steps",
                                               "activeKcalEst", "spo2Red", "spo2Ir"]),
        replace("sleepSession", .startTs, ["startTs"], ["endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited", "startTsAdjusted",
                                                        "motionJSON", "sleepStateJSON", "stagingSparse"]),
        replace("workout", .startTs, ["startTs", "sport"], ["endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain", "distanceM",
                                                           "zonesJSON", "notes", "routePolyline", "steps"]),
        replace("journal", .day, ["day", "question"], ["answeredYes", "notes", "numericValue"]),
    ]

    public static func spec(_ name: String) -> StreamSpec? { all.first { $0.name == name } }
    public static var streamNames: [String] { all.map { $0.name } }

    private static func append(_ n: String, _ k: [String], _ d: [String]) -> StreamSpec {
        StreamSpec(name: n, delivery: .append, selector: nil, keyColumns: k, dataColumns: d)
    }

    private static func replace(_ n: String, _ s: StreamSpec.Selector, _ k: [String], _ d: [String]) -> StreamSpec {
        StreamSpec(name: n, delivery: .replaceWindow, selector: s, keyColumns: k, dataColumns: d)
    }
}
