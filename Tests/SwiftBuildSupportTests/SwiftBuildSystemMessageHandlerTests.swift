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

import Basics
import Foundation
import struct SWBUtil.AbsolutePath
import Testing
@_spi(Testing)
import SwiftBuild
import SwiftBuildSupport

import TSCBasic
import _InternalTestSupport

@Suite
struct SwiftBuildSystemMessageHandlerTests {
    struct MockMessageHandlerProvider {
        private let warningMessageHandler: SwiftBuildSystemMessageHandler
        private let errorMessageHandler: SwiftBuildSystemMessageHandler
        private let debugMessageHandler: SwiftBuildSystemMessageHandler

        public init(
            outputStream: BufferedOutputByteStream,
            observabilityScope: ObservabilityScope,
        ) {
            self.warningMessageHandler = .init(
                observabilityScope: observabilityScope,
                outputStream: outputStream,
                logLevel: .warning
            )
            self.errorMessageHandler = .init(
                observabilityScope: observabilityScope,
                outputStream: outputStream,
                logLevel: .error
            )
            self.debugMessageHandler = .init(
                observabilityScope: observabilityScope,
                outputStream: outputStream,
                logLevel: .debug
            )
        }

        public var warning: SwiftBuildSystemMessageHandler {
            return warningMessageHandler
        }

        public var error: SwiftBuildSystemMessageHandler {
            return errorMessageHandler
        }

        public var debug: SwiftBuildSystemMessageHandler {
            return debugMessageHandler
        }
    }

    let outputStream: BufferedOutputByteStream
    let observability: TestingObservability
    let messageHandler: MockMessageHandlerProvider

    init() {
        self.outputStream = BufferedOutputByteStream()
        self.observability = ObservabilitySystem.makeForTesting(
            outputStream: outputStream
        )
        self.messageHandler = .init(
            outputStream: self.outputStream,
            observabilityScope: self.observability.topScope
        )
    }

