import Foundation
import OpenClickyKit

// A separate process using the real ledger, with no accounts or model calls.
let args = CommandLine.arguments
let directory = URL(fileURLWithPath: args[1], isDirectory: true)
let writer = args[2]
let count = Int(args[3])!
let barrier = URL(fileURLWithPath: args[4])
let now = Date(timeIntervalSince1970: Double(args[5])!)
let ledger = UsageLedger(directory: directory, now: { now })
try Data().write(to: barrier.deletingLastPathComponent().appendingPathComponent("ready-\(writer)"))
let deadline = Date().addingTimeInterval(30)
while !FileManager.default.fileExists(atPath: barrier.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
for index in 0..<count {
    ledger.record(UsageRecord(at: now, slot: "brain", surface: "fixture", provider: "fixture", model: "fixture",
                              turn: "\(writer)-\(index)", client: writer, measure: UsageMeasure(inputTokens: 1), costUSD: 1))
}
