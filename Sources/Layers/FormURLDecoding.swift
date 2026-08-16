import Foundation

/// The one query-decoding rule every Layers SDK implements.
///
/// URL query components are `application/x-www-form-urlencoded`. Ad platforms
/// emit `utm_campaign=running+shoes` meaning "running shoes", so:
///
///  - `+`   decodes to a space
///  - `%XX` decodes to the byte 0xXX (then UTF-8)
///  - it is ONE pass: neither output feeds the other, so `%2B` decodes to a
///    literal `+` and stops there
///
/// The rule applies to the QUERY component only. Path and fragment are
/// RFC 3986, where `+` is an ordinary character with no special meaning.
///
/// Foundation has no primitive with these semantics. `URLComponents.queryItems`
/// percent-decodes but leaves `+` alone, and `String.removingPercentEncoding`
/// is RFC 3986 percent-decoding only — correct for a path, wrong for a query.
/// So the decode is spelled out here, working from
/// `URLComponents.percentEncodedQueryItems` (the raw, still-encoded items).
enum FormURLDecoding {

    /// Decode one form-urlencoded token from a query component.
    ///
    /// The order below is load-bearing. `+` is swapped for its own escape on
    /// the STILL-ENCODED token, so percent-decoding runs exactly once over the
    /// result. Percent-decoding first and then swapping `+` for a space would
    /// turn `%2B` into a space — a double decode that silently corrupts every
    /// campaign name containing a real plus sign.
    ///
    /// Never fails: a malformed escape (`%ZZ`, a trailing `%`) makes
    /// `removingPercentEncoding` return nil, in which case the raw token is
    /// returned unchanged rather than the value being lost.
    static func decodeComponent(_ encoded: String) -> String {
        let plusAsSpace = encoded.replacingOccurrences(of: "+", with: "%20")
        return plusAsSpace.removingPercentEncoding ?? encoded
    }

    /// Decode the query component of `url` into key/value pairs.
    ///
    /// A parameter with no `=` maps to `""`, matching `URLSearchParams` and
    /// Android's `Uri.getQueryParameter`. On duplicate keys the LAST
    /// occurrence wins, preserving the behaviour this SDK has always had via
    /// `queryItems.reduce`.
    static func queryParameters(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else { return [:] }
        return items.reduce(into: [String: String]()) { result, item in
            result[decodeComponent(item.name)] = decodeComponent(item.value ?? "")
        }
    }
}
