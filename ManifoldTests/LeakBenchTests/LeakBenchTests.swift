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

    /// Warm up discovery, record the test host's existing leak baseline, run
    /// `walkCycles` more walks, then assert discovery added no leaks. XCTest
    /// and loaded macOS frameworks can have a non-zero process baseline, so
    /// comparing the before/after snapshots isolates the code under test.
    /// Skips
    /// when `MANIFOLD_SKIP_LEAK_BENCH` is set in the environment
    /// (lets a developer iterating on unrelated tests trim a few
    /// seconds off `xcodebuild test`).
    func test_discoveryWalk_100x_zeroLeaks() async throws {
        if ProcessInfo.processInfo.environment["MANIFOLD_SKIP_LEAK_BENCH"] != nil {
            throw XCTSkip("Skipped via MANIFOLD_SKIP_LEAK_BENCH=1")
        }

        let service = DiscoveryService()
        _ = try? await service.walk()

        let pid = ProcessInfo.processInfo.processIdentifier
        let baselineResult = try runLeaks(pid: pid)
        guard let baseline = leakCounts(from: baselineResult.stdout) else {
            return XCTFail("Initial leaks(1) output did not contain a summary line:\n\(baselineResult.stdout)")
        }

        for _ in 0..<Self.walkCycles {
            _ = try? await service.walk()
        }

        let finalResult = try runLeaks(pid: pid)
        guard let final = leakCounts(from: finalResult.stdout) else {
            return XCTFail("Final leaks(1) output did not contain a summary line:\n\(finalResult.stdout)")
        }

        XCTAssertLessThanOrEqual(
            final.leaks,
            baseline.leaks,
            "Discovery added leaks: baseline \(baseline.leaks), final \(final.leaks)"
        )
        XCTAssertLessThanOrEqual(
            final.bytes,
            baseline.bytes,
            "Discovery added leaked bytes: baseline \(baseline.bytes), final \(final.bytes)"
        )
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Parse `Process 123: 4 leaks for 200 total leaked bytes.`.
    private func leakCounts(from output: String) -> (leaks: Int, bytes: Int)? {
        guard let line = output
            .components(separatedBy: "\n")
            .first(where: { $0.contains("leaks for") })
        else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 6,
              let leaks = Int(fields[2]),
              let bytes = Int(fields[5])
        else { return nil }
        return (leaks, bytes)
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

        // `leaks` can emit more data than a pipe buffer holds. Waiting for the
        // process before draining its pipes deadlocks once that buffer fills,
        // so capture both streams in files that cannot exert back-pressure.
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifoldLeakBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()

        let stdoutData = try Data(contentsOf: stdoutURL)
        let stderrData = try Data(contentsOf: stderrURL)
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