    @Test
    func testExceptionThrownWhenTaskCompleteEventReceivedWithoutTaskStart() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskCompleteInfo(result: .success)
        ]

        #expect(throws: (any Error).self) {
            for event in events {
                _ = try messageHandler.emitEvent(event)
            }
        }
    }

    @Test
    func testNoDiagnosticsReported() throws {
        let messageHandler = self.messageHandler.warning
        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(),
            .taskCompleteInfo(),
            .buildCompletedInfo()
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        // Check output stream
        let output = self.outputStream.bytes.description
        #expect(!output.contains("error"))

        // Check observability diagnostics
        expectNoDiagnostics(self.observability.diagnostics)
    }

    @Test
    func testSimpleDiagnosticReported() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskSignature: "simple-diagnostic"),
            .diagnostic(locationContext2: .init(taskSignature: "simple-diagnostic"), message: "Simple diagnostic", appendToOutputStream: true),
            .taskCompleteInfo(taskSignature: "simple-diagnostic", result: .failed) // Handler only emits when a task is completed.
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(self.observability.hasErrorDiagnostics)

        try expectDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: "Simple diagnostic", severity: .error)
        }
    }

    @Test
    func testTwoDifferentDiagnosticsReported() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskSignature: "diagnostics"),
            .diagnostic(
                locationContext2: .init(
                    taskSignature: "diagnostics"
                ),
                message: "First diagnostic",
                appendToOutputStream: true
            ),
            .diagnostic(
                locationContext2: .init(
                    taskSignature: "diagnostics"
                ),
                message: "Second diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskSignature: "diagnostics", result: .failed) // Handler only emits when a task is completed.
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(self.observability.hasErrorDiagnostics)

        try expectDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: "First diagnostic", severity: .error)
            result.check(diagnostic: "Second diagnostic", severity: .error)
        }
    }

    @Test
    func testManyDiagnosticsReported() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskID: 1, taskSignature: "simple-diagnostic"),
            .diagnostic(
                locationContext2: .init(taskSignature: "simple-diagnostic"),
                message: "Simple diagnostic",
                appendToOutputStream: true
            ),
            .taskStartedInfo(taskID: 2, taskSignature: "another-diagnostic"),
            .taskStartedInfo(taskID: 3, taskSignature: "warning-diagnostic"),
            .diagnostic(
                kind: .warning,
                locationContext2: .init(taskSignature: "warning-diagnostic"),
                message: "Warning diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskID: 1, taskSignature: "simple-diagnostic", result: .failed),
            .diagnostic(
                kind: .warning,
                locationContext2: .init(taskSignature: "warning-diagnostic"),
                message: "Another warning diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskID: 3, taskSignature: "warning-diagnostic", result: .success),
            .diagnostic(
                kind: .note,
                locationContext2: .init(taskSignature: "another-diagnostic"),
                message: "Another diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskID: 2, taskSignature: "another-diagnostic", result: .failed)
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(self.observability.hasErrorDiagnostics)

        try expectDiagnostics(observability.diagnostics) { result in
            result.check(diagnostic: "Simple diagnostic", severity: .error)
            result.check(diagnostic: "Another diagnostic", severity: .info)
            result.check(diagnostic: "Another warning diagnostic", severity: .warning)
            result.check(diagnostic: "Warning diagnostic", severity: .warning)
        }
    }

    // Regression test for a bug where swift-driver warnings (e.g. "warning: next compile won't
    // be incremental") appeared on the same line as the build progress indicator.
    //
    // The root cause: emitDiagnosticCompilerOutput() used observabilityScope.print(), which
    // dispatches to the observability handler's serial queue asynchronously. By the time the
    // write ran, a subsequent progressAnimation.update() call could have written new progress
    // text to the terminal (without a trailing newline), causing the warning to be appended to
    // that progress line rather than appearing on its own line.
    //
    // The fix: write directly to outputStream (synchronously), matching LLBuildProgressTracker.
    //
    // This test validates the fix by using SEPARATE streams for the handler and the observability
    // scope. The warning must appear in the handler's outputStream (direct write), not in the
    // observability scope's stream (which the old async path would have used).
    @Test
    func testCompilerOutputWritesDirectlyToOutputStream() throws {
        // Separate streams so we can distinguish direct outputStream writes from
        // observabilityScope.print() writes.
        let handlerOutputStream = BufferedOutputByteStream()
        let observabilityOutputStream = BufferedOutputByteStream()
        let observability = ObservabilitySystem.makeForTesting(outputStream: observabilityOutputStream)
        let messageHandler = SwiftBuildSystemMessageHandler(
            observabilityScope: observability.topScope,
            outputStream: handlerOutputStream,
            logLevel: .warning
        )

        let warningString = "warning: next compile won't be incremental\n"

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskID: 1, taskSignature: "task-1"),
            .outputInfo(
                data: data(warningString),
                locationContext: .task(taskID: 1, targetID: 1),
                locationContext2: .init(targetID: 1, taskSignature: "task-1")
            ),
            // appendToOutputStream: false → marks the task ID for emitDiagnosticCompilerOutput
            .diagnostic(
                kind: .warning,
                locationContext: .task(taskID: 1, targetID: 1),
                locationContext2: .init(taskSignature: "task-1"),
                appendToOutputStream: false
            ),
            .taskCompleteInfo(taskID: 1, taskSignature: "task-1", result: .success),
            .buildCompletedInfo(),
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        let handlerOutput = handlerOutputStream.bytes.description
        let observabilityOutput = observabilityOutputStream.bytes.description

        // Post-fix: output is written synchronously via outputStream.send(), so it appears in
        // handlerOutputStream, not in the observability scope's stream.
        #expect(
            handlerOutput.contains(warningString),
            "Compiler output must be written directly to outputStream, not through observabilityScope.print()"
        )
        #expect(
            !observabilityOutput.contains(warningString),
            "Compiler output must not go through observabilityScope.print() (async path that races with progress animation)"
        )
    }

    @Test
    func testCompilerOutputDiagnosticsWithoutDuplicatedLogging() throws {
        let messageHandler = self.messageHandler.warning

        let simpleDiagnosticString: String = "[error]: Simple diagnostic\n"
        let simpleOutputInfo: SwiftBuildMessage = .outputInfo(
            data: data(simpleDiagnosticString),
            locationContext: .task(taskID: 1, targetID: 1),
            locationContext2: .init(targetID: 1, taskSignature: "simple-diagnostic")
        )

        let warningDiagnosticString: String = "[warning]: Warning diagnostic\n"
        let warningOutputInfo: SwiftBuildMessage = .outputInfo(
            data: data(warningDiagnosticString),
            locationContext: .task(taskID: 3, targetID: 1),
            locationContext2: .init(targetID: 1, taskSignature: "warning-diagnostic")
        )

        let anotherDiagnosticString = "[note]: Another diagnostic\n"
        let anotherOutputInfo: SwiftBuildMessage = .outputInfo(
            data: data(anotherDiagnosticString),
            locationContext: .task(taskID: 2, targetID: 1),
            locationContext2: .init(targetID: 1, taskSignature: "another-diagnostic")
        )

        let anotherWarningDiagnosticString: String = "[warning]: Another warning diagnostic\n"
        let anotherWarningOutputInfo: SwiftBuildMessage = .outputInfo(
            data: data(anotherWarningDiagnosticString),
            locationContext: .task(taskID: 3, targetID: 1),
            locationContext2: .init(targetID: 1, taskSignature: "warning-diagnostic")
        )

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskID: 1, taskSignature: "simple-diagnostic"),
            .diagnostic(
                locationContext2: .init(taskSignature: "simple-diagnostic"),
                message: "Simple diagnostic",
                appendToOutputStream: true
            ),
            .taskStartedInfo(taskID: 2, taskSignature: "another-diagnostic"),
            .taskStartedInfo(taskID: 3, taskSignature: "warning-diagnostic"),
            .diagnostic(
                kind: .warning,
                locationContext2: .init(taskSignature: "warning-diagnostic"),
                message: "Warning diagnostic",
                appendToOutputStream: true
            ),
            anotherWarningOutputInfo,
            simpleOutputInfo,
            .taskCompleteInfo(taskID: 1, taskSignature: "simple-diagnostic"),
            .diagnostic(
                kind: .warning,
                locationContext2: .init(taskSignature: "warning-diagnostic"),
                message: "Another warning diagnostic",
                appendToOutputStream: true
            ),
            warningOutputInfo,
            .taskCompleteInfo(taskID: 3, taskSignature: "warning-diagnostic"),
            .diagnostic(
                kind: .note,
                locationContext2: .init(taskSignature: "another-diagnostic"),
                message: "Another diagnostic",
                appendToOutputStream: true
            ),
            anotherOutputInfo,
            .taskCompleteInfo(taskID: 2, taskSignature: "another-diagnostic")
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        let outputText = self.outputStream.bytes.description
        #expect(outputText.contains("error"))
    }

    @Test
    func testDiagnosticOutputWhenOnlyWarnings() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskID: 1, taskSignature: "simple-warning-diagnostic"),
            .diagnostic(
                kind: .warning,
                locationContext2: .init(taskSignature: "simple-warning-diagnostic"),
                message: "Simple warning diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskID: 1, taskSignature: "simple-warning-diagnostic", result: .success)
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(self.observability.hasWarningDiagnostics)
    }

    @Test
    func testDiagnosticOutputWhenOnlyNotes() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskID: 1, taskSignature: "simple-note-diagnostic"),
            .diagnostic(
                kind: .note,
                locationContext2: .init(taskSignature: "simple-note-diagnostic"),
                message: "Simple note diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskID: 1, taskSignature: "simple-note-diagnostic", result: .success)
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 1)
        try expectDiagnostics(self.observability.diagnostics) { result in
            result.check(diagnostic: "Simple note diagnostic", severity: .info)
        }
    }

    @Test
    func testDiagnosticOutputWhenOnlyDebugs() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .taskStartedInfo(taskID: 1, taskSignature: "simple-debug-diagnostic"),
            .diagnostic(
                kind: .remark,
                locationContext2: .init(taskSignature: "simple-debug-diagnostic"),
                message: "Simple debug diagnostic",
                appendToOutputStream: true
            ),
            .taskCompleteInfo(taskID: 1, taskSignature: "simple-debug-diagnostic", result: .success)
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 1)
        try expectDiagnostics(self.observability.diagnostics) { result in
            result.check(diagnostic: "Simple debug diagnostic", severity: .debug)
        }
    }

    @Test
    func testPlanningOperationStartAndCompleteMessagesVerboseOnly() throws {
        let verboseMessageHandler = self.messageHandler.debug

        let events: [SwiftBuildMessage] = [
            .planningOperationStartedInfo(),
            .planningOperationCompletedInfo()
        ]

        for event in events {
            _ = try verboseMessageHandler.emitEvent(event)
        }

        let verboseOutput = self.outputStream.bytes.description

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 0)

        #expect(verboseOutput.contains("Planning build"))
        #expect(verboseOutput.contains("Planning complete"))
    }

    @Test
    func testPlanningOperationStartAndCompleteNoMessageWarningLogLevel() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .planningOperationStartedInfo(),
            .planningOperationCompletedInfo()
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        let output = self.outputStream.bytes.description

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 0)

        #expect(!output.contains("Planning build"))
        #expect(!output.contains("Planning complete"))
    }

    @Test
    func testPlanningOperationStartAndCompleteNoMessageErrorLogLevel() throws {
        let messageHandler = self.messageHandler.error

        let events: [SwiftBuildMessage] = [
            .planningOperationStartedInfo(),
            .planningOperationCompletedInfo()
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        let output = self.outputStream.bytes.description

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 0)

        #expect(!output.contains("Planning build"))
        #expect(!output.contains("Planning complete"))
    }

    @Test
    func testTargetUpToDateMessage() throws {
        let messageHandler = self.messageHandler.debug

        let events: [SwiftBuildMessage] = [
            .targetUpToDateInfo()
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 0)

        let output = self.outputStream.bytes.description
        #expect(output.contains("Target mock-target-guid up to date."))
    }

    @Test
    func testBuildProgressMessages() throws {
        let messageHandler = self.messageHandler.warning

        let events: [SwiftBuildMessage] = [
            .progress(message: "Weird percent", percentComplete: -1),
            .progress(message: "12 / 32", percentComplete: 0),
            .progress(message: "Something useful", percentComplete: 12),
            .progress(message: "Complete", percentComplete: 100)
        ]

        for event in events {
            _ = try messageHandler.emitEvent(event)
        }

        #expect(!self.observability.hasWarningDiagnostics)
        #expect(!self.observability.hasErrorDiagnostics)
        #expect(self.observability.diagnostics.count == 0)

        let output = self.outputStream.bytes.description
        #expect(output.contains("Weird percent"))
        #expect(!output.contains("12 / 32"))
        #expect(output.contains("Something useful"))
        #expect(output.contains("Complete"))
    }
}

