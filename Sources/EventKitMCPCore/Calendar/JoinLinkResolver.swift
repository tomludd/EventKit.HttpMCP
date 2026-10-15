import Foundation

/// Finds an online-meeting join URL (Teams, Zoom, Google Meet, Webex, …) in an event's url, location or notes.
public enum JoinLinkResolver {
    private static let urlChars = #"[\w\-._~:/?#\[\]@!$&'()*+,;=%]+"#

    private static let patterns: [NSRegularExpression] = [
        #"https://teams(?:\.live)?\.microsoft\.com/(?:l/meetup-join|meet)/"# + urlChars,
        #"https://(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/"# + urlChars,
        #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[\w\-._~=&%]*)?"#,
        #"https://[\w-]+\.webex\.com/"# + urlChars,
        #"https://(?:[\w-]+\.)?whereby\.com/[\w\-]+"#,
        #"https://facetime\.apple\.com/join"# + urlChars,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func resolve(url: String?, location: String?, notes: String?) -> String? {
        for text in [url, location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let match = firstMatch(in: text) { return match }
            // Outlook wraps links in safelinks (…safelinks.protection.outlook.com/?url=<encoded>).
            if text.localizedCaseInsensitiveContains("safelinks"), let decoded = text.removingPercentEncoding,
               let match = firstMatch(in: decoded) {
                return match
            }
        }
        return nil
    }

    private static func firstMatch(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        var best: (location: Int, value: String)?
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, range: range),
                  let swiftRange = Range(match.range, in: text) else { continue }
            if best == nil || match.range.location < best!.location {
                best = (match.range.location, String(text[swiftRange]))
            }
        }
        guard var value = best?.value else { return nil }
        while let last = value.last, ".,;)]'".contains(last) { value.removeLast() }
        return value
    }
}
