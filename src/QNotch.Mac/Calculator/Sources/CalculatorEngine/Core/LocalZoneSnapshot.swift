import Foundation

/// Immutable host-local rules plus a version that changes whenever those rules do (result caches compare it).
final class LocalZoneSnapshot {
    let version: String
    let rules: ZoneRules
    init(_ zone: ZoneRules, version: String) throws {
        if version.netTrim.isEmpty { throw CalcError.argument("The value cannot be an empty string or composed entirely of whitespace. (Parameter 'version')") }
        self.version = version; rules = zone
    }

    /// The host's zone. Mac counterpart of C#'s FromTimeZoneInfo, which converts the host's own TimeZoneInfo rules
    /// (BclDateTimeZone) and versions them "TimeZoneInfo:<id>:<SHA-256 of TimeZoneInfo.ToSerializedString()>".
    /// Deliberate platform difference: on the Mac only the host's IANA identifier is read; the rules come from the
    /// embedded TZDB (the same NodaTime data the named zones use), never from Foundation's database.
    static func host(_ zone: TimeZone = .current) -> LocalZoneSnapshot {
        fromIdentifier(zone.identifier, currentOffsetSeconds: zone.secondsFromGMT())
    }

    /// The snapshot for an IANA identifier. A known id gets the embedded rules and the version
    /// "TimeZone:<id>:<SHA-256 hex of "<TZDB version id>\n<id>">", which changes exactly when the rules for the id can.
    /// An id the embedded TZDB does not know (a newer host database, a custom zone) falls back to a fixed zone at
    /// the host's current offset, with the version "TimeZone:<id>:not in <TZDB version id>; fixed <zone id>", so
    /// explanations say plainly that no daylight-saving rules apply; the version changes with the host's offset.
    static func fromIdentifier(_ id: String, currentOffsetSeconds: Int, provider: TimeZoneProvider = Tzdb.provider) -> LocalZoneSnapshot {
        if let rules = provider.zone(id) {
            return try! LocalZoneSnapshot(rules, version: "TimeZone:" + id + ":" + FunctionLibrary.hash(provider.versionId + "\n" + id))
        }
        let fixed = FixedZone(offset: currentOffsetSeconds)
        return try! LocalZoneSnapshot(fixed, version: "TimeZone:" + id + ":not in " + provider.versionId + "; fixed " + fixed.id)
    }
}
