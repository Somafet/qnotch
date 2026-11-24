import Foundation

/// One explicit, bounded request for the European Commission's monthly InforEuro accounting rates
/// (one provider, not Frankfurter's blended feed). The URI carries only the provider, base EUR and an optional
/// date; no clock reads, credentials, retries, sheet text or amounts.
final class InforEuroRateClient {
    static let provider = CurrencyRateSnapshot.monthlyEuProvider
    static let source = "https://commission.europa.eu/funding-and-tenders/procedures-guidelines-tenders/information-contractors-and-beneficiaries/exchange-rate-inforeuro_en"
    static let terms = "https://commission.europa.eu/legal-notice_en"
    static let attribution = "Monthly accounting rates © European Union, CC BY 4.0; retrieved through Frankfurter and converted to exact cross rates by QNotch"
    static let firstDate = DateOnly(1994, 3, 1)!
    /// A monthly rate is dated the first day of its month; a later requested day keeps that month's rate.
    static let maximumAgeDays = 62

    private let transport: CurrencyRateTransport
    init(_ transport: CurrencyRateTransport) { self.transport = transport }

    static func requestUri(_ date: DateOnly?) -> URL {
        URL(string: "https://api.frankfurter.dev/v2/providers/INFOREURO/rates?base=EUR" + (date.map { "&date=" + $0.description } ?? ""))!
    }
    func fetch(_ date: DateOnly?, now: Instant, utcOffsetSeconds: Int = 0, token: CancellationToken = .none) async throws -> CurrencyRateSnapshot {
        let today = EcbRateClient.localDate(now, utcOffsetSeconds)
        if let requested = date, requested < InforEuroRateClient.firstDate || requested > today { throw CalcError.invalidData("InforEuro date is outside available bounds") }
        let bytes = try await EcbRateClient.download(transport, InforEuroRateClient.requestUri(date), now, token)
        return try InforEuroRateClient.parse(bytes, date, now, utcOffsetSeconds: utcOffsetSeconds)
    }
    static func parse(_ bytes: Data, _ requested: DateOnly?, _ retrievedAt: Instant, utcOffsetSeconds: Int = 0) throws -> CurrencyRateSnapshot {
        let snapshot = try EcbRateClient.parse(bytes, requested, retrievedAt, utcOffsetSeconds, provider, firstDate, maximumAgeDays)
        if snapshot.asOf.day != 1 { throw CalcError.invalidData("InforEuro rates must be dated the first day of their month") }
        return snapshot
    }
}
