import Foundation
import MacModesCore
var failures = 0
var tests = 0
func fail(_ message: String, file: StaticString, line: UInt) { failures += 1; print("FAIL \(file):\(line): \(message)") }
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows { let x = try a(), y = try b(); if x != y { fail("\(x) != \(y)",file:file,line:line) } }
func expectLess<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a < b) { fail("Expected ordered calls",file:file,line:line) } }
func expectTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { if !value() { fail("Expected true",file:file,line:line) } }
func expectFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { expectTrue(!value(),file:file,line:line) }
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { fail("Expected nil",file:file,line:line) } }
func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value == nil { fail("Expected value",file:file,line:line) } }
func expectThrows<T>(_ action: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try action(); fail("Expected failure",file:file,line:line) } catch {} }
func expectNoThrow<T>(_ action: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try action() } catch { fail(error.localizedDescription,file:file,line:line) } }
func test(_ name: String, _ action: () throws -> Void) { tests += 1; let before = failures; do { try action() } catch { failures += 1; print("FAIL \(name): \(error)") }; if before == failures { print("PASS \(name)") } }
test("StorageTests.testCrashAfterStateSaveDoesNotReverseToggle") { let suite=StorageTests();try suite.setUpWithError();defer { try? suite.tearDownWithError() };try suite.testCrashAfterStateSaveDoesNotReverseToggle() }
test("StorageTests.testDurableTargetSurvivesInterruptedTransition") { let suite=StorageTests();try suite.setUpWithError();defer { try? suite.tearDownWithError() };try suite.testDurableTargetSurvivesInterruptedTransition() }
test("StorageTests.testDurableResultNotExecutedTwice") { let suite=StorageTests();try suite.setUpWithError();defer { try? suite.tearDownWithError() };try suite.testDurableResultNotExecutedTwice() }
test("StorageTests.testMalformedRequestQuarantined") { let suite=StorageTests();try suite.setUpWithError();defer { try? suite.tearDownWithError() };try suite.testMalformedRequestQuarantined() }
test("StorageTests.testLockExcludesOtherController") { let suite=StorageTests();try suite.setUpWithError();defer { try? suite.tearDownWithError() };try suite.testLockExcludesOtherController() }
test("StorageTests.testAtomicWriteHasPrivatePermissions") { let suite=StorageTests();try suite.setUpWithError();defer { try? suite.tearDownWithError() };try suite.testAtomicWriteHasPrivatePermissions() }
test("PlatformTests.testVPNGates") { let suite=PlatformTests();try suite.testVPNGates() }
test("PlatformTests.testUnknownProtonStatePreserved") { let suite=PlatformTests();try suite.testUnknownProtonStatePreserved() }
test("PlatformTests.testCommandTimeoutAndFailure") { let suite=PlatformTests();try suite.testCommandTimeoutAndFailure() }
if !CommandLine.arguments.contains("--skip-ocr") { test("PlatformTests.testOCRReadsGeneratedImage") { let suite=PlatformTests();try suite.testOCRReadsGeneratedImage() } }
test("ControllerTests.testAllModePairsAndToggles") { let suite=ControllerTests();try suite.testAllModePairsAndToggles() }
test("ControllerTests.testPrivateOrderAndGate") { let suite=ControllerTests();try suite.testPrivateOrderAndGate() }
test("ControllerTests.testPrivateExitCancellationKeepsVPN") { let suite=ControllerTests();try suite.testPrivateExitCancellationKeepsVPN() }
test("ControllerTests.testCancellationLeavesServicesAndClearsOnNoop") { let suite=ControllerTests();try suite.testCancellationLeavesServicesAndClearsOnNoop() }
test("ControllerTests.testSameModeVerifiesServices") { let suite=ControllerTests();try suite.testSameModeVerifiesServices() }
test("ControllerTests.testIdleHealthIsWarning") { let suite=ControllerTests();try suite.testIdleHealthIsWarning() }
test("ControllerTests.testLayoutFailureIsWarning") { let suite=ControllerTests();try suite.testLayoutFailureIsWarning() }
test("ControllerTests.testStartupFailureRollsBack") { let suite=ControllerTests();try suite.testStartupFailureRollsBack() }
test("ControllerTests.testOwnershipAndRefusedQuit") { let suite=ControllerTests();try suite.testOwnershipAndRefusedQuit() }
test("ControllerTests.testEverydayBrowserNotOwnedOrClosed") { let suite=ControllerTests();try suite.testEverydayBrowserNotOwnedOrClosed() }
test("ControllerTests.testMonitorContinuesAfterFailedExit") { let suite=ControllerTests();try suite.testMonitorContinuesAfterFailedExit() }
test("ControllerTests.testStaleMonitorResultDoesNotFailNewMode") { let suite=ControllerTests();try suite.testStaleMonitorResultDoesNotFailNewMode() }
test("ControllerTests.testMonitorDoesNotWaitForPlatformDialog") { let suite=ControllerTests();try suite.testMonitorDoesNotWaitForPlatformDialog() }
test("ControllerTests.testPreexistingAppClosesOnModeExit") { try ControllerTests().testPreexistingAppClosesOnModeExit() }
test("ControllerTests.testPreexistingQuitRefusalPreservesServices") { try ControllerTests().testPreexistingQuitRefusalPreservesServices() }
test("ControllerTests.testFailedEntryIsClosedWhenAbandoned") { try ControllerTests().testFailedEntryIsClosedWhenAbandoned() }
test("ControllerTests.testRetryDoesNotCloseTargetApp") { try ControllerTests().testRetryDoesNotCloseTargetApp() }
test("ControllerTests.testDisabledPlatformFlagsAndZenAreNoops") { try ControllerTests().testDisabledPlatformFlagsAndZenAreNoops() }
test("ControllerTests.testVPNAppCleanupByMode") { try ControllerTests().testVPNAppCleanupByMode() }
test("ControllerTests.testFailedDisconnectNeverQuitsProton") { try ControllerTests().testFailedDisconnectNeverQuitsProton() }
test("ControllerTests.testRefusedVPNQuitBlocksNextMode") { try ControllerTests().testRefusedVPNQuitBlocksNextMode() }
test("ControllerTests.testTailscaleStopFailurePreventsPrivateEntry") { try ControllerTests().testTailscaleStopFailurePreventsPrivateEntry() }
test("ControllerTests.testPrivateReselectPreservesMonitorFailure") { try ControllerTests().testPrivateReselectPreservesMonitorFailure() }
test("ControllerTests.testSameModeReconcileFailureIsReported") { try ControllerTests().testSameModeReconcileFailureIsReported() }
test("ControllerTests.testPreflightFailureDoesNotCloseUnenteredApp") { try ControllerTests().testPreflightFailureDoesNotCloseUnenteredApp() }
test("ControllerTests.testPreflightFailurePreservesAbandonedEntryCleanup") { try ControllerTests().testPreflightFailurePreservesAbandonedEntryCleanup() }
test("ControllerTests.testExternalExitRequiresConfirmation") { try ControllerTests().testExternalExitRequiresConfirmation() }
test("ControllerTests.testPrivateRetryFailurePreservesMonitoring") { try ControllerTests().testPrivateRetryFailurePreservesMonitoring() }
test("ControllerTests.testQuitFailurePreservesMonitoring") { try ControllerTests().testQuitFailurePreservesMonitoring() }
test("ControllerTests.testLegacyRecoveryMigrates") { try ControllerTests().testLegacyRecoveryMigrates() }
test("ControllerTests.testT3RestartDebounceAndProtectedModes") { try ControllerTests().testT3RestartDebounceAndProtectedModes() }
test("ControllerTests.testBadConfigStillChecksPrivacy") { try ControllerTests().testBadConfigStillChecksPrivacy() }
print("\(tests) tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
