using System;
using System.IO;
using Xunit;

namespace RvtMcp.Tests
{
    public class SmokeHarnessContractTests
    {
        private static readonly string RepoRoot = FindRepoRoot();
        private static readonly string Script = File.ReadAllText(
            Path.Combine(RepoRoot, "scripts", "revit-2026-smoke.ps1"));
        private static readonly string StatisticsHandler = File.ReadAllText(
            Path.Combine(RepoRoot, "src", "shared", "Handlers", "AnalyzeModelStatisticsHandler.cs"));

        [Fact]
        public void Harness_defaults_to_read_only_preflight_and_skip_deploy_builds()
        {
            Assert.Contains("[string]$Phase = 'Preflight'", Script);
            Assert.Contains("[string]$Profile = 'read-only'", Script);
            Assert.Contains("-p:RvtMcpSkipDeploy=true", Script);
            Assert.Contains("[switch]$ApproveAddinChange", Script);
            Assert.Contains("[switch]$ApproveModelChanges", Script);
        }

        [Fact]
        public void Harness_uses_inactive_manifest_names_and_exact_process_ownership()
        {
            Assert.Contains(".addin.disabled", Script);
            Assert.Contains(".addin.tmp", Script);
            Assert.Contains("Assert-OwnedServerProcess", Script);
            Assert.Contains("server-starting.json", Script);
            Assert.Contains("$state.status = 'ServerStarted'", Script);
            Assert.Contains("startTimeUtc", Script);
            Assert.Contains("sha256 = $sourceHash", Script);
            Assert.Contains("runtime = $currentRuntime", Script);
            Assert.Contains("RvtMcp.Server.dll", Script);
            Assert.Contains("RvtMcp.Server.deps.json", Script);
            Assert.Contains("RvtMcp.Server.runtimeconfig.json", Script);
            Assert.Contains("Assert-InventoryMatches -Expected $ServerRecord.runtime", Script);
            Assert.DoesNotContain("Stop-Process -Name", Script);
            Assert.False(Script.Contains("taskkill", StringComparison.OrdinalIgnoreCase));
        }

        [Fact]
        public void Deploy_rollback_only_moves_targets_owned_by_this_run()
        {
            Assert.Contains("[bool]$PluginPayloadDeployed", Script);
            Assert.Contains("[bool]$ManifestPayloadDeployed", Script);
            Assert.Contains("if ($PluginPayloadDeployed)", Script);
            Assert.Contains("if ($ManifestPayloadDeployed)", Script);
            Assert.Contains("active manifest is not the smoke payload this run placed there", Script);
            Assert.Contains("owned deployed plugin during rollback", Script);
            Assert.Contains("early-deploy-failure", Script);
            Assert.Contains("deployTransitions", Script);
            Assert.Contains("Get-DeployRecoveryPlan", Script);
            Assert.Contains("Invoke-InterruptedDeployRecovery", Script);
            Assert.Contains("interrupted-deploy", Script);
            Assert.DoesNotContain("if (Test-Path -LiteralPath $paths.manifestTarget) { Move-Item", Script);
            Assert.DoesNotContain("if (Test-Path -LiteralPath $paths.pluginTarget) { Move-Item", Script);
        }

        [Fact]
        public void Restore_and_server_start_are_transition_journaled()
        {
            Assert.Contains("$State.status = 'ServerStarting'", Script);
            Assert.Contains("server-starting.json", Script);
            Assert.Contains("$state.status = 'Restoring'", Script);
            Assert.Contains("Invoke-InterruptedRestoreCompletion", Script);
            Assert.Contains("unverified-partial-stage-", Script);
            Assert.Contains("interrupted restore owned staging path", Script);
            Assert.Contains("pluginArchived = $false", Script);
            Assert.Contains("manifestRestored = $false", Script);
            Assert.Contains("function Set-ObjectProperty", Script);
            Assert.Contains("Set-ObjectProperty -Object $state -Name 'restore'", Script);
            Assert.Contains("new recovery properties could not be added to JSON-deserialized state", Script);
            Assert.DoesNotContain("$state.restore = [ordered]", Script);

            var start = Script.IndexOf("function Start-OwnedHttpServer", StringComparison.Ordinal);
            var end = Script.IndexOf("function Start-OrReuseRevit", start, StringComparison.Ordinal);
            var function = Script.Substring(start, end - start);
            Assert.True(
                function.IndexOf("Save-ActiveState $State", StringComparison.Ordinal) <
                function.IndexOf("Start-Sleep -Milliseconds 200", StringComparison.Ordinal),
                "Server ownership must be persisted before the startup sleep/readiness checks.");
        }