private func data(_ message: String) -> Data {
    Data(message.utf8)
}

/// Convenience inits for testing
extension SwiftBuildMessage {
    /// SwiftBuildMessage.TaskStartedInfo
    package static func taskStartedInfo(
        taskID: Int = 1,
        targetID: Int? = nil,
        taskSignature: String = "mock-task-signature",
        parentTaskID: Int? = nil,
        ruleInfo: String = "mock-rule",
        interestingPath: SwiftBuild.AbsolutePath? = nil,
        commandLineDisplayString: String? = nil,
        executionDescription: String = "execution description",
        serializedDiagnosticsPath: [SwiftBuild.AbsolutePath] = []
    ) -> SwiftBuildMessage {
        .taskStarted(
            .init(
                taskID: taskID,
                targetID: targetID,
                taskSignature: taskSignature,
                parentTaskID: parentTaskID,
                ruleInfo: ruleInfo,
                interestingPath: interestingPath,
                commandLineDisplayString: commandLineDisplayString,
                executionDescription: executionDescription,
                serializedDiagnosticsPaths: serializedDiagnosticsPath
            )
        )
    }

    /// SwiftBuildMessage.TaskCompletedInfo
    package static func taskCompleteInfo(
        taskID: Int = 1,
        taskSignature: String = "mock-task-signature",
        result: TaskCompleteInfo.Result = .success,
        signalled: Bool = false,
        metrics: TaskCompleteInfo.Metrics? = nil
    ) -> SwiftBuildMessage {
        .taskComplete(
            .init(
                taskID: taskID,
                taskSignature: taskSignature,
                result: result,
                signalled: signalled,
                metrics: metrics
            )
        )
    }

