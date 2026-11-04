import Foundation

/// Keeps credentials out of memory. Everything bound for the memory folder (tool saves, the session writer's diff,
/// Settings and `occtl` input) and everything rendered from it into a prompt passes through here.
///
/// It replaces what looks like a secret with `[redacted]`: provider key and token formats, JWTs, private-key
/// blocks, bearer credentials, passwords in URLs, values given for words like "password" or "API key", payment
/// card numbers (Luhn-checked), US social security numbers, and long random-looking strings. It errs toward
/// redacting: losing a word of a memory is cheap, keeping a key is not.
public enum MemorySecretScrubber {
    public static let marker = "[redacted]"

    public struct Result: Sendable, Hashable {
        public var text: String
        public var redactions: Int
    }

    public static func scrub(_ text: String) -> Result {
        var output = text
        var count = 0

        // Whole-match patterns, most specific first.
        for pattern in wholeMatchPatterns {
            count += replace(pattern, in: &output) { _, _ in marker }
        }
        // Keep the label, redact the value.
        count += replace(authorizationPattern, in: &output) { match, text in
            text.substring(with: match.range(at: 1)) + " " + marker
        }
        count += replace(urlCredentialPattern, in: &output) { match, text in
            text.substring(with: match.range(at: 1)) + marker + "@"
        }
        // A password can be a passphrase with spaces: after a password-like name, hide the quoted value or
        // everything to the end of the clause.
        count += replace(passphrasePattern, in: &output) { match, text in
            let value = text.substring(with: match.range(at: 3))
            if value.contains(marker) { return text.substring(with: match.range) }
            return text.substring(with: match.range(at: 1)) + text.substring(with: match.range(at: 2)) + marker
        }
        count += replace(labeledSecretPattern, in: &output) { match, text in
            let whole = text.substring(with: match.range)
            let name = text.substring(with: match.range(at: 1)).lowercased()
            let separator = text.substring(with: match.range(at: 2))
            let value = text.substring(with: match.range(at: 3))
            if value.contains(marker) { return whole }
            // "password: x" and "token=x" always hide x. With "is"/"was", a plain word is only taken for a secret
            // after a password-like name ("the password is swordfish", but not "the token is expired").
            let explicit = separator.contains(":") || separator.contains("=") || separator.contains(">")
            let plainWord = value.allSatisfy(\.isLetter)
            let passwordLike = ["password", "passwd", "passcode", "passphrase", "pwd"].contains { name.contains($0) }
            if !explicit, plainWord, !passwordLike { return whole }
            return text.substring(with: match.range(at: 1)) + separator + marker
        }
        count += replace(cardPattern, in: &output) { match, text in
            let candidate = text.substring(with: match.range)
            return luhnValid(candidate) ? marker : candidate
        }
        count += replace(randomTokenPattern, in: &output) { match, text in
            let candidate = text.substring(with: match.range)
            return looksRandom(candidate) ? marker : candidate
        }
        return Result(text: output, redactions: count)
    }

    public static func containsSecret(_ text: String) -> Bool { scrub(text).redactions > 0 }

    /// True when, once its secrets are gone, `text` says too little to be worth keeping ("my token is [redacted]").
    public static func isMostlySecret(_ text: String) -> Bool {
        let result = scrub(text)
        guard result.redactions > 0 else { return false }
        let remaining = result.text.replacingOccurrences(of: marker, with: " ")
        let meaningful = MemoryRanker.terms(remaining).filter { !secretWords.contains($0) }
        return meaningful.count < 3
    }

    // MARK: - Patterns