        [Fact]
        public void Harness_checks_stateless_http_and_preserves_user_model_control()
        {
            Assert.Contains("Mcp-Session-Id", Script);
            Assert.Contains("$headers['Mcp-Name'] = $mcpName", Script);
            Assert.Contains("/sse", Script);
            Assert.Contains("$toolNames -contains 'revit_workflow_model_audit'", Script);
            Assert.Contains("'revit_batch_execute'", Script);
            Assert.Contains("'revit_create_view'", Script);
            Assert.Contains("'revit_set_project_info'", Script);
            Assert.Contains("'revit_purge_unused'", Script);
            foreach (var forbidden in new[]
            {
                "revit_delete_element",
                "revit_unload_family",
                "revit_purge_unused",
                "revit_wipe_empty_tags",
                "revit_remove_filter_from_view",
                "revit_unload_link",
                "revit_remove_parameter_binding",
                "revit_delete_view_template",
                "revit_delete_saved_selection",
                "revit_workflow_view_cleanup"
            })
            {
                Assert.Contains($"'{forbidden}'", Script);
            }
            Assert.Contains("Copy-Item -LiteralPath $sourceModel -Destination $copiedModel", Script);
            Assert.Contains("The harness never saves, closes, deletes, or discards the copied model", Script);
            Assert.False(Script.Contains("SaveAs(", StringComparison.OrdinalIgnoreCase));
            Assert.False(Script.Contains("Close(false", StringComparison.OrdinalIgnoreCase));
            Assert.Contains("$floorCategory -eq 'Structural Foundations'", Script);
            Assert.Contains("$floorCategory -ne 'Floors'", Script);
            Assert.Contains("rollbackLevelId", Script);
            Assert.Contains("temporary level $rollbackLevelId still resolves", Script);
            Assert.Contains("command = 'create_grid'", Script);
            Assert.DoesNotContain("cria_expected_failure", Script);
            Assert.Contains("Assert-CompleteModelStatistics -Statistics $afterRollbackStats", Script);
            Assert.Contains("Assert-McpJsonRpcSuccess -Parsed $parsed", Script);
            Assert.DoesNotContain("$parsed.error", Script);
        }

        [Fact]
        public void Running_state_can_resume_only_the_exact_owned_session_with_separate_evidence()
        {
            Assert.Contains("function Assert-RunningSessionForResume", Script);
            Assert.Contains("$isResume = [string]$state.status -eq 'Running'", Script);
            Assert.Contains("Assert-RunningSessionForResume -State $state", Script);
            Assert.Contains("Assert-OwnedServerProcess $State.server", Script);
            Assert.Contains("Assert-RevitSessionIdentity $State", Script);
            Assert.Contains("Run resume must use recorded HTTP port", Script);
            Assert.Contains("Run resume must use recorded profile", Script);
            Assert.Contains("http-attempt-$attemptId", Script);
            Assert.Contains("failure.json", Script);
            Assert.Contains("Assert-RunResumeHasNoAmbiguousAuthoring", Script);
            Assert.Contains("found authoring-step evidence but no recorded authoring state", Script);
            Assert.Contains("Assert-ExactPath -Actual ([string]$statistics.documentPath)", Script);
        }

        [Fact]
        public void Process_start_times_survive_json_round_trip_without_local_offset_shift()
        {
            Assert.Contains("function ConvertTo-UtcDateTime", Script);
            Assert.Contains("$Value -is [datetimeoffset]", Script);
            Assert.Contains("$Value -is [datetime]", Script);
            Assert.Contains("[System.Globalization.DateTimeStyles]::RoundtripKind", Script);
            Assert.DoesNotContain("[datetime]::Parse([string]$ServerRecord.startTimeUtc)", Script);
            Assert.DoesNotContain("[datetime]::Parse([string]$State.revit.startTimeUtc)", Script);
            Assert.Contains("JSON round-trip changed the recorded UTC process start time", Script);
        }

        [Fact]
        public void Authoring_reads_the_current_view_level_without_strict_mode_property_failures()
        {
            Assert.Contains("foreach ($propertyName in @('levelName', 'level'))", Script);
            Assert.Contains("$view.PSObject.Properties[$propertyName]", Script);
            Assert.Contains("Active view has no level", Script);
        }

