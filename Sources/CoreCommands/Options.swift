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

import ArgumentParser

import struct Basics.AbsolutePath
import var Basics.localFileSystem
import enum Basics.TestingLibrary
import struct Basics.Triple

import struct Foundation.URL

import enum PackageModel.BuildConfiguration
import struct PackageModel.BuildFlags
import struct PackageModel.EnabledSanitizers
import class PackageModel.Manifest
import struct PackageModel.PackageIdentity
import enum PackageModel.Sanitizer
@_spi(SwiftPMInternal) import struct PackageModel.SwiftSDK

import enum PackageModel.TraitConfiguration

import struct SPMBuildCore.BuildParameters
import struct SPMBuildCore.BuildSystemProvider

import struct TSCBasic.StringError

import struct TSCUtility.Version

import Foundation
import class Workspace.Workspace
import struct Workspace.WorkspaceConfiguration

public struct GlobalOptions: ParsableArguments {
    public init() {}

    @OptionGroup(title: "Paths & Locations")
    public var locations: LocationOptions

    @OptionGroup(title: "Caching")
    public var caching: CachingOptions

    @OptionGroup(title: "Logging")
    public var logging: LoggingOptions

    @OptionGroup(title: "Security")
    public var security: SecurityOptions

    @OptionGroup(title: "Resolution")
    public var resolver: ResolverOptions

    @OptionGroup(title: "Build Options")
    public var build: BuildOptions

    @OptionGroup(title: "Build Options")
    public var linker: LinkerOptions

    @OptionGroup(title: "Trait Options")
    public var traits: TraitOptions
}

public struct LocationOptions: ParsableArguments {
    public init() {}

    @Option(
        name: .customLong("package-path"),
        help: "Specify the package path to operate on (default current directory). This changes the working directory before any other operation.",
        completion: .directory
    )
    public var packageDirectory: AbsolutePath?

    @Option(name: .customLong("cache-path"), help: "Specify the shared cache directory path.", completion: .directory)
    public var cacheDirectory: AbsolutePath?

    @Option(
        name: .customLong("config-path"),
        help: "Specify the shared configuration directory path.",
        completion: .directory
    )
    public var configurationDirectory: AbsolutePath?

    @Option(
        name: .customLong("security-path"),
        help: "Specify the shared security directory path.",
        completion: .directory
    )
    public var securityDirectory: AbsolutePath?

    /// The custom .build directory, if provided.
    @Option(
        name: .customLong("scratch-path"),
        help: "Specify a custom scratch directory path. (default .build)",
        completion: .directory
    )
    var _scratchDirectory: AbsolutePath?

    @Option(name: .customLong("build-path"), help: .hidden)
    var _deprecated_buildPath: AbsolutePath?

    var scratchDirectory: AbsolutePath? {
        self._scratchDirectory ?? self._deprecated_buildPath
    }

    /// The path to the file containing multiroot package data. This is currently Xcode's workspace file.
    @Option(name: .customLong("multiroot-data-file"), help: .hidden, completion: .directory)
    public var multirootPackageDataFile: AbsolutePath?

    /// Path to the compilation destination describing JSON file.
    @Option(name: .customLong("destination"), help: .hidden, completion: .directory)
    public var customCompileDestination: AbsolutePath?

    @Option(name: .customLong("experimental-swift-sdks-path"), help: .hidden, completion: .directory)
    public var deprecatedSwiftSDKsDirectory: AbsolutePath?

    /// Path to the directory containing installed Swift SDKs.
    @Option(
        name: .customLong("swift-sdks-path"),
        help: "Path to the directory containing installed Swift SDKs.",
        completion: .directory
    )
    public var swiftSDKsDirectory: AbsolutePath?

    @Option(
        name: .customLong("toolset"),
        help: """
            Specify a toolset JSON file to use when building for the target platform. \
            Use the option multiple times to specify more than one toolset. Toolsets will be merged in the order \
            they're specified into a single final toolset for the current build.
            """,
        completion: .file(extensions: [".json"])
    )
    public var toolsetPaths: [AbsolutePath] = []

    @Option(
        name: .customLong("pkg-config-path"),
        help:
        """
        Specify alternative path to search for pkg-config `.pc` files. Use the option multiple times to
        specify more than one path.
        """,
        completion: .directory
    )
    public var pkgConfigDirectories: [AbsolutePath] = []
    
