//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import struct SPMBuildCore.BuildSystemProvider
import enum PackageModel.BuildConfiguration

/// The build systems exercised by parameterized tests.
///
/// By default this is every supported build system except Xcode's. On Windows
/// the default is narrowed to just the default (`swiftbuild`) build system:
/// running the full end-to-end command/functional suites against multiple build
/// systems dominates Windows CI wall-clock time, because each parameterized case
/// spawns a complete package build per build system.
///
/// Override with the `SWIFTPM_TEST_BUILD_SYSTEMS` environment variable -- a
/// comma-separated list of build-system names (e.g. `swiftbuild` or
/// `native,swiftbuild`). Unknown names are ignored and `xcode` is never
/// included. This lets CI or local runs A/B the cost of the build-system matrix
/// without a code change.
public var SupportedBuildSystemOnAllPlatforms: [BuildSystemProvider.Kind] {
    if let overridden = buildSystemsFromEnvironment {
        return overridden
    }
    #if os(Windows)
    return [.swiftbuild]
    #else
    return BuildSystemProvider.Kind.allCases.filter { $0 != .xcode }
    #endif
}

/// Parses `SWIFTPM_TEST_BUILD_SYSTEMS` into a list of build systems, or `nil`
/// when the variable is unset or yields no valid entries (callers then fall back
/// to the platform default).
private var buildSystemsFromEnvironment: [BuildSystemProvider.Kind]? {
    guard let raw = ProcessInfo.processInfo.environment["SWIFTPM_TEST_BUILD_SYSTEMS"] else {
        return nil
    }
    let kinds = raw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .compactMap { BuildSystemProvider.Kind(rawValue: $0) }
        .filter { $0 != .xcode }
    return kinds.isEmpty ? nil : kinds
}

public struct BuildData {
    public let buildSystem: BuildSystemProvider.Kind
    public let config: BuildConfiguration

    public init(
        buildSystem: BuildSystemProvider.Kind,
        config: BuildConfiguration,
    ) {
        self.buildSystem = buildSystem
        self.config = config
    }
}

public func getBuildData(for buildSystems: [BuildSystemProvider.Kind]) -> [BuildData] {
    buildSystems.flatMap { buildSystem in
        BuildConfiguration.allCases.compactMap { config in
            return BuildData(
                buildSystem: buildSystem,
                config: config,
            )
        }
    }
}
