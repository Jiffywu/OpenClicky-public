import Foundation
import Testing
@testable import OpenClicky

/// Settings → Usage reads the limit fields: a decimal comma or thousands separator must not quietly turn a limit off.
@Suite struct UsageLimitAmountTests {
    @Test func decimalCommasAndThousandsSeparatorsAreRead() {
        #expect(UsageLimitAmount("2.50") == .readable(2.5))
        #expect(UsageLimitAmount(" $2.50 ") == .readable(2.5))
        #expect(UsageLimitAmount("2,50") == .readable(2.5))
        #expect(UsageLimitAmount("1,000", groupingSeparator: ",") == .readable(1000))
        #expect(UsageLimitAmount("1.000", groupingSeparator: ".") == .readable(1000))
        #expect(UsageLimitAmount("1,000", groupingSeparator: ".") == .readable(1))
        #expect(UsageLimitAmount("1,000.50") == .readable(1000.5))
        #expect(UsageLimitAmount("1.000,50") == .readable(1000.5))
        #expect(UsageLimitAmount("1\u{00A0}000,50") == .readable(1000.5))
        #expect(UsageLimitAmount("1,000,000") == .readable(1_000_000))
    }

    @Test func emptyMeansNoLimitAndAnythingElseIsRefused() {
        #expect(UsageLimitAmount("") == .readable(nil))
        #expect(UsageLimitAmount("  ") == .readable(nil))
        #expect(UsageLimitAmount("two dollars") == .unreadable)
        #expect(UsageLimitAmount("-5") == .unreadable)
        #expect(UsageLimitAmount("1.000,50,25") == .unreadable)
        #expect(UsageLimitAmount("$") == .readable(nil))
        #expect(UsageLimitAmount(",") == .unreadable)
        #expect(UsageLimitAmount.problem("2x", field: "daily").contains("Nothing was saved"))
    }
}
