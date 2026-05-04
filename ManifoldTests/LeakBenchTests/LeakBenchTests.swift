// Manifold — visualizes physical USB and Thunderbolt connections live.
// Copyright (C) 2026 Brandon Villar
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// ─────────────────────────────────────────────────────────────────────
// LeakBenchTests.swift
//
// F7 closure (Phase 1 review, due Phase 16): replaces the
// Reviewer-deferred §18.0 LEAK-100x procedure for IOKit-touching
// phases (1, 3, 5, 7) with a per-PR XCTest assertion. Cycles
// `DiscoveryService.walk()` 100× through the full IOKit pipeline,
// then invokes `leaks(1)` against the test process pid and
// asserts zero leaked bytes.
//
// `leaks(1)` is gated behind `MallocStackLogging` for symbol-rich
// output, but for a binary "did anything leak" check we just need
// the exit status + the "X leaks for Y total leaked bytes" parse.
// On a clean run the line reads "0 leaks for 0 total leaked bytes".

import XCTest
import Foundation
@testable import Manifold

@MainActor
final class LeakBenchTests: XCTestCase {

    /// Number of walk cycles per the SPEC §18.0 LEAK-100x procedure.
    /// 100 is the SPEC-pinned bound; raising it past ~1000 in CI
    /// would push the runtime into 10s of seconds without changing
    /// the signal.
    static let walkCycles = 100

    /// Run `walkCycles` discovery walks then assert `leaks(1)`
    /// reports zero leaked bytes against this test process. Skips
    /// when `MANIFOLD_SKIP_LEAK_BENCH` is set in the environment
    /// (lets a developer iterating on unrelated tests trim a few
    /// seconds off `xcodebuild test`).
    func test_discoveryWalk_100x_zeroLeaks() async throws {
        if ProcessInfo.processInfo.environment["MANIFOLD_SKIP_LEAK_BENCH"] != nil {
            throw XCTSkip("Skipped via MANIFOLD_SKIP_LEAK_BENCH=1")
        }

        let service = DiscoveryService()
        for _ in 0..<Self.walkCycles {
            _ = try? await service.walk()
        }

        // Run leaks(1) against the test process pid. The output
        // we care about is one line: "Process N: X leaks for Y
        // total leaked bytes".
        let pid = ProcessInfo.processInfo.processIdentifier
        let result = try runLeaks(pid: pid)

        // Parse the trailing summary line. `leaks` writes a few
        // header lines + the malloc count + the leak summary;
        // `endsWith` against a regex would be brittle so grep the
        // line containing "leaks for".
        guard let summaryLine = result.stdout
            .components(separatedBy: "\n")
            .first(where: { $0.contains("leaks for") }) else {
            XCTFail("leaks(1) output did not contain a summary line:\n\(result.stdout)")
            return
        }

        // "Process 12345: 0 leaks for 0 total leaked bytes." → match
        // " 0 leaks for 0 total leaked bytes".
        XCTAssertTrue(
            summaryLine.contains("0 leaks for 0 total leaked bytes"),
            "Expected zero-leak summary; got: \(summaryLine)"
        )
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Spawn `/usr/bin/leaks` against `pid` synchronously and
    /// collect stdout/stderr. `leaks` exits 0 on success (zero
    /// leaks) and non-zero when leaks are detected. We assert on
    /// the parsed summary line, not the exit code, because some
    /// macOS versions return 0 even with leaks present (relying
    /// on the human-parseable output to flag the count).
    private func runLeaks(pid: Int32) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = ["\(pid)"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