    /// SwiftBuildMessage.DiagnosticInfo
    package static func diagnostic(
        kind: DiagnosticInfo.Kind = .error,
        location: DiagnosticInfo.Location = .unknown,
        locationContext: LocationContext = .task(taskID: 1, targetID: 1),
        locationContext2: LocationContext2 = .init(),
        component: DiagnosticInfo.Component = .default,
        message: String = "Mock diagnostic message.",
        optionName: String? = nil,
        appendToOutputStream: Bool = false,
        childDiagnostics: [DiagnosticInfo] = [],
        sourceRanges: [DiagnosticInfo.SourceRange] = [],
        fixIts: [SwiftBuildMessage.DiagnosticInfo.FixIt] = []
    ) -> SwiftBuildMessage {
        .diagnostic(
            .init(
                kind: kind,
                location: location,
                locationContext: locationContext,
                locationContext2: locationContext2,
                component: component,
                message: message,
                optionName: optionName,
                appendToOutputStream: appendToOutputStream,
                childDiagnostics: childDiagnostics,
                sourceRanges: sourceRanges,
                fixIts: fixIts
            )
        )
    }

    /// SwiftBuildMessage.BuildStartedInfo
    package static func buildStartedInfo(
        baseDirectory: SwiftBuild.AbsolutePath,
        derivedDataPath: SwiftBuild.AbsolutePath? = nil
    ) -> SwiftBuildMessage.BuildStartedInfo {
        .init(
            baseDirectory: baseDirectory,
            derivedDataPath: derivedDataPath
        )
    }

