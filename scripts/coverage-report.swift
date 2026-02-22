#!/usr/bin/env swift
// Parses the llvm-cov JSON export (from swift test --enable-code-coverage)
// and prints a per-file coverage summary for Sources/App/.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

print(String(format: "Regions: %d/%d = %.1f%%", coveredRegions, totalRegions, regionPct))
print(String(format: "Lines:   %d/%d = %.1f%%", coveredLines, totalLines, linePct))
print()

let sorted = appFiles.sorted { $0.filename < $1.filename }
for file in sorted {
    let name: String
    if let range = file.filename.range(of: "/Sources/App/") {
        name = String(file.filename[range.upperBound...])
    } else {
        name = file.filename
    }
    let pad = String(repeating: " ", count: max(0, 45 - name.count))
    print(String(format: "  %@%@  regions: %5.1f%%  lines: %5.1f%%",
                 name, pad, file.summary.regions.percent, file.summary.lines.percent))
}