    @Option(
        help: .init("Specify alternate path to search for resources required for SwiftPM to operate. (default: <Toolchain Directory>/usr/share/pm)", visibility: .hidden),
        completion: .directory
    )
    public var packageManagerResourcesDirectory: AbsolutePath?

    @Flag(name: .customLong("ignore-lock"), help: .hidden)
    public var ignoreLock: Bool = false
}

public struct CachingOptions: ParsableArguments {
    public init() {}

    /// Disables package caching.
    @Flag(
        name: .customLong("dependency-cache"),
        inversion: .prefixedEnableDisable,
        help: "Use a shared cache when fetching dependencies."
    )
    public var useDependenciesCache: Bool = true

    /// Disables manifest caching.
    @Flag(name: .customLong("disable-package-manifest-caching"), help: .hidden)
    public var shouldDisableManifestCaching: Bool = false

    /// Whether to enable llbuild manifest caching.
    @Flag(name: .customLong("build-manifest-caching"), inversion: .prefixedEnableDisable)
    public var cacheBuildManifest: Bool = true

    /// Disables manifest caching.
    @Option(
        name: .customLong("manifest-cache"),
        help: "Caching mode of Package.swift manifests. Valid values are: (shared: shared cache, local: package's build directory, none: disabled)"
    )
    public var manifestCachingMode: ManifestCachingMode = .shared

    public enum ManifestCachingMode: String, ExpressibleByArgument {
        case none
        case local
        case shared

        public init?(argument: String) {
            self.init(rawValue: argument)
        }
    }

    /// Whether to use macro prebuilts or not
    @Flag(name: .customLong("experimental-prebuilts"),
          inversion: .prefixedEnableDisable,
          help: "Whether to use prebuilt swift-syntax libraries for macros.")
    public var usePrebuilts: Bool = true

    /// Hidden option to override the prebuilts download location for testing
    @Option(
        name: .customLong("experimental-prebuilts-download-url"),
        help: .hidden
    )
    public var prebuiltsDownloadURL: String?

    @Option(
        name: .customLong("experimental-prebuilts-root-cert"),
        help: .hidden
    )
    public var prebuiltsRootCertPath: String?
}

public struct LoggingOptions: ParsableArguments {
    public init() {}

    /// The verbosity of informational output.
    @Flag(name: .shortAndLong, help: "Increase verbosity to include informational output.")
    public var verbose: Bool = false

    /// The verbosity of informational output.
    @Flag(name: [.long, .customLong("vv")], help: "Increase verbosity to include debug output.")
    public var veryVerbose: Bool = false

    /// Whether logging output should be limited to `.error`.
    @Flag(name: .shortAndLong, help: "Decrease verbosity to only include error output.")
    public var quiet: Bool = false

    @Flag(name: .customLong("color-diagnostics"),
          inversion: .prefixedNo,
          help:
            """
            Enables or disables color diagnostics when printing to a TTY. 
            By default, color diagnostics are enabled when connected to a TTY and disabled otherwise.
            """)
    public var colorDiagnostics: Bool = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
}

public struct SecurityOptions: ParsableArguments {
    public init() {}

    /// Disables sandboxing when executing subprocesses.
    @Flag(name: .customLong("disable-sandbox"), help: "Disable using the sandbox when executing subprocesses.")
    public var shouldDisableSandbox: Bool = false

    /// Force usage of the netrc file even in cases where it is not allowed.
    @Flag(name: .customLong("netrc"), help: "Use netrc file even in cases where other credential stores are preferred.")
    public var forceNetrc: Bool = false

    /// Whether to load netrc files for authenticating with remote servers
    /// when downloading binary artifacts. This has no effects on registry
    /// communications.
    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: "Load credentials from a netrc file."
    )
    public var netrc: Bool = true

    /// The path to the netrc file used when `netrc` is `true`.
    @Option(
        name: .customLong("netrc-file"),
        help: "Specify the netrc file path.",
        completion: .file()
    )
    public var netrcFilePath: AbsolutePath?

    /// Whether to use keychain for authenticating with remote servers
    /// when downloading binary artifacts. This has no effects on registry
    /// communications.
    #if canImport(Security)
    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: "Search credentials in macOS keychain."
    )
    public var keychain: Bool = true
    #else
    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: .hidden
    )
    public var keychain: Bool = false
    #endif

    @Option(name: .customLong("resolver-fingerprint-checking"))
    public var fingerprintCheckingMode: WorkspaceConfiguration.CheckingMode = .strict

    @Option(name: .customLong("resolver-signing-entity-checking"))
    public var signingEntityCheckingMode: WorkspaceConfiguration.CheckingMode = .warn

    @Flag(
        inversion: .prefixedEnableDisable,
        exclusivity: .exclusive,
        help: "Validate signature of a signed package release downloaded from registry."
    )
    public var signatureValidation: Bool = true
}