    /// SwiftBuildMessage.BuildCompleteInfo
    package static func buildCompletedInfo(
        result: BuildCompletedInfo.Result = .ok,
        metrics: BuildOperationMetrics? = nil
    ) -> SwiftBuildMessage {
        .buildCompleted(
            .init(
                result: result,
                metrics: metrics
            )
        )
    }

    /// SwiftBuildMessage.OutputInfo
    package static func outputInfo(
        data: Data,
        locationContext: LocationContext = .task(taskID: 1, targetID: 1),
        locationContext2: LocationContext2 = .init(targetID: 1, taskSignature: "mock-task-signature")
    ) -> SwiftBuildMessage {
        .output(
            .init(
                data: data,
                locationContext: locationContext,
                locationContext2: locationContext2
            )
        )
    }

    /// SwiftBuildMessage.PlanningOperationStartedInfo
    package static func planningOperationStartedInfo(
        planningOperationID: String = "mock-planning-operation-id"
    ) -> SwiftBuildMessage {
        .planningOperationStarted(
            .init(planningOperationID: planningOperationID)
        )
    }

    /// SwiftBuildMessage.PlanningOperationCompletedInfo
    package static func planningOperationCompletedInfo(
        planningOperationID: String = "mock-planning-operation-id"
    ) -> SwiftBuildMessage {
        .planningOperationCompleted(
            .init(planningOperationID: planningOperationID)
        )
    }

    /// SwiftBuildMessage.TargetUpToDateInfo
    package static func targetUpToDateInfo(
        guid: String = "mock-target-guid"
    ) -> SwiftBuildMessage {
        .targetUpToDate(
            .init(guid: guid)
        )
    }

    /// SwiftBuildMessage.DidUpdateProgressInfo
    package static func progress(
        message: String,
        percentComplete: Double,
        showInLog: Bool = false,
        targetName: String? = nil
    ) -> SwiftBuildMessage {
        .didUpdateProgress(
            .init(
                message: message,
                percentComplete: percentComplete,
                showInLog: showInLog,
                targetName: targetName
            )
        )
    }
}