    private static let wholeMatchPatterns: [NSRegularExpression] = [
        // PEM private keys (any kind).
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
        // OpenAI / Anthropic style keys: sk-…, sk-proj-…, sk-ant-….
        #"\bsk-[A-Za-z0-9_\-]{16,}"#,
        // Stripe-style keys.
        #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{12,}"#,
        // GitHub tokens.
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        // GitLab, Slack, Hugging Face, npm, Google OAuth access tokens.
        #"\bglpat-[A-Za-z0-9_\-]{16,}"#,
        #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"\bhf_[A-Za-z0-9]{20,}"#,
        #"\bnpm_[A-Za-z0-9]{20,}"#,
        #"\bya29\.[A-Za-z0-9_\-]{20,}"#,
        // Google API keys.
        #"\bAIza[0-9A-Za-z_\-]{30,}"#,
        // AWS access key ids.
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        // JSON Web Tokens.
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        // US social security numbers.
        #"\b\d{3}-\d{2}-\d{4}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// `Bearer abc…` / `Basic abc…`: group 1 is the scheme.
    private static let authorizationPattern = try! NSRegularExpression(
        pattern: #"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=\-]{12,}"#, options: [.caseInsensitive])

    /// `scheme://user:password@`: group 1 is the scheme.
    private static let urlCredentialPattern = try! NSRegularExpression(
        pattern: #"\b([a-z][a-z0-9+.\-]*://)[^\s:/@]+:[^\s@/]+@"#, options: [.caseInsensitive])

    /// Words that name a secret.
    private static let secretWords: Set<String> = [
        "password", "passwords", "passwd", "passcode", "passphrase", "pwd", "pin", "key", "api", "apikey", "token",
        "secret", "otp", "code", "cvv", "cvc", "credential", "credentials", "login",
    ]

    /// A secret's name, then `is` / `:` / `=` and the value. Group 1 is the name, group 2 the separator, group 3 the value.
    private static let labeledSecretPattern = try! NSRegularExpression(
        pattern: #"\b((?:wi-?fi\s+)?(?:password|passwd|passcode|passphrase|pwd|pin(?:\s+code)?|api[\s_\-]?key|access[\s_\-]?key|secret(?:[\s_\-]?key)?|client[\s_\-]?secret|(?:auth|access|refresh|bearer|api)[\s_\-]?token|token|private[\s_\-]?key|recovery\s+code|security\s+code|verification\s+code|one[\s\-]time\s+(?:code|password)|2fa\s+code|otp|cvv|cvc))(\s*(?:[:=]|->)\s*|\s+(?:is|was|are)\s+(?:set\s+to\s+|now\s+|still\s+)?(?:[:=]\s*)?)(["'`]?[^\s"'`,;]{3,}["'`]?)"#,
        options: [.caseInsensitive])

    /// A password-like name, `is` / `:` / `=`, then a quoted value or the rest of the clause (up to `.`, `,`, `;`, `!`,
    /// `?` or the end of the line). Group 1 is the name, group 2 the separator, group 3 the value.
    private static let passphrasePattern = try! NSRegularExpression(
        pattern: #"\b((?:wi-?fi\s+)?(?:password|passwd|passcode|passphrase|pwd))(\s*(?:[:=]|->)\s*|\s+(?:is|was)\s+(?:set\s+to\s+|now\s+|still\s+)?(?:[:=]\s*)?)("[^"\n]{3,}"|'[^'\n]{3,}'|“[^”\n]{3,}”|`[^`\n]{3,}`|[^\s"'“`.,;!?][^\n.,;!?]{2,})"#,
        options: [.caseInsensitive])

    /// 13–19 digits with optional single spaces or dashes between them.
    private static let cardPattern = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){12,18}\d\b"#)

    /// Long runs of key-like characters.
    private static let randomTokenPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_\-=]{24,}"#)

    // MARK: - Helpers

    private static func replace(_ pattern: NSRegularExpression, in text: inout String,
                                with replacement: (NSTextCheckingResult, NSString) -> String) -> Int {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return 0 }
        let output = NSMutableString(string: ns)
        var changed = 0
        for match in matches.reversed() {
            let new = replacement(match, ns)
            if new != ns.substring(with: match.range) {
                output.replaceCharacters(in: match.range, with: new)
                changed += 1
            }
        }
        text = output as String
        return changed
    }

    static func luhnValid(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// A long token with letters and digits, high character entropy, that isn't just words joined by `-`, `_` or `/`
    /// (slugs, package names, file paths like `Documents/Exports2026/Q3`).
    static func looksRandom(_ token: String) -> Bool {
        let hasDigit = token.contains(where: \.isNumber)
        let hasLetter = token.contains(where: \.isLetter)
        guard hasDigit, hasLetter else { return false }
        let segments = token.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "/" })
        if !segments.isEmpty, segments.allSatisfy(isWordLike) { return false }
        return entropy(token) >= 3.5
    }

    /// A word with at most a short number after it ("Exports2026", "v2"), a short number, or any piece of three
    /// characters or fewer.
    private static func isWordLike(_ segment: Substring) -> Bool {
        if segment.count <= 3 { return true }
        let letters = segment.prefix(while: \.isLetter)
        let rest = segment.dropFirst(letters.count)
        return letters.count <= 24 && rest.count <= 4 && rest.allSatisfy(\.isNumber)
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}
