#!/usr/bin/env swift
// Parses the llvm-cov JSON export (from swift test --enable-code-coverage)
// and prints a per-file coverage summary for Sources/App/.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// On Linux, FoundationEssentials replaces Foundation and does not include
// NSString-bridged APIs (String(format:), padding(toLength:), range(of:))
// or C variadic functions (snprintf). These helpers use pure Swift instead.

/// Format a Double to 1 decimal place.
func pct(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    let whole = Int(rounded)
    let frac = Int(((rounded - Double(whole)).magnitude * 10).rounded())
    return "\(whole).\(frac)"
}

/// Right-align a string to the given width.
func rpad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return s }
    return String(repeating: " ", count: width - s.count) + s
}

struct CoverageData: Decodable {
    let data: [CoverageEntry]
}

struct CoverageEntry: Decodable {
    let totals: Summary
    let files: [FileCoverage]
}

struct FileCoverage: Decodable {
    let filename: String
    let summary: Summary
}

struct Summary: Decodable {
    let regions: Metric
    let lines: Metric
}

struct Metric: Decodable {
    let count: Int
    let covered: Int
    let percent: Double
}

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: coverage-report.swift <codecov.json>\n", stderr)
    exit(1)
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let jsonData = try Data(contentsOf: url)
let coverage = try JSONDecoder().decode(CoverageData.self, from: jsonData)

let appFiles = coverage.data[0].files.filter { $0.filename.contains("/Sources/App/") }

let totalRegions = appFiles.reduce(0) { $0 + $1.summary.regions.count }
let coveredRegions = appFiles.reduce(0) { $0 + $1.summary.regions.covered }
let totalLines = appFiles.reduce(0) { $0 + $1.summary.lines.count }
let coveredLines = appFiles.reduce(0) { $0 + $1.summary.lines.covered }

let regionPct = totalRegions > 0 ? Double(coveredRegions) / Double(totalRegions) * 100 : 0
let linePct = totalLines > 0 ? Double(coveredLines) / Double(totalLines) * 100 : 0

print("Regions: \(coveredRegions)/\(totalRegions) = \(pct(regionPct))%")
print("Lines:   \(coveredLines)/\(totalLines) = \(pct(linePct))%")
print()

let sorted = appFiles.sorted { $0.filename < $1.filename }
for file in sorted {
    let marker = "/Sources/App/"
    let name: String
    if let idx = file.filename.firstRange(of: marker)?.upperBound {
        name = String(file.filename[idx...])
    } else {
        name = file.filename
    }
    let pad = String(repeating: " ", count: max(0, 45 - name.count))
    print("  \(name)\(pad)  regions: \(rpad(pct(file.summary.regions.percent), 5))%  lines: \(rpad(pct(file.summary.lines.percent), 5))%")
}