public struct ResolverOptions: ParsableArguments {
    public init() {}

    /// Enable prefetching in resolver which will kick off parallel git cloning.
    @Flag(name: .customLong("prefetching"), inversion: .prefixedEnableDisable)
    public var shouldEnableResolverPrefetching: Bool = true

    /// Use Package.resolved file for resolving dependencies.
    @Flag(
        name: [.long, .customLong("disable-automatic-resolution"), .customLong("only-use-versions-from-resolved-file")],
        help: "Only use versions from the Package.resolved file and fail resolution if it is out-of-date."
    )
    public var forceResolvedVersions: Bool = false

    /// Skip updating dependencies from their remote during a resolution.
    @Flag(name: .customLong("skip-update"), help: "Skip updating dependencies from their remote during a resolution.")
    public var skipDependencyUpdate: Bool = false

    @Flag(help: "Define automatic transformation of source control based dependencies to registry based ones.")
    public var sourceControlToRegistryDependencyTransformation: SourceControlToRegistryDependencyTransformation =
        .disabled

    /// Enables pruning unused dependencies to omit redundant calculations during resolution, and each phase thereafter.
    /// Hidden from the generated help text as this feature is only currently being considered for traits.
    @Flag(
        name: .customLong("experimental-prune-unused-dependencies"),
        help: ArgumentHelp(
            "Enables the ability to prune unused dependencies of the package to avoid redundant loads during resolution.",
            visibility: .hidden
        )
    )
    public var pruneDependencies: Bool = false

    @Option(help: "Default registry URL to use, instead of the registries.json configuration file.")
    public var defaultRegistryURL: URL?

    public enum SourceControlToRegistryDependencyTransformation: EnumerableFlag {
        case disabled
        case identity
        case swizzle

        public static func name(for value: Self) -> NameSpecification {
            switch value {
            case .disabled:
                return .customLong("disable-scm-to-registry-transformation")
            case .identity:
                return .customLong("use-registry-identity-for-scm")
            case .swizzle:
                return .customLong("replace-scm-with-registry")
            }
        }

        public static func help(for value: SourceControlToRegistryDependencyTransformation) -> ArgumentHelp? {
            switch value {
            case .disabled:
                return "Disable source control to registry transformation."
            case .identity:
                return "Look up source control dependencies in the registry and use their registry identity when possible to help deduplicate across the two origins."
            case .swizzle:
                return "Look up source control dependencies in the registry and use the registry to retrieve them instead of source control when possible."
            }
        }
    }
}

public struct BuildOptions: ParsableArguments {
    public init() {}

    /// Build configuration.
    @Option(name: .shortAndLong, help: "Build with configuration")
    public var configuration: BuildConfiguration?