        [Fact]
        public void Authoring_selects_an_empty_physical_volume_before_any_model_write()
        {
            Assert.Contains("function Find-AuthoringPlacement", Script);
            Assert.Contains("revit_find_elements_in_volume", Script);
            Assert.Contains("09b-placement-probe-{0:D2}", Script);
            Assert.Contains("09c-placement-selection.json", Script);
            Assert.Contains("@('OST_Walls', 'OST_Floors', 'OST_StructuralFoundation')", Script);
            Assert.DoesNotContain("@('OST_Walls', 'OST_Floors', 'OST_StructuralFoundation', 'OST_Grids')", Script);
            Assert.Contains("No empty authoring placement was found", Script);
            Assert.Contains("$placement = Find-AuthoringPlacement", Script);
            Assert.Contains("New-AuthoringCommands -OffsetX ([double]$placement.offsetX)", Script);
            Assert.Contains("placement = $placement", Script);

            var placementIndex = Script.IndexOf("$placement = Find-AuthoringPlacement", StringComparison.Ordinal);
            var rollbackIndex = Script.IndexOf("10-rollback-batch", placementIndex, StringComparison.Ordinal);
            Assert.True(placementIndex >= 0 && rollbackIndex > placementIndex,
                "The read-only placement probe must finish before the first model-changing batch.");
        }

        [Fact]
        public void Undo_verification_revalidates_revit_process_document_and_complete_counts()
        {
            Assert.Contains("Assert-RevitSessionIdentity $state", Script);
            Assert.Contains("$discovery.pid -ne $pidValue", Script);
            Assert.Contains("$statistics.projectName", Script);
            Assert.Contains("documentPath = doc.PathName", StatisticsHandler);
            Assert.Contains("Assert-ExactPath -Actual ([string]$baseline.documentPath)", Script);
            Assert.Contains("Assert-ExactPath -Actual ([string]$statistics.documentPath)", Script);
            Assert.Contains("not recorded copied model", Script);
            Assert.Contains("Assert-CompleteModelStatistics -Statistics $statistics", Script);
            Assert.Contains("[bool]$Statistics.truncated", Script);
            Assert.Contains("Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoVerified'", Script);
            Assert.Contains("Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoVerifiedUtc'", Script);
            Assert.Contains("Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoRequired' -Value $false", Script);
            Assert.Contains("UNDO_INSTRUCTIONS.archived.txt", Script);
            Assert.Contains("Move-Item -LiteralPath $undoRequiredMarker -Destination $archivedUndoInstructions", Script);
            Assert.Contains("$state.smoke.authoring.PSObject.Properties['undoVerified']", Script);
            Assert.Contains("Undo was already verified for this run; no MCP calls were repeated.", Script);
            Assert.True(
                Script.IndexOf("Undo was already verified for this run", StringComparison.Ordinal) <
                Script.IndexOf("EvidenceName '16-after-undo-session-statistics'", StringComparison.Ordinal));
            Assert.Contains("Set-ObjectProperty -Object $deserializedState.smoke.authoring -Name 'undoVerified'", Script);
            Assert.Contains("Set-ObjectProperty -Object $deserializedState.smoke.authoring -Name 'undoRequired' -Value $false", Script);
            Assert.Contains("new undo verification properties could not be added to JSON-deserialized authoring state", Script);
            Assert.DoesNotContain("$state.smoke.authoring.undoVerified =", Script);
            Assert.DoesNotContain("$state.smoke.authoring.undoRequired =", Script);
        }

        [Fact]
        public void Harness_prefers_and_records_repo_local_dotnet()
        {
            Assert.Contains(".dotnet\\dotnet.exe", Script);
            Assert.Contains("Get-Command dotnet -CommandType Application", Script);
            Assert.Contains("dotnet = $dotnet", Script);
        }

        [Fact]
        public void Live_smoke_operator_guide_is_present()
        {
            var guide = Path.Combine(RepoRoot, "docs", "testing", "revit-2026-live-smoke.md");
            Assert.True(File.Exists(guide), $"Missing live smoke guide: {guide}");
        }

        private static string FindRepoRoot()
        {
            var directory = new DirectoryInfo(AppContext.BaseDirectory);
            while (directory != null)
            {
                if (File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
                {
                    return directory.FullName;
                }

                directory = directory.Parent;
            }

            throw new InvalidOperationException("Could not find the repository root containing AGENTS.md.");
        }
    }
}
