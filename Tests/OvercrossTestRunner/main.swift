import Foundation
@testable import OvercrossCore

@main
struct OvercrossTestApp {
    static func main() async {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print(" Ludus Test Suite Execution")
        print(" Target: Apple Silicon (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

        var passedCount = 0
        var failedCount = 0
        let suiteStart = Date()

        func runTest(name: String, block: (GameLibraryStoreTests) throws -> Void) {
            let suite = GameLibraryStoreTests()
            let start = Date()
            let initialFailures = testFailuresCount
            do {
                try suite.setUp()
                try block(suite)
                try suite.tearDown()
                let elapsed = Date().timeIntervalSince(start)
                if testFailuresCount == initialFailures {
                    passedCount += 1
                    print("  ✓ \(name) (\(String(format: "%.3f", elapsed))s)")
                } else {
                    failedCount += 1
                    print("  ✗ \(name) (\(String(format: "%.3f", elapsed))s) [FAILED]")
                }
            } catch {
                failedCount += 1
                let elapsed = Date().timeIntervalSince(start)
                print("  ✗ \(name) (\(String(format: "%.3f", elapsed))s) [THREW: \(error)]")
            }
        }

        func runAsyncTest(name: String, block: (GameLibraryStoreTests) async throws -> Void) async {
            let suite = GameLibraryStoreTests()
            let start = Date()
            let initialFailures = testFailuresCount
            do {
                try suite.setUp()
                try await block(suite)
                try suite.tearDown()
                let elapsed = Date().timeIntervalSince(start)
                if testFailuresCount == initialFailures {
                    passedCount += 1
                    print("  ✓ \(name) (\(String(format: "%.3f", elapsed))s)")
                } else {
                    failedCount += 1
                    print("  ✗ \(name) (\(String(format: "%.3f", elapsed))s) [FAILED]")
                }
            } catch {
                failedCount += 1
                let elapsed = Date().timeIntervalSince(start)
                print("  ✗ \(name) (\(String(format: "%.3f", elapsed))s) [THREW: \(error)]")
            }
        }

        // Synchronous tests
        runTest(name: "testWindowsLaunchResolvesNestedUnrealExecutable") { try $0.testWindowsLaunchResolvesNestedUnrealExecutable() }
        runTest(name: "testWindowsLaunchRecognizesPE32ExecutableInsideWin64Prefix") { try $0.testWindowsLaunchRecognizesPE32ExecutableInsideWin64Prefix() }
        runTest(name: "testPE32AndPE32PlusDetection") { try $0.testPE32AndPE32PlusDetection() }
        runTest(name: "testAudioRepairRejectsUnknownBinaryWithoutMutation") { try $0.testAudioRepairRejectsUnknownBinaryWithoutMutation() }
        runTest(name: "testAudioDiagnosticsDetection") { try $0.testAudioDiagnosticsDetection() }
        runTest(name: "testAudioRepairStagingAndRollbackPreservesSourceRuntime") { try $0.testAudioRepairStagingAndRollbackPreservesSourceRuntime() }
        runTest(name: "testSettingsDecodePreservesOlderSavedShape") { try $0.testSettingsDecodePreservesOlderSavedShape() }
        runTest(name: "testSettingsRoundTripPreservesExplicitEpicPrerequisiteChoice") { try $0.testSettingsRoundTripPreservesExplicitEpicPrerequisiteChoice() }
        runTest(name: "testLibraryRoundTripsARealGameRecord") { try $0.testLibraryRoundTripsARealGameRecord() }
        runTest(name: "testOlderGameRecordsDefaultToUnconfirmedOwnershipEvidence") { try $0.testOlderGameRecordsDefaultToUnconfirmedOwnershipEvidence() }
        runTest(name: "testGamePlatformInferenceIsConservative") { $0.testGamePlatformInferenceIsConservative() }
        runTest(name: "testDownloadOperationStoreRoundTripsAndBoundsHistory") { try $0.testDownloadOperationStoreRoundTripsAndBoundsHistory() }
        runTest(name: "testDownloadOperationRunningStateCanBeMarkedForRecovery") { $0.testDownloadOperationRunningStateCanBeMarkedForRecovery() }
        runTest(name: "testAccountBackedOwnershipEvidenceSurvivesLibraryRoundTrip") { try $0.testAccountBackedOwnershipEvidenceSurvivesLibraryRoundTrip() }
        runTest(name: "testLibraryMergePromotesAContainedLocalExecutableWithoutCreatingADuplicate") { $0.testLibraryMergePromotesAContainedLocalExecutableWithoutCreatingADuplicate() }
        runTest(name: "testLibraryMergeDoesNotUseSimilarTitlesToCombineDifferentInstallations") { $0.testLibraryMergeDoesNotUseSimilarTitlesToCombineDifferentInstallations() }
        runTest(name: "testImportsOnlyTheSelectedSteamLibraryManifests") { try $0.testImportsOnlyTheSelectedSteamLibraryManifests() }
        runTest(name: "testSteamManifestRecordsAnInstallationOnlyWhenTheDirectoryExists") { try $0.testSteamManifestRecordsAnInstallationOnlyWhenTheDirectoryExists() }
        runTest(name: "testImportsExistingHeroicInstallationEvidenceWithoutCredentials") { try $0.testImportsExistingHeroicInstallationEvidenceWithoutCredentials() }
        runTest(name: "testHeroicLaunchURLUsesTheSupportedQueryProtocol") { try $0.testHeroicLaunchURLUsesTheSupportedQueryProtocol() }
        runTest(name: "testHeroicImportRecordsTheSelectedLegendaryConfigurationDirectory") { $0.testHeroicImportRecordsTheSelectedLegendaryConfigurationDirectory() }
        runTest(name: "testHeroicInstallArgumentsUseTheMaintainedLegendaryInstallShape") { try $0.testHeroicInstallArgumentsUseTheMaintainedLegendaryInstallShape() }
        runTest(name: "testHeroicInstallCanExplicitlyAllowPrerequisiteInstallers") { try $0.testHeroicInstallCanExplicitlyAllowPrerequisiteInstallers() }
        runTest(name: "testHeroicInstallRejectsPathLikeApplicationNames") { $0.testHeroicInstallRejectsPathLikeApplicationNames() }
        runTest(name: "testHeroicLibraryDecodesAccountEntriesAndOmitsDLC") { try $0.testHeroicLibraryDecodesAccountEntriesAndOmitsDLC() }
        runTest(name: "testHeroicLibraryUsesTheMaintainedListArguments") { $0.testHeroicLibraryUsesTheMaintainedListArguments() }
        runTest(name: "testHeroicGameInfoUsesTheWindowsJSONMetadataArguments") { try $0.testHeroicGameInfoUsesTheWindowsJSONMetadataArguments() }
        runTest(name: "testHeroicGameInfoDecodesDownloadAndDiskSizes") { try $0.testHeroicGameInfoDecodesDownloadAndDiskSizes() }
        runTest(name: "testHeroicGameInfoRejectsMissingSizeMetadata") { $0.testHeroicGameInfoRejectsMissingSizeMetadata() }
        runTest(name: "testHeroicInstallVerificationRequiresRecordedNonEmptyFiles") { try $0.testHeroicInstallVerificationRequiresRecordedNonEmptyFiles() }
        runTest(name: "testHeroicInstallVerificationRejectsAnInstallationOutsideTheSelectedBase") { try $0.testHeroicInstallVerificationRejectsAnInstallationOutsideTheSelectedBase() }
        runTest(name: "testHeroicUpdateArgumentsOnlyUpdateExistingInstallations") { try $0.testHeroicUpdateArgumentsOnlyUpdateExistingInstallations() }
        runTest(name: "testHeroicMoveArgumentsValidateTheDestination") { try $0.testHeroicMoveArgumentsValidateTheDestination() }
        runTest(name: "testHeroicUninstallReadsOnlyInstalledEntryNames") { try $0.testHeroicUninstallReadsOnlyInstalledEntryNames() }
        runTest(name: "testHeroicUninstallArgumentsRequireConfirmationMode") { try $0.testHeroicUninstallArgumentsRequireConfirmationMode() }
        runTest(name: "testRuntimeInspectionUsesTheSelectedExecutableAndSiblingWineboot") { try $0.testRuntimeInspectionUsesTheSelectedExecutableAndSiblingWineboot() }
        runTest(name: "testRuntimeIdentifierIsStableForTheSameExecutablePath") { $0.testRuntimeIdentifierIsStableForTheSameExecutablePath() }
        runTest(name: "testSteamOpenIDFormEncodingEscapesSpecialCharactersCorrectly") { $0.testSteamOpenIDFormEncodingEscapesSpecialCharactersCorrectly() }
        runTest(name: "testSteamLibraryImporterDiscoversAvailableDefaultLibraries") { $0.testSteamLibraryImporterDiscoversAvailableDefaultLibraries() }
        runTest(name: "testSteamLaunchURLUsesTheOfficialRunProtocol") { try $0.testSteamLaunchURLUsesTheOfficialRunProtocol() }
        runTest(name: "testSteamOpenIDAuthorizationURLUsesTheDelegatedCallbackContract") { try $0.testSteamOpenIDAuthorizationURLUsesTheDelegatedCallbackContract() }
        runTest(name: "testSteamOpenIDCallbackRequiresTheInitiatedSteamEndpointAndRealm") { try $0.testSteamOpenIDCallbackRequiresTheInitiatedSteamEndpointAndRealm() }
        runTest(name: "testSteamOpenIDExtractsOnlyNumericSteamIDsFromClaimedIDs") { try $0.testSteamOpenIDExtractsOnlyNumericSteamIDsFromClaimedIDs() }
        await runAsyncTest(name: "testSteamLoopbackListenerBindsToValidPortAndReceivesCallback") { try await $0.testSteamLoopbackListenerBindsToValidPortAndReceivesCallback() }
        runTest(name: "testSteamWebAPIDecodesVisibleOwnedGamesWithoutAppData") { try $0.testSteamWebAPIDecodesVisibleOwnedGamesWithoutAppData() }
        runTest(name: "testSteamWebAPIRequestUsesValidGETShape") { try $0.testSteamWebAPIRequestUsesValidGETShape() }
        runTest(name: "testPrefixArchiveRestoresAndRemovesOnlyManagedPrefix") { try $0.testPrefixArchiveRestoresAndRemovesOnlyManagedPrefix() }
        runTest(name: "testProfileSelectionRequiresExactVerifiedStoreMatch") { $0.testProfileSelectionRequiresExactVerifiedStoreMatch() }
        runTest(name: "testCompatibilityProfileRequiresRecordedTestEnvironmentEvidence") { $0.testCompatibilityProfileRequiresRecordedTestEnvironmentEvidence() }
        runTest(name: "testCompatibilityProfileStoreImportsISO8601ProfileLists") { try $0.testCompatibilityProfileStoreImportsISO8601ProfileLists() }
        runTest(name: "testRuntimeStoreRoundTripsUserSelectedRuntimeRecords") { try $0.testRuntimeStoreRoundTripsUserSelectedRuntimeRecords() }
        runTest(name: "testRuntimeBundleInstallerVerifiesChecksumAndCopiesBundle") { try $0.testRuntimeBundleInstallerVerifiesChecksumAndCopiesBundle() }
        runTest(name: "testRuntimeBundleInstallerRejectsChecksumMismatch") { try $0.testRuntimeBundleInstallerRejectsChecksumMismatch() }
        runTest(name: "testLaunchLogStoreBoundsStreamsAndRoundTrips") { try $0.testLaunchLogStoreBoundsStreamsAndRoundTrips() }
        runTest(name: "testStorageUsageMeasuresInstalledGameFiles") { try $0.testStorageUsageMeasuresInstalledGameFiles() }
        runTest(name: "testApplicationCacheCleanupRemovesOnlyOwnedCacheContents") { try $0.testApplicationCacheCleanupRemovesOnlyOwnedCacheContents() }
        runTest(name: "testApplicationCacheCleanupRejectsAFileAsItsRoot") { try $0.testApplicationCacheCleanupRejectsAFileAsItsRoot() }
        runTest(name: "testApplicationCacheCleanupRejectsASymbolicLinkRoot") { try $0.testApplicationCacheCleanupRejectsASymbolicLinkRoot() }
        runTest(name: "testSteamArtworkPortraitAndHeaderURLs") { $0.testSteamArtworkPortraitAndHeaderURLs() }
        runTest(name: "testHeroicArtworkExtractionFromLegendaryMetadata") { try $0.testHeroicArtworkExtractionFromLegendaryMetadata() }
        runTest(name: "testAppSettingsAppleSiliconPerformanceDefaultsAndRoundTrip") { try $0.testAppSettingsAppleSiliconPerformanceDefaultsAndRoundTrip() }
        runTest(name: "testGameCustomLaunchArgumentsAndEnvironmentOverridesRoundTrip") { try $0.testGameCustomLaunchArgumentsAndEnvironmentOverridesRoundTrip() }
        runTest(name: "testWinePrefixServiceInspectsComponents") { try $0.testWinePrefixServiceInspectsComponents() }
        runTest(name: "testRuntimeDiagnosticsDetectWineAndCandidatePaths") { $0.testRuntimeDiagnosticsDetectWineAndCandidatePaths() }
        runTest(name: "testConnectedGamepadProperties") { $0.testConnectedGamepadProperties() }

        // Async tests
        await runAsyncTest(name: "testLaunchRejectsMissingExecutableInsteadOfInventingSuccess") {
            await $0.testLaunchRejectsMissingExecutableInsteadOfInventingSuccess()
        }
        await runAsyncTest(name: "testPrefixCreationRejectsPathTraversalNames") {
            await $0.testPrefixCreationRejectsPathTraversalNames()
        }
        await runAsyncTest(name: "testWindowsLaunchRequiresARealRuntime") {
            try await $0.testWindowsLaunchRequiresARealRuntime()
        }
        await runAsyncTest(name: "testWindowsLaunchRejectsAnUnverifiedPrefix") {
            try await $0.testWindowsLaunchRejectsAnUnverifiedPrefix()
        }
        await runAsyncTest(name: "testWindowsLaunchProcessHarnessCapturesConfigurationAndOutput") {
            try await $0.testWindowsLaunchProcessHarnessCapturesConfigurationAndOutput()
        }
        await runAsyncTest(name: "testWindowsLaunchRejectsAProfileForADifferentExecutable") {
            try await $0.testWindowsLaunchRejectsAProfileForADifferentExecutable()
        }
        await runAsyncTest(name: "testWindowsLaunchRejectsAProfileThatRequiresAnExternalLauncher") {
            try await $0.testWindowsLaunchRejectsAProfileThatRequiresAnExternalLauncher()
        }
        await runAsyncTest(name: "testWindowsLaunchRejectsAProfileForADifferentPrefix") {
            try await $0.testWindowsLaunchRejectsAProfileForADifferentPrefix()
        }
        await runAsyncTest(name: "testWinePrefixArchiveCreatesZipBackup") {
            try await $0.testWinePrefixArchiveCreatesZipBackup()
        }
        await runAsyncTest(name: "testWinePrefixPreflightRedistributables") {
            try await $0.testWinePrefixPreflightRedistributables()
        }
        await runAsyncTest(name: "testWindowsLaunchProcessHarnessCapturesPerformanceEnvironmentAndCustomArgs") {
            try await $0.testWindowsLaunchProcessHarnessCapturesPerformanceEnvironmentAndCustomArgs()
        }
        await runAsyncTest(name: "testNativeGameLaunchPassesCustomArgumentsAndEnvironment") {
            try await $0.testNativeGameLaunchPassesCustomArgumentsAndEnvironment()
        }
        await runAsyncTest(name: "testWindowsLaunchExplicitlyDisablesPerformanceOverridesWhenSetToFalse") {
            try await $0.testWindowsLaunchExplicitlyDisablesPerformanceOverridesWhenSetToFalse()
        }
        await runAsyncTest(name: "testWindowsLaunchBypassesAudioRepairFor64BitExecutable") {
            try await $0.testWindowsLaunchBypassesAudioRepairFor64BitExecutable()
        }
        await runAsyncTest(name: "testWinePrefixArchiveCreateDirectoryZipBackup") {
            try await $0.testWinePrefixArchiveCreateDirectoryZipBackup()
        }

        // Autonomous Windows Gaming Hub Tests
        runTest(name: "testAntiCheatRegistryDetectsKernelAntiCheatTitles") { $0.testAntiCheatRegistryDetectsKernelAntiCheatTitles() }
        await runAsyncTest(name: "testRuntimeBootstrapServiceProvisionsEnvironment") { try await $0.testRuntimeBootstrapServiceProvisionsEnvironment() }
        await runAsyncTest(name: "testWineBottleServiceInitializesDefaultBottleWithRedistributables") { try await $0.testWineBottleServiceInitializesDefaultBottleWithRedistributables() }
        runTest(name: "testEpicServiceDecodesWindowsGamesAndFiltersDLCs") { try $0.testEpicServiceDecodesWindowsGamesAndFiltersDLCs() }
        runTest(name: "testEpicServiceExtractsJSONDataWithPrefixLogLines") { try $0.testEpicServiceExtractsJSONDataWithPrefixLogLines() }
        runTest(name: "testEpicServiceRejectsMockDummyUserJSON") { try $0.testEpicServiceRejectsMockDummyUserJSON() }
        runTest(name: "testSteamServicePreparesOfflineAppIDLaunch") { try $0.testSteamServicePreparesOfflineAppIDLaunch() }
        runTest(name: "testHeroicInstallProgressParsesResumeAndOverallProgress") { try $0.testHeroicInstallProgressParsesResumeAndOverallProgress() }
        runTest(name: "testHeroicInstallVerificationFailsWhenResumeFileStillExists") { try $0.testHeroicInstallVerificationFailsWhenResumeFileStillExists() }
        runTest(name: "testDownloadOperationStateSupportsPaused") { try $0.testDownloadOperationStateSupportsPaused() }
        runTest(name: "testHeroicDeleteDownloadDataRemovesResumeAndJsonFiles") { try $0.testHeroicDeleteDownloadDataRemovesResumeAndJsonFiles() }

        // CrossOver Boost & Bottle Service Tests
        await runAsyncTest(name: "testGraphicsBackendDXMTAndCrossOverEnvironmentVariables") { try await $0.testGraphicsBackendDXMTAndCrossOverEnvironmentVariables() }
        await runAsyncTest(name: "testAutomatedRedistributableAndDependencyRepair") { try await $0.testAutomatedRedistributableAndDependencyRepair() }
        await runAsyncTest(name: "testForceStopAndCleanResetBottle") { try await $0.testForceStopAndCleanResetBottle() }
        runTest(name: "testRetinaDisplayModeToggleAndRegistrySync") { try $0.testRetinaDisplayModeToggleAndRegistrySync() }
        await runAsyncTest(name: "testWinePrefixArchiveCxarchiveBackupAndRestore") { try await $0.testWinePrefixArchiveCxarchiveBackupAndRestore() }
        runTest(name: "testWineToolEnumMetadataAndCases") { $0.testWineToolEnumMetadataAndCases() }
        runTest(name: "testEpicServiceFindApplicationID") { try $0.testEpicServiceFindApplicationID() }
        await runAsyncTest(name: "testEpicServiceGetLaunchArguments") { try await $0.testEpicServiceGetLaunchArguments() }
        runTest(name: "testGitHubUpdateServiceVersionComparison") { $0.testGitHubUpdateServiceVersionComparison() }
        runTest(name: "testLogSanitizerScrubsPII") { $0.testLogSanitizerScrubsPII() }
        runTest(name: "testAnonymousDiagnosticPayloadGeneration") { $0.testAnonymousDiagnosticPayloadGeneration() }
        runTest(name: "testDiagnosticsConsentAndSettingsPersistence") { $0.testDiagnosticsConsentAndSettingsPersistence() }
        runTest(name: "testAnonymousDiagnosticsLocalReportStorage") { $0.testAnonymousDiagnosticsLocalReportStorage() }

        // Game Optimization & GPU Utilization Tests
        runTest(name: "testGameOptimizationNeutralizesProblematicLibraries") { try $0.testGameOptimizationNeutralizesProblematicLibraries() }
        runTest(name: "testGameOptimizationEngineINISettings16GB") { try $0.testGameOptimizationEngineINISettings16GB() }
        runTest(name: "testGameOptimizationEngineINIPreservesExistingKeys") { try $0.testGameOptimizationEngineINIPreservesExistingKeys() }
        runTest(name: "testOptimalStreamingPoolMBForDifferentRAMSizes") { $0.testOptimalStreamingPoolMBForDifferentRAMSizes() }
        await runAsyncTest(name: "testWindowsLaunchInjectsGPUPerformanceAndOptimizationEnvironment") {
            try await $0.testWindowsLaunchInjectsGPUPerformanceAndOptimizationEnvironment()
        }
        runTest(name: "testWineBottleRegistrySyncMacDriverAndDirectInput") { try $0.testWineBottleRegistrySyncMacDriverAndDirectInput() }
        runTest(name: "testGameOptimizationNeutralizesProblematicLibrariesAndRestoresEssential") { try $0.testGameOptimizationNeutralizesProblematicLibrariesAndRestoresEssential() }
        runTest(name: "testGameOptimizationEngineINISettingsSafeForUnifiedMemory") { try $0.testGameOptimizationEngineINISettingsSafeForUnifiedMemory() }
        await runAsyncTest(name: "testWindowsLaunchInjectsNvidiaOverridesAndAudioProtectionEnvironment") {
            try await $0.testWindowsLaunchInjectsNvidiaOverridesAndAudioProtectionEnvironment()
        }

        let totalElapsed = Date().timeIntervalSince(suiteStart)
        print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print(" Results: \(passedCount) passed, \(failedCount) failed (\(String(format: "%.2f", totalElapsed))s total)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        if failedCount > 0 {
            exit(1)
        } else {
            exit(0)
        }
    }
}