    @Option(
        name: .customLong("Xcc", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all C compiler invocations."
    )
    var cCompilerFlags: [String] = []

    @Option(
        name: .customLong("Xswiftc", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all Swift compiler invocations."
    )
    var swiftCompilerFlags: [String] = []

    @Option(
        name: .customLong("Xlinker", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all linker invocations."
    )
    var linkerFlags: [String] = []

    @Option(
        name: .customLong("Xcxx", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: "Pass flag through to all C++ compiler invocations."
    )
    var cxxCompilerFlags: [String] = []

    @Option(
        name: .customLong("Xxcbuild", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Pass flag through to the Xcode build system invocations.",
            visibility: .hidden
        )
    )
    public var xcbuildFlags: [String] = []

    @Option(
        name: .customLong("Xbuild-tools-swiftc", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Pass flag to Swift compiler invocations for build-time executables (manifest and plugins).",
            visibility: .hidden
        )
    )
    public var _buildToolsSwiftCFlags: [String] = []

    @Option(
        name: .customLong("Xmanifest", withSingleDash: true),
        parsing: .unconditionalSingleValue,
        help: ArgumentHelp(
            "Pass flag to the manifest build invocation. Deprecated: use '-Xbuild-tools-swiftc' instead.",
            visibility: .hidden
        )
    )
    public var _deprecated_manifestFlags: [String] = []

    var manifestFlags: [String] {
        self._deprecated_manifestFlags.isEmpty ?
            self._buildToolsSwiftCFlags :
            self._deprecated_manifestFlags
    }

    var pluginSwiftCFlags: [String] {
        self._buildToolsSwiftCFlags
    }

    public var buildFlags: BuildFlags {
        BuildFlags(
            cCompilerFlags: self.cCompilerFlags,
            cxxCompilerFlags: self.cxxCompilerFlags,
            swiftCompilerFlags: self.swiftCompilerFlags,
            linkerFlags: self.linkerFlags,
            xcbuildFlags: self.xcbuildFlags
        )
    }

    /// The compilation destination’s target triple.
    @Option(name: .customLong("triple"), transform: Triple.init)
    public var customCompileTriple: Triple?

    /// Path to the compilation destination’s SDK.
    @Option(name: .customLong("sdk"))
    public var customCompileSDK: AbsolutePath?

    /// Path to the compilation destination’s toolchain.
    @Option(name: .customLong("toolchain"))
    public var customCompileToolchain: AbsolutePath?

    /// The architectures to compile for.
    @Option(
        name: .customLong("arch"),
        help: ArgumentHelp(
            "Build the package for the these architectures",
            visibility: .hidden
        )
    )
    public var architectures: [String] = []

    @Option(name: .customLong("experimental-swift-sdk"), help: .hidden)
    public var deprecatedSwiftSDKSelector: String?

    /// Filter for selecting a specific Swift SDK to build with.
    @Option(
        name: .customLong("swift-sdk"),
        help: "Filter for selecting a specific Swift SDK to build with."
    )
    public var swiftSDKSelector: String?

    /// Which compile-time sanitizers should be enabled.
    @Option(
        name: .customLong("sanitize"),
        help: "Turn on runtime checks for erroneous behavior, possible values: \(Sanitizer.formattedValues)."
    )
    public var sanitizers: [Sanitizer] = []

    public var enabledSanitizers: EnabledSanitizers {
        EnabledSanitizers(Set(sanitizers))
    }

    @Flag(help: "Enable or disable indexing-while-building feature.")
    public var indexStoreMode: StoreMode = .autoIndexStore

    /// Instead of building the target, perform the minimal amount of work to prepare it for indexing.
    ///
    /// This builds Swift module files for all dependencies but skips generation of object files. It also continues
    /// building modules in the presence of compilation errors.
    @Flag(name: .customLong("experimental-prepare-for-indexing"), help: .hidden)
    var prepareForIndexing: Bool = false

    /// Don't pass `-experimental-lazy-typecheck` during preparation.
    ///
    /// This is intended as a workaround if lazy type checking is causing compiler crashes.
    ///
    /// Only applicable in conjunction with `--experimental-prepare-for-indexing`
    @Flag(name: .customLong("experimental-prepare-for-indexing-no-lazy"), help: .hidden)
    var prepareForIndexingNoLazy: Bool = false

    /// Whether to enable generation of `.swiftinterface`s alongside `.swiftmodule`s.
    @Flag(name: .customLong("enable-parseable-module-interfaces"))
    public var shouldEnableParseableModuleInterfaces: Bool = false

    /// The number of jobs for llbuild to start (aka the number of schedulerLanes)
    @Option(name: .shortAndLong, help: "The number of jobs to spawn in parallel during the build process.")
    public var jobs: UInt32?

    /// Whether to use the integrated Swift driver rather than shelling out
    /// to a separate process.
    @Flag()
    public var useIntegratedSwiftDriver: Bool = false

    /// A flag that indicates this build should check whether targets only import
    /// their explicitly-declared dependencies
    @Option(help: "A flag that indicates this build should check whether targets only import their explicitly-declared dependencies.")
    public var explicitTargetDependencyImportCheck: TargetDependencyImportCheckingMode = .none

    /// The build system to use.
    @Option(name: .customLong("build-system"))
    var _buildSystem: BuildSystemProvider.Kind = .native

    /// The Debug Information Format to use.
    @Option(name: .customLong("debug-info-format", withSingleDash: true), help: "The Debug Information Format to use.")
    public var debugInfoFormat: DebugInfoFormat = .dwarf

    public var buildSystem: BuildSystemProvider.Kind {
        // Force the Xcode build system if we want to build more than one arch.
        return self.architectures.count > 1 ? .xcode : self._buildSystem
    }

    /// Whether to enable test discovery on platforms without Objective-C runtime.
    @Flag(help: .hidden)
    public var enableTestDiscovery: Bool = false

    /// Path of test entry point file to use, instead of synthesizing one or using `XCTMain.swift` in the package (if
    /// present).
    /// This implies `--enable-test-discovery`
    @Option(
        name: .customLong("experimental-test-entry-point-path"),
        help: .hidden
    )
    public var testEntryPointPath: AbsolutePath?

    /// The lto mode to use if any.
    @Option(
        name: .customLong("experimental-lto-mode"),
        help: .hidden
    )
    public var linkTimeOptimizationMode: LinkTimeOptimizationMode?

    @Flag(inversion: .prefixedEnableDisable, help: .hidden)
    public var getTaskAllowEntitlement: Bool? = nil

    // Whether to omit frame pointers
    // this can be removed once the backtracer uses DWARF instead of frame pointers
    @Flag(inversion: .prefixedNo, help: .hidden)
    public var omitFramePointers: Bool? = nil

    // @Flag works best when there is a default value present
    // if true, false aren't enough and a third state is needed
    // nil should not be the goto. Instead create an enum
    public enum StoreMode: EnumerableFlag {
        case autoIndexStore
        case enableIndexStore
        case disableIndexStore
    }

    public enum TargetDependencyImportCheckingMode: String, Codable, ExpressibleByArgument, CaseIterable {
        case none
        case warn
        case error
    }

    /// See `BuildParameters.LinkTimeOptimizationMode` for details.
    public enum LinkTimeOptimizationMode: String, Codable, ExpressibleByArgument {
        /// See `BuildParameters.LinkTimeOptimizationMode.full` for details.
        case full
        /// See `BuildParameters.LinkTimeOptimizationMode.thin` for details.
        case thin
    }

    /// See `BuildParameters.DebugInfoFormat` for details.
    public enum DebugInfoFormat: String, Codable, ExpressibleByArgument, CaseIterable {
        /// See `BuildParameters.DebugInfoFormat.dwarf` for details.
        case dwarf
        /// See `BuildParameters.DebugInfoFormat.codeview` for details.
        case codeview
        /// See `BuildParameters.DebugInfoFormat.none` for details.
        case none
    }
}

public struct LinkerOptions: ParsableArguments {
    public init() {}

    @Flag(
        name: .customLong("dead-strip"),
        inversion: .prefixedEnableDisable,
        help: "Disable/enable dead code stripping by the linker."
    )
    public var linkerDeadStrip: Bool = true

    /// Disables adding $ORIGIN/@loader_path to the rpath, useful when deploying
    @Flag(name: .customLong("disable-local-rpath"), help: "Disable adding $ORIGIN/@loader_path to the rpath by default.")
    public var shouldDisableLocalRpath: Bool = false
}

/// Which testing libraries to use (and any related options.)
@_spi(SwiftPMInternal)
public struct TestLibraryOptions: ParsableArguments {
    public init() {}

    /// Whether to enable support for XCTest (as explicitly specified by the user.)
    ///
    /// Callers will generally want to use ``enableXCTestSupport`` since it will
    /// have the correct default value if the user didn't specify one.
    @Flag(name: .customLong("xctest"),
          inversion: .prefixedEnableDisable,
          help: "Enable support for XCTest.")
    public var explicitlyEnableXCTestSupport: Bool?

    /// Whether to enable support for Swift Testing (as explicitly specified by the user.)
    ///
    /// Callers will generally want to use ``enableSwiftTestingLibrarySupport`` since it will
    /// have the correct default value if the user didn't specify one.
    @Flag(name: .customLong("swift-testing"),
          inversion: .prefixedEnableDisable,
          help: "Enable support for Swift Testing.")
    public var explicitlyEnableSwiftTestingLibrarySupport: Bool?

    /// Legacy experimental equivalent of ``explicitlyEnableSwiftTestingLibrarySupport``.
    ///
    /// This option will be removed in a future update.
    @Flag(name: .customLong("experimental-swift-testing"),
          inversion: .prefixedEnableDisable,
          help: .private)
    public var explicitlyEnableExperimentalSwiftTestingLibrarySupport: Bool?

    /// The common implementation for `isEnabled()` and `isExplicitlyEnabled()`.
    ///
    /// It is intentional that `isEnabled()` is not simply this function with a
    /// default value for the `default` argument. There's no "true" default
    /// value to use; it depends on the semantics the caller is interested in.
    private func isEnabled(_ library: TestingLibrary, `default`: Bool, swiftCommandState: SwiftCommandState) -> Bool {
        switch library {
        case .xctest:
            if let explicitlyEnableXCTestSupport {
                return explicitlyEnableXCTestSupport
            }
            if let toolchain = try? swiftCommandState.getHostToolchain(),
               toolchain.swiftSDK.xctestSupport == .supported {
                return `default`
            }
            return false
        case .swiftTesting:
            return explicitlyEnableSwiftTestingLibrarySupport ?? explicitlyEnableExperimentalSwiftTestingLibrarySupport ?? `default`
        }
    }

    /// Test whether or not a given library is enabled.
    public func isEnabled(_ library: TestingLibrary, swiftCommandState: SwiftCommandState) -> Bool {
        isEnabled(library, default: true, swiftCommandState: swiftCommandState)
    }

    /// Test whether or not a given library was explicitly enabled by the developer.
    public func isExplicitlyEnabled(_ library: TestingLibrary, swiftCommandState: SwiftCommandState) -> Bool {
        isEnabled(library, default: false, swiftCommandState: swiftCommandState)
    }
}

public struct TraitOptions: ParsableArguments {
    public init() {}

    /// The traits to enable for the package.
    @Option(
        name: .customLong("traits"),
        help: "Enables the passed traits of the package. Multiple traits can be specified by providing a comma separated list e.g. `--traits Trait1,Trait2`. When enabling specific traits the defaults traits need to explictily enabled as well by passing `defaults` to this command."
    )
    package var _enabledTraits: String?

    /// The set of enabled traits for the package.
    public var enabledTraits: Set<String>? {
        self._enabledTraits.flatMap { Set($0.components(separatedBy: ",")) }
    }

    /// Enables all traits of the package.
    @Flag(
        name: .customLong("enable-all-traits"),
        help: "Enables all traits of the package."
    )
    public var enableAllTraits: Bool = false

    /// Disables all default traits of the package.
    @Flag(
        name: .customLong("disable-default-traits"),
        help: "Disables all default traits of the package."
    )
    public var disableDefaultTraits: Bool = false
}

extension TraitConfiguration {
    public init(traitOptions: TraitOptions) {
        var enabledTraits = traitOptions.enabledTraits
        if traitOptions.disableDefaultTraits {
            // If there are no enabled traits specified we can disable the
            // default trait by passing in an empty set. Otherwise the enabling specific traits
            // requires the user to pass the default as well.
            enabledTraits = enabledTraits ?? []
        }
        self.init(
            enabledTraits: enabledTraits,
            enableAllTraits: traitOptions.enableAllTraits
        )
    }
}

// MARK: - Extensions

extension BuildConfiguration {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension AbsolutePath {
    public init?(argument: String) {
        if let cwd = localFileSystem.currentWorkingDirectory {
            guard let path = try? AbsolutePath(validating: argument, relativeTo: cwd) else {
                return nil
            }
            self = path
        } else {
            guard let path = try? AbsolutePath(validating: argument) else {
                return nil
            }
            self = path
        }
    }

    public static var defaultCompletionKind: CompletionKind {
        // This type is most commonly used to select a directory, not a file.
        // Specify '.file()' in an argument declaration when necessary.
        .directory
    }
}

extension WorkspaceConfiguration.CheckingMode {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension Sanitizer {
    public init?(argument: String) {
        if let sanitizer = Sanitizer(rawValue: argument) {
            self = sanitizer
            return
        }

        for sanitizer in Sanitizer.allCases where sanitizer.shortName == argument {
            self = sanitizer
            return
        }

        return nil
    }

    /// All sanitizer options in a comma separated string
    fileprivate static var formattedValues: String {
        Sanitizer.allCases.map(\.rawValue).joined(separator: ", ")
    }
}

extension PackageIdentity {
    public init?(argument: String) {
        self = .plain(argument)
    }
}

extension URL {
    public init?(argument: String) {
        self.init(string: argument)
    }
}

extension BuildConfiguration: ExpressibleByArgument {}
extension AbsolutePath: ExpressibleByArgument {}
extension WorkspaceConfiguration.CheckingMode: ExpressibleByArgument {}
extension Sanitizer: ExpressibleByArgument {}
extension BuildSystemProvider.Kind: ExpressibleByArgument {}
extension Version: @retroactive ExpressibleByArgument {}
extension PackageIdentity: ExpressibleByArgument {}
extension URL: @retroactive ExpressibleByArgument {}
