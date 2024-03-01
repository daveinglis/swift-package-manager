//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import SPMTestSupport
@testable import SPMBuildCore
import XCTest
import PackageModel

final class PluginsBuildPlanTests: XCTestCase {
    func testBuildToolsDatabasePath() throws {
        try fixture(name: "Miscellaneous/Plugins/MySourceGenPlugin") { fixturePath in
            let (stdout, _) = try executeSwiftBuild(fixturePath)
            XCTAssertMatch(stdout, .contains("Build complete!"))
            XCTAssertTrue(localFileSystem.exists(fixturePath.appending(RelativePath(".build/plugins/tools/build.db"))))
        }
    }

    func testCommandPluginDependenciesWhenCrossCompiling() throws {
        // Command Plugin dependencies must be built for the host.
        // This test is only supported on macOS because that is the only
        // platform on which we can currently be sure of having a viable
        // cross-compilation environment (arm64->x86_64 or vice versa).
        // On Linux it is typically only possible to build for the host
        // environment unless cross-compilation SDKs are being used.
        #if !os(macOS)
        try XCTSkipIf(true, "test is only supported on macOS")
        #endif

        let hostToolchain = try UserToolchain(swiftSDK: .hostSwiftSDK())
        let hostTriple = try! hostToolchain.targetTriple.withoutVersion().tripleString

        let x86Triple = "x86_64-apple-macosx"
        let armTriple = "arm64-apple-macosx"
        let targetTriple = hostToolchain.targetTriple.arch == .aarch64 ? x86Triple : armTriple

        // By default, plugin dependencies are built for the host platform
        try fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let (stdout, stderr) = try executeSwiftPackage(fixturePath, extraArgs: ["-v", "build-plugin-dependency"])
            XCTAssertMatch(stdout, .contains("Hello from dependencies-stub"))
            XCTAssertMatch(stderr, .contains("Build of product 'plugintool' complete!"))
            XCTAssertTrue(localFileSystem.exists(fixturePath.appending(RelativePath(".build/\(hostTriple)/debug/plugintool"))))
            XCTAssertTrue(localFileSystem.exists(fixturePath.appending(RelativePath(".build/\(hostTriple)/debug/placeholder"))))
        }

        // When cross compiling the final product, plugin dependencies should still be built for the host
        try fixture(name: "Miscellaneous/Plugins/CommandPluginTestStub") { fixturePath in
            let (stdout, stderr) = try executeSwiftPackage(fixturePath, extraArgs: ["--triple", targetTriple, "-v", "build-plugin-dependency"])
            XCTAssertMatch(stdout, .contains("Hello from dependencies-stub"))
            XCTAssertMatch(stderr, .contains("Build of product 'plugintool' complete!"))
            XCTAssertTrue(localFileSystem.exists(fixturePath.appending(RelativePath(".build/\(hostTriple)/debug/plugintool"))))
            XCTAssertTrue(localFileSystem.exists(fixturePath.appending(RelativePath(".build/\(targetTriple)/debug/placeholder"))))
        }
    }
}
