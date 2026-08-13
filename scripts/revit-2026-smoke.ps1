#Requires -Version 7.2
<#
.SYNOPSIS
  Runs a guarded, reversible Cria smoke session against Autodesk Revit 2026.

.DESCRIPTION
  Preflight is the default and is read-only. Build always uses
  RvtMcpSkipDeploy=true. Deploy and Restore require an explicit acknowledgement
  before they touch the Revit add-ins directory. Run starts only a server process
  owned by this harness and records enough identity data to stop that exact process
  later. A supplied RVT is copied into the ignored local artifact directory; the
  source model is never opened, saved, closed, deleted, or replaced by this script.

  Evidence and state stay under artifacts/live-smoke/ in this repository. That
  directory is gitignored.

.EXAMPLE
  pwsh scripts/revit-2026-smoke.ps1

.EXAMPLE
  pwsh scripts/revit-2026-smoke.ps1 -Phase Build

.EXAMPLE
  pwsh scripts/revit-2026-smoke.ps1 -Phase Deploy -WhatIf
  pwsh scripts/revit-2026-smoke.ps1 -Phase Deploy -ApproveAddinChange

.EXAMPLE
  pwsh scripts/revit-2026-smoke.ps1 -Phase Run -LaunchRevit -ModelPath C:\Models\CriaSeed.rvt

.EXAMPLE
  pwsh scripts/revit-2026-smoke.ps1 -Phase Run -LaunchRevit -ModelPath C:\Models\CriaSeed.rvt -RunAuthoring -ApproveModelChanges

.EXAMPLE
  pwsh scripts/revit-2026-smoke.ps1 -Phase Restore -StopOwnedServer -ApproveAddinChange
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Preflight', 'Build', 'Deploy', 'Run', 'VerifyUndo', 'Collect', 'Restore', 'SelfTest')]
    [string]$Phase = 'Preflight',

    [ValidateSet('read-only', 'safe-authoring')]
    [string]$Profile = 'read-only',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$')]
    [string]$RunId,

    [string]$RepoRoot,
    [string]$RevitExe = 'C:\Program Files\Autodesk\Revit 2026\Revit.exe',
    [string]$ModelPath,

    [ValidateRange(1, 65535)]
    [int]$HttpPort = 8200,

    [ValidateRange(5, 600)]
    [int]$WaitSeconds = 180,

    [switch]$LaunchRevit,
    [switch]$RunAuthoring,
    [switch]$ApproveModelChanges,
    [switch]$ApproveAddinChange,
    [switch]$StopOwnedServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$ArtifactRoot = Join-Path $RepoRoot 'artifacts\live-smoke'
$ActiveStatePath = Join-Path $ArtifactRoot 'active-deployment.json'
$ProtocolVersion = '2026-07-28'
$Script:McpRequestId = 0

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
}

function Assert-ExactPath {
    param(
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected,
        [string]$Label = 'path'
    )
    $a = Get-NormalizedPath $Actual
    $e = Get-NormalizedPath $Expected
    if (-not $a.Equals($e, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label mismatch. Expected '$e'; got '$a'."
    }
}

function Assert-PathUnder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent,
        [string]$Label = 'path'
    )
    $candidate = Get-NormalizedPath $Path
    $root = (Get-NormalizedPath $Parent) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under '$Parent'; got '$candidate'."
    }
}

function Assert-LocalFilesystemPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = 'path')
    $full = Get-NormalizedPath $Path
    if ($full.StartsWith('\\')) {
        throw "$Label must be on this workstation, not a UNC/network path: '$full'."
    }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) {
        throw "$Label is not a local drive path: '$full'."
    }
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = 'path')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $items = @((Get-Item -LiteralPath $Path -Force))
    if ((Get-Item -LiteralPath $Path -Force).PSIsContainer) {
        $items += @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
    }
    foreach ($item in $items) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label contains a junction or symbolic link, which the harness will not traverse: '$($item.FullName)'."
        }
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash)
}

function Get-TreeInventory {
    param([Parameter(Mandatory = $true)][string]$Root)
    $fullRoot = Get-NormalizedPath $Root
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
        return [pscustomobject]@{
            exists = $false
            root = $fullRoot
            fileCount = 0
            digest = $null
            files = @()
        }
    }

    Assert-NoReparsePoint -Path $fullRoot -Label 'inventory root'
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -Force -File -Recurse | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($fullRoot, $file.FullName).Replace('\', '/')
        $records += [pscustomobject]@{
            path = $relative
            length = [long]$file.Length
            sha256 = Get-Sha256 $file.FullName
        }
    }
    $material = ($records | ForEach-Object { '{0}|{1}|{2}' -f $_.path, $_.length, $_.sha256 }) -join "`n"
    return [pscustomobject]@{
        exists = $true
        root = $fullRoot
        fileCount = $records.Count
        digest = Get-TextSha256 $material
        files = $records
    }
}

function Assert-InventoryMatches {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [string]$Label = 'directory'
    )
    if ([bool]$Expected.exists -ne [bool]$Actual.exists) {
        throw "$Label existence changed. Expected $($Expected.exists); got $($Actual.exists)."
    }
    if (-not [bool]$Expected.exists) { return }
    if ([int]$Expected.fileCount -ne [int]$Actual.fileCount -or
        -not ([string]$Expected.digest).Equals([string]$Actual.digest, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label hash inventory mismatch. Expected $($Expected.fileCount) files / $($Expected.digest); got $($Actual.fileCount) files / $($Actual.digest)."
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Assert-NoReparsePoint -Path $Source -Label 'copy source'
    if (Test-Path -LiteralPath $Destination) {
        throw "Copy destination already exists: '$Destination'."
    }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file not found: '$Path'."
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    $existing = $Object.PSObject.Properties[$Name]
    if ($null -ne $existing) {
        $existing.Value = $Value
        return
    }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function New-SmokeRunId {
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Get-Paths {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is unavailable; the Revit add-ins directory cannot be resolved safely.'
    }
    $addinsRoot = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2026'
    $expectedAddinsRoot = [System.IO.Path]::Combine($env:APPDATA, 'Autodesk', 'Revit', 'Addins', '2026')
    Assert-ExactPath -Actual $addinsRoot -Expected $expectedAddinsRoot -Label 'Revit 2026 add-ins root'
    Assert-LocalFilesystemPath -Path $addinsRoot -Label 'Revit 2026 add-ins root'

    $paths = [pscustomobject]@{
        repoRoot = $RepoRoot
        artifactRoot = $ArtifactRoot
        revitExe = Get-NormalizedPath $RevitExe
        pluginProject = Join-Path $RepoRoot 'src\plugin-r26\RvtMcp.Plugin.R26.csproj'
        pluginOutput = Join-Path $RepoRoot 'src\plugin-r26\bin\Release\net8.0-windows7.0'
        pluginDll = Join-Path $RepoRoot 'src\plugin-r26\bin\Release\net8.0-windows7.0\RvtMcp.Plugin.dll'
        manifestSource = Join-Path $RepoRoot 'src\plugin-r26\RvtMcp.R26.addin'
        serverProject = Join-Path $RepoRoot 'src\server\RvtMcp.Server.csproj'
        serverOutput = Join-Path $RepoRoot 'src\server\bin\Release\net8.0'
        serverExe = Join-Path $RepoRoot 'src\server\bin\Release\net8.0\RvtMcp.Server.exe'
        testsProject = Join-Path $RepoRoot 'tests\RvtMcp.Tests\RvtMcp.Tests.csproj'
        addinsRoot = Get-NormalizedPath $addinsRoot
        manifestTarget = Join-Path $addinsRoot 'RvtMcp.R26.addin'
        pluginTarget = Join-Path $addinsRoot 'RvtMcp'
        discoveryFile = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { Join-Path $env:LOCALAPPDATA 'RvtMcp\revit-2026.json' }
        localDataRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { Join-Path $env:LOCALAPPDATA 'RvtMcp' }
    }

    Assert-PathUnder -Path $paths.pluginProject -Parent $RepoRoot -Label 'plugin project'
    Assert-PathUnder -Path $paths.serverProject -Parent $RepoRoot -Label 'server project'
    Assert-PathUnder -Path $paths.serverOutput -Parent $RepoRoot -Label 'server output'
    Assert-PathUnder -Path $paths.testsProject -Parent $RepoRoot -Label 'test project'
    Assert-ExactPath -Actual $paths.manifestTarget -Expected ([System.IO.Path]::Combine($expectedAddinsRoot, 'RvtMcp.R26.addin')) -Label 'manifest target'
    Assert-ExactPath -Actual $paths.pluginTarget -Expected ([System.IO.Path]::Combine($expectedAddinsRoot, 'RvtMcp')) -Label 'plugin target'
    return $paths
}

function Get-FileSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; path = Get-NormalizedPath $Path; length = 0; sha256 = $null }
    }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        exists = $true
        path = $item.FullName
        length = [long]$item.Length
        sha256 = Get-Sha256 $item.FullName
    }
}

function Get-ServerRuntimeInventory {
    param([Parameter(Mandatory = $true)]$Paths)
    foreach ($name in @('RvtMcp.Server.exe', 'RvtMcp.Server.dll', 'RvtMcp.Server.deps.json', 'RvtMcp.Server.runtimeconfig.json')) {
        $required = Join-Path ([string]$Paths.serverOutput) $name
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required server runtime file is missing: '$required'. Run -Phase Build first."
        }
    }
    Assert-NoReparsePoint -Path ([string]$Paths.serverOutput) -Label 'server runtime output'
    return Get-TreeInventory ([string]$Paths.serverOutput)
}

function Get-RevitProcesses {
    Write-Output -NoEnumerate @(Get-Process -Name Revit -ErrorAction SilentlyContinue)
}

function Assert-RevitClosed {
    $revit = Get-RevitProcesses
    if ($revit.Count -gt 0) {
        $ids = ($revit | Select-Object -ExpandProperty Id) -join ', '
        throw "Revit must be closed before this phase. Running Revit PID(s): $ids. The harness will not close Revit or discard any model."
    }
}

function Get-PluginPayloadFiles {
    param([Parameter(Mandatory = $true)]$Paths)
    if (-not (Test-Path -LiteralPath $Paths.pluginDll -PathType Leaf)) {
        throw "Revit 2026 plugin output is missing: '$($Paths.pluginDll)'. Run -Phase Build first."
    }

    $files = @()
    $rootPatterns = @(
        'RvtMcp.*.dll',
        'Newtonsoft.Json.dll',
        'Microsoft.Data.Sqlite.dll',
        'SQLitePCLRaw*.dll',
        'Microsoft.CodeAnalysis*.dll'
    )
    foreach ($pattern in $rootPatterns) {
        $files += @(Get-ChildItem -LiteralPath $Paths.pluginOutput -Filter $pattern -File -ErrorAction SilentlyContinue)
    }

    $nativeSqlite = Join-Path $Paths.pluginOutput 'runtimes\win-x64\native\e_sqlite3.dll'
    if (Test-Path -LiteralPath $nativeSqlite -PathType Leaf) {
        $files += Get-Item -LiteralPath $nativeSqlite
    }
    $files = @($files | Sort-Object FullName -Unique)
    if (-not ($files | Where-Object Name -eq 'RvtMcp.Plugin.dll')) {
        throw 'The staged payload does not contain RvtMcp.Plugin.dll.'
    }
    return $files
}

function Stage-PluginPayload {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$RunDirectory
    )
    $payloadRoot = Join-Path $RunDirectory 'payload'
    $payloadPlugin = Join-Path $payloadRoot 'RvtMcp'
    $payloadManifest = Join-Path $payloadRoot 'RvtMcp.R26.addin'
    if (Test-Path -LiteralPath $payloadRoot) {
        throw "Payload already staged for this run: '$payloadRoot'."
    }
    New-Item -ItemType Directory -Path $payloadPlugin -Force | Out-Null

    foreach ($file in @(Get-PluginPayloadFiles -Paths $Paths)) {
        $relative = [System.IO.Path]::GetRelativePath($Paths.pluginOutput, $file.FullName)
        $destination = Join-Path $payloadPlugin $relative
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        if ((Get-Sha256 $file.FullName) -ne (Get-Sha256 $destination)) {
            throw "Hash mismatch while staging '$relative'."
        }
    }

    Copy-Item -LiteralPath $Paths.manifestSource -Destination $payloadManifest
    return [pscustomobject]@{
        pluginRoot = $payloadPlugin
        manifest = $payloadManifest
        pluginInventory = Get-TreeInventory $payloadPlugin
        manifestSnapshot = Get-FileSnapshot $payloadManifest
    }
}

function Invoke-DeployTargetRollback {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$BeforePlugin,
        [Parameter(Mandatory = $true)]$BeforeManifest,
        [Parameter(Mandatory = $true)]$PayloadPlugin,
        [Parameter(Mandatory = $true)]$PayloadManifest,
        [Parameter(Mandatory = $true)][string]$OriginalPluginSibling,
        [Parameter(Mandatory = $true)][string]$OriginalManifestSibling,
        [Parameter(Mandatory = $true)][string]$StagePluginSibling,
        [Parameter(Mandatory = $true)][string]$StageManifestSibling,
        [Parameter(Mandatory = $true)][string]$FailureDirectory,
        [bool]$OriginalPluginMoved,
        [bool]$PluginPayloadDeployed,
        [bool]$OriginalManifestMoved,
        [bool]$ManifestPayloadDeployed
    )

    if ($ManifestPayloadDeployed) {
        $currentManifest = Get-FileSnapshot ([string]$Paths.manifestTarget)
        if (-not [bool]$currentManifest.exists -or
            -not ([string]$currentManifest.sha256).Equals([string]$PayloadManifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing deploy rollback: active manifest is not the smoke payload this run placed there.'
        }
        Move-Item -LiteralPath ([string]$Paths.manifestTarget) -Destination (Join-Path $FailureDirectory 'failed-deployed-manifest.addin')
    }
    if ($OriginalManifestMoved) {
        if (Test-Path -LiteralPath ([string]$Paths.manifestTarget)) {
            throw 'Refusing deploy rollback: manifest target is occupied before original restoration.'
        }
        $inactiveManifest = Get-FileSnapshot $OriginalManifestSibling
        if (-not [bool]$inactiveManifest.exists -or
            -not ([string]$inactiveManifest.sha256).Equals([string]$BeforeManifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing deploy rollback: inactive original manifest does not match the pre-deploy hash.'
        }
        Move-Item -LiteralPath $OriginalManifestSibling -Destination ([string]$Paths.manifestTarget)
    }

    if ($PluginPayloadDeployed) {
        Assert-InventoryMatches -Expected $PayloadPlugin -Actual (Get-TreeInventory ([string]$Paths.pluginTarget)) -Label 'owned deployed plugin during rollback'
        Move-Item -LiteralPath ([string]$Paths.pluginTarget) -Destination (Join-Path $FailureDirectory 'failed-deployed-plugin')
    }
    if ($OriginalPluginMoved) {
        if (Test-Path -LiteralPath ([string]$Paths.pluginTarget)) {
            throw 'Refusing deploy rollback: plugin target is occupied before original restoration.'
        }
        Assert-InventoryMatches -Expected $BeforePlugin -Actual (Get-TreeInventory $OriginalPluginSibling) -Label 'inactive original plugin during rollback'
        Move-Item -LiteralPath $OriginalPluginSibling -Destination ([string]$Paths.pluginTarget)
    }

    if (Test-Path -LiteralPath $StageManifestSibling -PathType Leaf) {
        $stagedManifest = Get-FileSnapshot $StageManifestSibling
        if (-not ([string]$stagedManifest.sha256).Equals([string]$PayloadManifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing deploy rollback: remaining staged manifest hash changed.'
        }
        Move-Item -LiteralPath $StageManifestSibling -Destination (Join-Path $FailureDirectory 'failed-staging-manifest.addin.tmp')
    }
    if (Test-Path -LiteralPath $StagePluginSibling -PathType Container) {
        Assert-InventoryMatches -Expected $PayloadPlugin -Actual (Get-TreeInventory $StagePluginSibling) -Label 'remaining staged plugin during rollback'
        Move-Item -LiteralPath $StagePluginSibling -Destination (Join-Path $FailureDirectory 'failed-staging-plugin')
    }

    $rollbackPlugin = Get-TreeInventory ([string]$Paths.pluginTarget)
    $rollbackManifest = Get-FileSnapshot ([string]$Paths.manifestTarget)
    Assert-InventoryMatches -Expected $BeforePlugin -Actual $rollbackPlugin -Label 'deploy rollback plugin'
    if ([bool]$BeforeManifest.exists) {
        if (-not [bool]$rollbackManifest.exists -or
            -not ([string]$rollbackManifest.sha256).Equals([string]$BeforeManifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Deploy failed and manifest rollback could not be hash-verified.'
        }
    } elseif ([bool]$rollbackManifest.exists) {
        throw 'Deploy failed and rollback left a manifest that did not exist before.'
    }
}

function Test-TreeInventoryEquivalent {
    param([Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)]$Actual)
    try {
        Assert-InventoryMatches -Expected $Expected -Actual $Actual -Label 'inventory comparison'
        return $true
    } catch {
        return $false
    }
}

function Test-FileSnapshotEquivalent {
    param([Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)]$Actual)
    if ([bool]$Expected.exists -ne [bool]$Actual.exists) { return $false }
    if (-not [bool]$Expected.exists) { return $true }
    return ([string]$Expected.sha256).Equals([string]$Actual.sha256, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DeployRecoveryPlan {
    param([Parameter(Mandatory = $true)]$State)
    $targetPlugin = Get-TreeInventory ([string]$State.paths.pluginTarget)
    $originalPlugin = Get-TreeInventory ([string]$State.paths.originalPluginSibling)
    $stagePlugin = Get-TreeInventory ([string]$State.paths.stagePluginSibling)
    $targetManifest = Get-FileSnapshot ([string]$State.paths.manifestTarget)
    $originalManifest = Get-FileSnapshot ([string]$State.paths.originalManifestSibling)
    $stageManifest = Get-FileSnapshot ([string]$State.paths.stageManifestSibling)

    $targetPluginIsBefore = Test-TreeInventoryEquivalent $State.before.plugin $targetPlugin
    $targetPluginIsPayload = Test-TreeInventoryEquivalent $State.source.plugin $targetPlugin
    $originalPluginIsBefore = Test-TreeInventoryEquivalent $State.before.plugin $originalPlugin
    $stagePluginIsPayload = Test-TreeInventoryEquivalent $State.source.plugin $stagePlugin
    if ([bool]$targetPlugin.exists -and -not $targetPluginIsBefore -and -not $targetPluginIsPayload) {
        throw 'Deploy recovery found an unrecognized plugin target hash; refusing to move it.'
    }
    if ([bool]$originalPlugin.exists -and -not $originalPluginIsBefore) {
        throw 'Deploy recovery found an unrecognized inactive original plugin hash.'
    }
    if ([bool]$stagePlugin.exists -and -not $stagePluginIsPayload) {
        throw 'Deploy recovery found an unrecognized staged plugin hash.'
    }
    if (-not [bool]$State.before.plugin.exists -and [bool]$originalPlugin.exists) {
        throw 'Deploy recovery found an inactive original plugin although no plugin existed before deployment.'
    }
    if ([bool]$State.before.plugin.exists) {
        if ([bool]$originalPlugin.exists) {
            if ([bool]$targetPlugin.exists -and -not $targetPluginIsPayload) {
                throw 'Deploy recovery found an inactive original plugin plus a target that is not the smoke payload.'
            }
            $originalPluginMoved = $true
            $pluginPayloadDeployed = [bool]$targetPlugin.exists
        } elseif ([bool]$targetPlugin.exists -and $targetPluginIsBefore) {
            $originalPluginMoved = $false
            $pluginPayloadDeployed = $false
        } else {
            $originalPluginMoved = $true
            $pluginPayloadDeployed = [bool]$targetPlugin.exists -and $targetPluginIsPayload
        }
    } else {
        $originalPluginMoved = $false
        $pluginPayloadDeployed = [bool]$targetPlugin.exists -and $targetPluginIsPayload
    }
    if ($pluginPayloadDeployed -and [bool]$stagePlugin.exists) {
        throw 'Deploy recovery found duplicate smoke plugin payloads in target and staging paths.'
    }
    $needsPluginBackup = $originalPluginMoved -and -not $originalPluginIsBefore

    $targetManifestIsBefore = Test-FileSnapshotEquivalent $State.before.manifest $targetManifest
    $targetManifestIsPayload = Test-FileSnapshotEquivalent $State.source.manifest $targetManifest
    $originalManifestIsBefore = Test-FileSnapshotEquivalent $State.before.manifest $originalManifest
    $stageManifestIsPayload = Test-FileSnapshotEquivalent $State.source.manifest $stageManifest
    if ([bool]$targetManifest.exists -and -not $targetManifestIsBefore -and -not $targetManifestIsPayload) {
        throw 'Deploy recovery found an unrecognized manifest target hash; refusing to move it.'
    }
    if ([bool]$originalManifest.exists -and -not $originalManifestIsBefore) {
        throw 'Deploy recovery found an unrecognized inactive original manifest hash.'
    }
    if ([bool]$stageManifest.exists -and -not $stageManifestIsPayload) {
        throw 'Deploy recovery found an unrecognized staged manifest hash.'
    }
    if (-not [bool]$State.before.manifest.exists -and [bool]$originalManifest.exists) {
        throw 'Deploy recovery found an inactive original manifest although no manifest existed before deployment.'
    }
    if ([bool]$State.before.manifest.exists) {
        if ([bool]$originalManifest.exists) {
            if ([bool]$targetManifest.exists -and -not $targetManifestIsPayload) {
                throw 'Deploy recovery found an inactive original manifest plus a target that is not the smoke payload.'
            }
            $originalManifestMoved = $true
            $manifestPayloadDeployed = [bool]$targetManifest.exists
        } elseif ([bool]$targetManifest.exists -and $targetManifestIsBefore) {
            $originalManifestMoved = $false
            $manifestPayloadDeployed = $false
        } else {
            $originalManifestMoved = $true
            $manifestPayloadDeployed = [bool]$targetManifest.exists -and $targetManifestIsPayload
        }
    } else {
        $originalManifestMoved = $false
        $manifestPayloadDeployed = [bool]$targetManifest.exists -and $targetManifestIsPayload
    }
    if ($manifestPayloadDeployed -and [bool]$stageManifest.exists) {
        throw 'Deploy recovery found duplicate smoke manifests in target and staging paths.'
    }
    $needsManifestBackup = $originalManifestMoved -and -not $originalManifestIsBefore

    return [pscustomobject]@{
        originalPluginMoved = $originalPluginMoved
        pluginPayloadDeployed = $pluginPayloadDeployed
        originalManifestMoved = $originalManifestMoved
        manifestPayloadDeployed = $manifestPayloadDeployed
        needsPluginBackup = $needsPluginBackup
        needsManifestBackup = $needsManifestBackup
        targetPlugin = $targetPlugin
        originalPlugin = $originalPlugin
        stagePlugin = $stagePlugin
        targetManifest = $targetManifest
        originalManifest = $originalManifest
        stageManifest = $stageManifest
    }
}

function Invoke-InterruptedDeployRecovery {
    param([Parameter(Mandatory = $true)]$State)
    $plan = Get-DeployRecoveryPlan $State
    Write-Host 'Interrupted deploy recovery preview:'
    Write-Host "  Plugin: original moved=$($plan.originalPluginMoved), smoke deployed=$($plan.pluginPayloadDeployed), backup fallback=$($plan.needsPluginBackup)"
    Write-Host "  Manifest: original moved=$($plan.originalManifestMoved), smoke deployed=$($plan.manifestPayloadDeployed), backup fallback=$($plan.needsManifestBackup)"
    if (-not $PSCmdlet.ShouldProcess([string]$State.paths.addinsRoot, "Recover interrupted Cria deploy $($State.runId) to exact pre-deploy state")) { return $false }

    if ($plan.needsPluginBackup) {
        $backupPlugin = Join-Path ([string]$State.runDirectory) 'backup\RvtMcp'
        Assert-InventoryMatches -Expected $State.before.plugin -Actual (Get-TreeInventory $backupPlugin) -Label 'deploy recovery plugin backup'
        Copy-DirectoryContents -Source $backupPlugin -Destination ([string]$State.paths.originalPluginSibling)
    }
    if ($plan.needsManifestBackup) {
        $backupManifest = Join-Path ([string]$State.runDirectory) 'backup\RvtMcp.R26.addin'
        $snapshot = Get-FileSnapshot $backupManifest
        if (-not (Test-FileSnapshotEquivalent $State.before.manifest $snapshot)) {
            throw 'Deploy recovery manifest backup does not match the pre-deploy hash.'
        }
        Copy-Item -LiteralPath $backupManifest -Destination ([string]$State.paths.originalManifestSibling)
    }

    $recoveryDirectory = Join-Path ([string]$State.runDirectory) ('interrupted-deploy-recovery-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $recoveryDirectory) { throw "Recovery evidence path already exists: '$recoveryDirectory'." }
    New-Item -ItemType Directory -Path $recoveryDirectory | Out-Null
    Invoke-DeployTargetRollback -Paths $State.paths -BeforePlugin $State.before.plugin -BeforeManifest $State.before.manifest `
        -PayloadPlugin $State.source.plugin -PayloadManifest $State.source.manifest `
        -OriginalPluginSibling ([string]$State.paths.originalPluginSibling) -OriginalManifestSibling ([string]$State.paths.originalManifestSibling) `
        -StagePluginSibling ([string]$State.paths.stagePluginSibling) -StageManifestSibling ([string]$State.paths.stageManifestSibling) `
        -FailureDirectory $recoveryDirectory -OriginalPluginMoved $plan.originalPluginMoved `
        -PluginPayloadDeployed $plan.pluginPayloadDeployed -OriginalManifestMoved $plan.originalManifestMoved `
        -ManifestPayloadDeployed $plan.manifestPayloadDeployed
    $State.status = 'Restored'
    Set-ObjectProperty -Object $State -Name 'interruptedDeployRecoveredUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
    Save-ActiveState $State
    Write-Host 'Interrupted deploy was reconciled by exact hashes and restored to the pre-deploy state.'
    return $true
}

function Save-ActiveState {
    param([Parameter(Mandatory = $true)]$State)
    Write-JsonAtomic -Path ([string]$State.statePath) -Value $State
    Write-JsonAtomic -Path $ActiveStatePath -Value ([ordered]@{
        schemaVersion = 1
        statePath = [string]$State.statePath
        runId = [string]$State.runId
        status = [string]$State.status
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    })
}

function Get-ActiveState {
    $pointer = Read-JsonFile $ActiveStatePath
    Assert-PathUnder -Path ([string]$pointer.statePath) -Parent $ArtifactRoot -Label 'active state path'
    $state = Read-JsonFile ([string]$pointer.statePath)
    Assert-ExactPath -Actual ([string]$state.repoRoot) -Expected $RepoRoot -Label 'state repository root'
    return $state
}

function Test-PortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        try { $listener.Stop() } catch { }
    }
}

function Test-ProcessAlive {
    param([int]$Id)
    if ($Id -le 0) { return $false }
    try {
        $process = Get-Process -Id $Id -ErrorAction Stop
        return -not $process.HasExited
    } catch {
        return $false
    }
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory = $true)]$Value, [string]$Label = 'timestamp')
    if ($Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).UtcDateTime
    }
    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime()
    }
    try {
        $parsed = [datetime]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $parsed.ToUniversalTime()
    } catch {
        throw "$Label is not a round-trip ISO timestamp: '$Value'."
    }
}

function Assert-OwnedServerProcess {
    param([Parameter(Mandatory = $true)]$ServerRecord)
    $pidValue = [int]$ServerRecord.pid
    if (-not (Test-ProcessAlive $pidValue)) { return $null }
    $process = Get-Process -Id $pidValue -ErrorAction Stop
    $actualPath = $process.Path
    Assert-ExactPath -Actual $actualPath -Expected ([string]$ServerRecord.exe) -Label 'owned server executable'
    $actualStart = $process.StartTime.ToUniversalTime()
    $expectedStart = ConvertTo-UtcDateTime -Value $ServerRecord.startTimeUtc -Label 'recorded server start time'
    if ([math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
        throw "PID $pidValue was reused; start time no longer matches the harness-owned server. Refusing to stop it."
    }
    $actualHash = Get-Sha256 $actualPath
    if (-not $actualHash.Equals([string]$ServerRecord.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PID $pidValue executable hash changed. Refusing to stop it."
    }
    if ($null -eq $ServerRecord.runtime) {
        throw "PID $pidValue has no recorded server runtime inventory. Refusing to treat it as harness-owned."
    }
    Assert-InventoryMatches -Expected $ServerRecord.runtime -Actual (Get-TreeInventory (Split-Path -Parent $actualPath)) -Label 'owned server runtime payload'
    return $process
}

function Assert-RevitSessionIdentity {
    param([Parameter(Mandatory = $true)]$State)
    if ($null -eq $State.revit -or $null -eq $State.revit.pid -or [string]::IsNullOrWhiteSpace([string]$State.revit.startTimeUtc)) {
        throw 'The smoke state has no complete Revit PID/start-time identity.'
    }
    $pidValue = [int]$State.revit.pid
    if (-not (Test-ProcessAlive $pidValue)) { throw "Recorded Revit PID $pidValue is no longer running." }
    $process = Get-Process -Id $pidValue -ErrorAction Stop
    Assert-ExactPath -Actual $process.Path -Expected ([string]$State.revit.exe) -Label 'recorded Revit executable'
    $actualStart = $process.StartTime.ToUniversalTime()
    $expectedStart = ConvertTo-UtcDateTime -Value $State.revit.startTimeUtc -Label 'recorded Revit start time'
    if ([math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
        throw "Revit PID $pidValue was reused; start time no longer matches the recorded smoke session."
    }
    $discovery = Get-SanitizedDiscovery ([string]$State.paths.discoveryFile)
    if ([int]$discovery.pid -ne $pidValue -or [string]$discovery.revit_year -ne '2026' -or [string]$discovery.transport -ne 'pipe') {
        throw "Current Revit discovery does not match recorded PID $pidValue / Revit 2026 / named pipe."
    }
    return $process
}

function Assert-CompleteModelStatistics {
    param([Parameter(Mandatory = $true)]$Statistics, [string]$Label = 'model statistics')
    $properties = @($Statistics.PSObject.Properties.Name)
    foreach ($required in @('projectName', 'documentPath', 'elementsCounted', 'truncated', 'cap')) {
        if ($properties -notcontains $required) { throw "$Label omitted required field '$required'." }
    }
    $count = [long]$Statistics.elementsCounted
    $cap = [long]$Statistics.cap
    if ([bool]$Statistics.truncated -or $cap -le 0 -or $count -ge $cap) {
        throw "$Label is truncated or at its cap ($count / $cap); element-count rollback or undo proof would be ambiguous."
    }
}

function Assert-RunningSessionForResume {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$SelectedProfile
    )
    if ([string]$State.status -ne 'Running') {
        throw "Run resume requires Running state; got '$($State.status)'."
    }
    if ($null -eq $State.server -or $null -eq $State.server.runtime) {
        throw 'Running state has no complete server identity/runtime record.'
    }
    if ([int]$State.server.port -ne $Port) {
        throw "Run resume must use recorded HTTP port $($State.server.port), not $Port."
    }
    if ([string]$State.server.profile -ne $SelectedProfile) {
        throw "Run resume must use recorded profile '$($State.server.profile)', not '$SelectedProfile'."
    }
    Assert-ExactPath -Actual ([string]$State.paths.serverOutput) -Expected ([string]$Paths.serverOutput) -Label 'resume server output'
    Assert-ExactPath -Actual ([string]$State.server.exe) -Expected ([string]$Paths.serverExe) -Label 'resume server executable'
    Assert-InventoryMatches -Expected $State.source.server -Actual $State.server.runtime -Label 'recorded resume server runtime'
    $server = Assert-OwnedServerProcess $State.server
    if ($null -eq $server) { throw 'The recorded harness-owned MCP server is no longer running.' }
    Assert-RevitSessionIdentity $State | Out-Null

    if ($null -eq $State.revit -or -not [bool]$State.revit.launchedByHarness -or
        [string]::IsNullOrWhiteSpace([string]$State.revit.copiedModel)) {
        throw 'Run resume requires the recorded harness-launched copied model.'
    }
    Assert-PathUnder -Path ([string]$State.revit.copiedModel) -Parent ([string]$State.runDirectory) -Label 'resume copied model'
    if (-not (Test-Path -LiteralPath ([string]$State.revit.copiedModel) -PathType Leaf)) {
        throw "Recorded copied model is missing: '$($State.revit.copiedModel)'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$State.revit.sourceModel)) {
            throw 'Run resume received -ModelPath, but the recorded session has no source-model path.'
        }
        Assert-ExactPath -Actual $ModelPath -Expected ([string]$State.revit.sourceModel) -Label 'resume source model'
    }
}

function Assert-RunResumeHasNoAmbiguousAuthoring {
    param([Parameter(Mandatory = $true)]$State)
    $smokeProperty = $State.PSObject.Properties['smoke']
    if ($null -ne $smokeProperty -and $null -ne $smokeProperty.Value) {
        $authoringProperty = $smokeProperty.Value.PSObject.Properties['authoring']
        if ($null -ne $authoringProperty -and $null -ne $authoringProperty.Value) {
            throw 'This Running state already records authoring work. Use VerifyUndo, Collect, or Restore; Run will not overwrite its element IDs.'
        }
    }

    $authoringEvidence = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath ([string]$State.runDirectory) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'http' -or $_.Name -like 'http-attempt-*' })) {
        $authoringEvidence += @(Get-ChildItem -LiteralPath $directory.FullName -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(10|11|12|13|14|15)-' })
    }
    if ($authoringEvidence.Count -gt 0) {
        $paths = ($authoringEvidence | Select-Object -ExpandProperty FullName) -join "'; '"
        throw "Run resume found authoring-step evidence but no recorded authoring state. Refusing an ambiguous retry; inspect '$paths', then Collect or Restore."
    }
}

function Stop-OwnedServerProcess {
    param([Parameter(Mandatory = $true)]$State)
    if ($null -eq $State.server -or $null -eq $State.server.pid) { return }
    $process = Assert-OwnedServerProcess $State.server
    if ($null -eq $process) { return }
    Stop-Process -Id $process.Id
    $process.WaitForExit(10000)
    if (-not $process.HasExited) {
        throw "Harness-owned server PID $($process.Id) did not exit. No other process was touched."
    }
    Write-Host "Stopped harness-owned MCP server PID $($process.Id)."
}

function Invoke-DotNetStep {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    Write-Host ($Executable + ' ' + ($Arguments -join ' '))
    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath $LogPath -Encoding UTF8
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) {
        throw "dotnet exited with code $exitCode. See '$LogPath'."
    }
}

function ConvertFrom-McpHttpBody {
    param([Parameter(Mandatory = $true)][string]$Body)
    $trimmed = $Body.Trim()
    if ($trimmed.StartsWith('{')) {
        return $trimmed | ConvertFrom-Json
    }
    $match = [regex]::Match($Body, '(?m)^data:\s*(?<json>\{.*\})\s*$')
    if (-not $match.Success) {
        throw 'MCP response was neither JSON nor a parseable SSE data event.'
    }
    return $match.Groups['json'].Value | ConvertFrom-Json
}

function Assert-McpJsonRpcSuccess {
    param(
        [Parameter(Mandatory = $true)]$Parsed,
        [Parameter(Mandatory = $true)][string]$Method
    )
    $errorProperty = $Parsed.PSObject.Properties['error']
    if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
        throw "$Method returned JSON-RPC error: $($errorProperty.Value | ConvertTo-Json -Compress -Depth 10)"
    }
}

function Invoke-McpHttp {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)]$Parameters,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$EvidenceName
    )
    $Script:McpRequestId++
    $meta = [ordered]@{
        'io.modelcontextprotocol/protocolVersion' = $ProtocolVersion
        'io.modelcontextprotocol/clientInfo' = [ordered]@{ name = 'cria-live-smoke'; version = '1.0.0' }
        'io.modelcontextprotocol/clientCapabilities' = [ordered]@{}
    }
    $paramsMap = [ordered]@{}
    if ($null -ne $Parameters) {
        if ($Parameters -is [System.Collections.IDictionary]) {
            foreach ($key in $Parameters.Keys) { $paramsMap[[string]$key] = $Parameters[$key] }
        } else {
            foreach ($property in $Parameters.PSObject.Properties) {
                $paramsMap[$property.Name] = $property.Value
            }
        }
    }
    $paramsMap['_meta'] = $meta
    $request = [ordered]@{
        jsonrpc = '2.0'
        id = $Script:McpRequestId
        method = $Method
        params = $paramsMap
    }
    $requestJson = $request | ConvertTo-Json -Depth 30 -Compress
    $safeName = $EvidenceName -replace '[^A-Za-z0-9._-]', '_'
    $requestJson | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$safeName.request.json") -Encoding UTF8

    $headers = @{
        'MCP-Protocol-Version' = $ProtocolVersion
        'Mcp-Method' = $Method
        'Accept' = 'application/json, text/event-stream'
    }
    if ($Method -eq 'tools/call') {
        $mcpName = [string]$paramsMap['name']
        if ([string]::IsNullOrWhiteSpace($mcpName)) { throw 'tools/call requires a tool name for the Mcp-Name header.' }
        $headers['Mcp-Name'] = $mcpName
    }
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -Method Post -Body $requestJson -ContentType 'application/json' -Headers $headers -TimeoutSec 75

    [string]$response.Content | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$safeName.response.txt") -Encoding UTF8
    if ($null -ne $response.Headers['Mcp-Session-Id']) {
        throw "$Method unexpectedly returned Mcp-Session-Id; HTTP is not stateless."
    }
    $parsed = ConvertFrom-McpHttpBody ([string]$response.Content)
    $parsed | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$safeName.response.json") -Encoding UTF8
    Assert-McpJsonRpcSuccess -Parsed $parsed -Method $Method
    return $parsed
}

function Invoke-McpTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Arguments,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [Parameter(Mandatory = $true)][string]$EvidenceName
    )
    $result = Invoke-McpHttp -Method 'tools/call' -Parameters ([ordered]@{ name = $Name; arguments = $Arguments }) -Port $Port -EvidenceDirectory $EvidenceDirectory -EvidenceName $EvidenceName
    if (($result.result.PSObject.Properties.Name -contains 'isError') -and $result.result.isError -eq $true) {
        throw "$Name returned isError=true."
    }
    if (-not ($result.result.PSObject.Properties.Name -contains 'content') -or @($result.result.content).Count -eq 0) {
        throw "$Name returned no MCP content blocks."
    }
    $text = [string](@($result.result.content)[0].text)
    if ($text.StartsWith('Error:', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name returned: $text"
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        return $text
    }
}

function Wait-HttpReady {
    param([int]$Port, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $task = $client.ConnectAsync('127.0.0.1', $Port)
                if ($task.Wait(500) -and $client.Connected) { return }
            } finally {
                $client.Dispose()
            }
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    throw "MCP HTTP server did not listen on 127.0.0.1:$Port within $TimeoutSeconds seconds."
}

function Get-SanitizedDiscovery {
    param([Parameter(Mandatory = $true)][string]$Path)
    $raw = Read-JsonFile $Path
    return [ordered]@{
        schema_version = $raw.schema_version
        revit_year = $raw.revit_year
        transport = $raw.transport
        port = $raw.port
        pipe_name = $raw.pipe_name
        pid = $raw.pid
    }
}

function Wait-RevitDiscovery {
    param([Parameter(Mandatory = $true)]$Paths, [int]$TimeoutSeconds)
    if ([string]::IsNullOrWhiteSpace([string]$Paths.discoveryFile)) {
        throw 'LOCALAPPDATA is unavailable; Revit discovery cannot be verified.'
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Paths.discoveryFile -PathType Leaf) {
            try {
                $discovery = Get-SanitizedDiscovery $Paths.discoveryFile
                if ([string]$discovery.revit_year -eq '2026' -and
                    [string]$discovery.transport -eq 'pipe' -and
                    (Test-ProcessAlive ([int]$discovery.pid))) {
                    return $discovery
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "No live Revit 2026 named-pipe discovery appeared at '$($Paths.discoveryFile)' within $TimeoutSeconds seconds."
}

function Get-LogOffsets {
    param([Parameter(Mandatory = $true)]$Paths)
    $offsets = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace([string]$Paths.localDataRoot)) { return $offsets }
    foreach ($name in @('debug.log', 'revit-mcp.log', 'mcp-calls.jsonl')) {
        $path = Join-Path $Paths.localDataRoot $name
        $offsets[$name] = if (Test-Path -LiteralPath $path -PathType Leaf) { [long](Get-Item -LiteralPath $path).Length } else { 0 }
    }
    return $offsets
}

function Copy-AppendedLogBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $stream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($Offset -lt 0 -or $Offset -gt $stream.Length) { $Offset = 0 }
        $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $output = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.CopyTo($output) } finally { $output.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Assert-DeployedPayloadUnchanged {
    param([Parameter(Mandatory = $true)]$State)
    $manifest = Get-FileSnapshot ([string]$State.paths.manifestTarget)
    $plugin = Get-TreeInventory ([string]$State.paths.pluginTarget)
    if (-not [bool]$manifest.exists -or
        -not ([string]$manifest.sha256).Equals([string]$State.deployed.manifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The active add-in manifest no longer matches the deployed smoke payload. Refusing to overwrite it.'
    }
    Assert-InventoryMatches -Expected $State.deployed.plugin -Actual $plugin -Label 'active deployed plugin'
}

function Get-DotNetInfo {
    $repoLocal = Join-Path $RepoRoot '.dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $repoLocal -PathType Leaf) {
        $executable = Get-NormalizedPath $repoLocal
    } else {
        $command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            throw "No .NET SDK host was found. Expected '$repoLocal' or dotnet on PATH."
        }
        $executable = Get-NormalizedPath $command.Source
    }
    Assert-LocalFilesystemPath -Path $executable -Label '.NET executable'
    $versionOutput = @(& $executable --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1) {
        throw ".NET SDK version check failed for '$executable': $($versionOutput -join ' ')"
    }
    return [pscustomobject]@{
        path = $executable
        version = [string]$versionOutput[0]
        sha256 = Get-Sha256 $executable
        repoLocal = $executable.Equals((Get-NormalizedPath $repoLocal), [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Invoke-Preflight {
    $paths = Get-Paths
    Write-Host 'Cria Revit 2026 live smoke preflight (read-only)'
    Write-Host "Repository : $RepoRoot"
    Write-Host "Artifacts  : $ArtifactRoot (gitignored)"
    Write-Host "Revit      : $($paths.revitExe)"
    Write-Host "Add-ins    : $($paths.addinsRoot)"
    Write-Host "Manifest   : $($paths.manifestTarget)"
    Write-Host "Plugin     : $($paths.pluginTarget)"
    Write-Host ''

    try {
        $dotnet = Get-DotNetInfo
        Write-Host "[OK] .NET SDK: $($dotnet.version) at $($dotnet.path) (repo-local: $($dotnet.repoLocal))"
    } catch {
        Write-Warning "[MISSING] .NET SDK: $($_.Exception.Message)"
    }

    foreach ($entry in @(
        @{ Label = 'Revit executable'; Path = $paths.revitExe },
        @{ Label = 'Server output'; Path = $paths.serverExe },
        @{ Label = 'Plugin output'; Path = $paths.pluginDll },
        @{ Label = 'Source manifest'; Path = $paths.manifestSource }
    )) {
        if (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $entry.Path
            Write-Host ('[OK] {0}: {1} bytes, SHA256 {2}' -f $entry.Label, $item.Length, (Get-Sha256 $entry.Path))
        } else {
            Write-Warning "[MISSING] $($entry.Label): $($entry.Path)"
        }
    }

    $installedManifest = Get-FileSnapshot $paths.manifestTarget
    $installedPlugin = Get-TreeInventory $paths.pluginTarget
    Write-Host ('Installed manifest: {0}' -f $(if ($installedManifest.exists) { $installedManifest.sha256 } else { 'absent' }))
    Write-Host ('Installed plugin  : {0}' -f $(if ($installedPlugin.exists) { "$($installedPlugin.fileCount) files / $($installedPlugin.digest)" } else { 'absent' }))

    $revit = Get-RevitProcesses
    if ($revit.Count -eq 0) {
        Write-Host '[OK] Revit is closed; Deploy/Restore can proceed.'
    } else {
        Write-Warning ('Revit is running (PID {0}). Deploy/Restore will refuse to proceed.' -f (($revit.Id) -join ', '))
    }

    if (Test-Path -LiteralPath $ActiveStatePath -PathType Leaf) {
        try {
            $active = Get-ActiveState
            Write-Host "Active harness state: $($active.runId) / $($active.status) / $($active.statePath)"
        } catch {
            Write-Warning "Active state could not be validated: $($_.Exception.Message)"
        }
    } else {
        Write-Host 'Active harness state: none'
    }

    Write-Host ''
    Write-Host 'Next safe commands:'
    Write-Host '  pwsh scripts/revit-2026-smoke.ps1 -Phase Build'
    Write-Host '  pwsh scripts/revit-2026-smoke.ps1 -Phase Deploy -WhatIf'
    Write-Host '  pwsh scripts/revit-2026-smoke.ps1 -Phase Deploy -ApproveAddinChange'
}

function Invoke-Build {
    $paths = Get-Paths
    $dotnet = Get-DotNetInfo
    $buildId = if ($RunId) { $RunId } else { New-SmokeRunId }
    $buildDir = Join-Path $ArtifactRoot "builds\$buildId"
    Assert-PathUnder -Path $buildDir -Parent $ArtifactRoot -Label 'build evidence directory'
    if ($PSCmdlet.ShouldProcess($buildDir, 'Run tests and skip-deploy builds')) {
        if (Test-Path -LiteralPath $buildDir) { throw "Build evidence directory already exists: '$buildDir'." }
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
        Invoke-DotNetStep -Executable $dotnet.path -Arguments @('test', $paths.testsProject, '-c', 'Release') -LogPath (Join-Path $buildDir 'dotnet-test.log')
        Invoke-DotNetStep -Executable $dotnet.path -Arguments @('build', $paths.serverProject, '-c', 'Release') -LogPath (Join-Path $buildDir 'server-build.log')
        Invoke-DotNetStep -Executable $dotnet.path -Arguments @('build', $paths.pluginProject, '-c', 'Release', '-p:RvtMcpSkipDeploy=true') -LogPath (Join-Path $buildDir 'plugin-r26-build.log')
        $record = [ordered]@{
            schemaVersion = 1
            buildId = $buildId
            createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            server = Get-ServerRuntimeInventory $paths
            plugin = Get-FileSnapshot $paths.pluginDll
            manifest = Get-FileSnapshot $paths.manifestSource
            dotnet = $dotnet
            skipDeploy = $true
        }
        Write-JsonAtomic -Path (Join-Path $buildDir 'build-record.json') -Value $record
        Write-Host "Build and tests passed. Evidence: $buildDir"
    }
}

function Invoke-Deploy {
    $paths = Get-Paths
    Assert-RevitClosed
    if (-not $WhatIfPreference -and -not $ApproveAddinChange) {
        throw 'Deploy modifies %APPDATA%\Autodesk\Revit\Addins\2026. Preview with -WhatIf, then rerun with -ApproveAddinChange.'
    }
    if (Test-Path -LiteralPath $ActiveStatePath -PathType Leaf) {
        $existing = Get-ActiveState
        if ([string]$existing.status -ne 'Restored') {
            throw "A smoke deployment is already active: $($existing.runId) / $($existing.status). Restore it before deploying another build."
        }
    }

    foreach ($required in @($paths.pluginDll, $paths.manifestSource, $paths.serverExe, $paths.revitExe)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required file is missing: '$required'. Run -Phase Build or fix the path."
        }
    }
    $serverRuntime = Get-ServerRuntimeInventory $paths
    Assert-NoReparsePoint -Path $paths.pluginOutput -Label 'plugin build output'
    Assert-NoReparsePoint -Path $paths.pluginTarget -Label 'installed plugin'

    $id = if ($RunId) { $RunId } else { New-SmokeRunId }
    $runDirectory = Join-Path $ArtifactRoot $id
    Assert-PathUnder -Path $runDirectory -Parent $ArtifactRoot -Label 'run directory'
    $statePath = Join-Path $runDirectory 'state.json'
    $backupDirectory = Join-Path $runDirectory 'backup'
    $originalPluginSibling = Join-Path $paths.addinsRoot ".cria-$id-original-RvtMcp"
    $originalManifestSibling = Join-Path $paths.addinsRoot ".cria-$id-original-RvtMcp.R26.addin.disabled"
    $stagePluginSibling = Join-Path $paths.addinsRoot ".cria-$id-staging-RvtMcp"
    $stageManifestSibling = Join-Path $paths.addinsRoot ".cria-$id-staging-RvtMcp.R26.addin.tmp"

    Write-Host 'Deploy preview:'
    Write-Host "  Source plugin : $($paths.pluginOutput)"
    Write-Host "  Source manifest: $($paths.manifestSource)"
    Write-Host "  Target plugin : $($paths.pluginTarget)"
    Write-Host "  Target manifest: $($paths.manifestTarget)"
    Write-Host "  Backup/evidence: $runDirectory"

    if (-not $PSCmdlet.ShouldProcess($paths.addinsRoot, "Back up and deploy the exact Cria R26 payload for run $id")) { return }
    foreach ($collision in @($runDirectory, $originalPluginSibling, $originalManifestSibling, $stagePluginSibling, $stageManifestSibling)) {
        if (Test-Path -LiteralPath $collision) { throw "Refusing to overwrite existing deployment path: '$collision'." }
    }

    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $payload = Stage-PluginPayload -Paths $paths -RunDirectory $runDirectory
    $beforePlugin = Get-TreeInventory $paths.pluginTarget
    $beforeManifest = Get-FileSnapshot $paths.manifestTarget

    if ($beforePlugin.exists) {
        $backupPlugin = Join-Path $backupDirectory 'RvtMcp'
        Copy-DirectoryContents -Source $paths.pluginTarget -Destination $backupPlugin
        Assert-InventoryMatches -Expected $beforePlugin -Actual (Get-TreeInventory $backupPlugin) -Label 'plugin backup'
    }
    if ($beforeManifest.exists) {
        $backupManifest = Join-Path $backupDirectory 'RvtMcp.R26.addin'
        Copy-Item -LiteralPath $paths.manifestTarget -Destination $backupManifest
        if ((Get-Sha256 $backupManifest) -ne [string]$beforeManifest.sha256) { throw 'Manifest backup hash mismatch.' }
    }

    if (-not (Test-Path -LiteralPath $paths.addinsRoot)) {
        New-Item -ItemType Directory -Path $paths.addinsRoot -Force | Out-Null
    }
    Copy-DirectoryContents -Source $payload.pluginRoot -Destination $stagePluginSibling
    Copy-Item -LiteralPath $payload.manifest -Destination $stageManifestSibling
    Assert-InventoryMatches -Expected $payload.pluginInventory -Actual (Get-TreeInventory $stagePluginSibling) -Label 'add-ins staging plugin'
    if ((Get-Sha256 $stageManifestSibling) -ne [string]$payload.manifestSnapshot.sha256) { throw 'Add-ins staging manifest hash mismatch.' }

    $state = [ordered]@{
        schemaVersion = 1
        runId = $id
        status = 'Deploying'
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        repoRoot = $RepoRoot
        statePath = $statePath
        runDirectory = $runDirectory
        paths = [ordered]@{
            revitExe = $paths.revitExe
            discoveryFile = $paths.discoveryFile
            serverOutput = $paths.serverOutput
            serverExe = $paths.serverExe
            addinsRoot = $paths.addinsRoot
            manifestTarget = $paths.manifestTarget
            pluginTarget = $paths.pluginTarget
            originalPluginSibling = $originalPluginSibling
            originalManifestSibling = $originalManifestSibling
            stagePluginSibling = $stagePluginSibling
            stageManifestSibling = $stageManifestSibling
        }
        source = [ordered]@{
            server = $serverRuntime
            plugin = $payload.pluginInventory
            manifest = $payload.manifestSnapshot
        }
        before = [ordered]@{
            plugin = $beforePlugin
            manifest = $beforeManifest
        }
        deployed = $null
        deployTransitions = [ordered]@{
            originalPluginMoved = $false
            pluginPayloadDeployed = $false
            originalManifestMoved = $false
            manifestPayloadDeployed = $false
            updatedUtc = $null
        }
        server = $null
        revit = $null
        logOffsets = Get-LogOffsets $paths
        smoke = $null
    }
    Save-ActiveState $state

    $originalPluginMoved = $false
    $pluginPayloadDeployed = $false
    $originalManifestMoved = $false
    $manifestPayloadDeployed = $false
    try {
        if ($beforePlugin.exists) {
            Move-Item -LiteralPath $paths.pluginTarget -Destination $originalPluginSibling
            $originalPluginMoved = $true
            $state.deployTransitions.originalPluginMoved = $true
            $state.deployTransitions.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-ActiveState $state
        }
        Move-Item -LiteralPath $stagePluginSibling -Destination $paths.pluginTarget
        $pluginPayloadDeployed = $true
        $state.deployTransitions.pluginPayloadDeployed = $true
        $state.deployTransitions.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-ActiveState $state

        if ($beforeManifest.exists) {
            Move-Item -LiteralPath $paths.manifestTarget -Destination $originalManifestSibling
            $originalManifestMoved = $true
            $state.deployTransitions.originalManifestMoved = $true
            $state.deployTransitions.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-ActiveState $state
        }
        Move-Item -LiteralPath $stageManifestSibling -Destination $paths.manifestTarget
        $manifestPayloadDeployed = $true
        $state.deployTransitions.manifestPayloadDeployed = $true
        $state.deployTransitions.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-ActiveState $state

        $deployedPlugin = Get-TreeInventory $paths.pluginTarget
        $deployedManifest = Get-FileSnapshot $paths.manifestTarget
        Assert-InventoryMatches -Expected $payload.pluginInventory -Actual $deployedPlugin -Label 'deployed plugin'
        if (-not ([string]$deployedManifest.sha256).Equals([string]$payload.manifestSnapshot.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Deployed manifest hash mismatch.'
        }
        $state.deployed = [ordered]@{ plugin = $deployedPlugin; manifest = $deployedManifest }
        $state.status = 'Deployed'
        Set-ObjectProperty -Object $state -Name 'deployedUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
        Save-ActiveState $state
        Write-Host "Cria R26 smoke payload deployed and verified. Run ID: $id"
        Write-Host 'The original add-in remains both in the local run backup and in inactive sibling paths until Restore.'
    } catch {
        $deployError = $_
        Write-Warning "Deploy failed; attempting exact rollback: $($deployError.Exception.Message)"
        try {
            Invoke-DeployTargetRollback -Paths $paths -BeforePlugin $beforePlugin -BeforeManifest $beforeManifest `
                -PayloadPlugin $payload.pluginInventory -PayloadManifest $payload.manifestSnapshot `
                -OriginalPluginSibling $originalPluginSibling -OriginalManifestSibling $originalManifestSibling `
                -StagePluginSibling $stagePluginSibling -StageManifestSibling $stageManifestSibling `
                -FailureDirectory $runDirectory -OriginalPluginMoved $originalPluginMoved `
                -PluginPayloadDeployed $pluginPayloadDeployed -OriginalManifestMoved $originalManifestMoved `
                -ManifestPayloadDeployed $manifestPayloadDeployed
        } catch {
            $rollbackError = $_
            $state.status = 'DeployRollbackFailed'
            Set-ObjectProperty -Object $state -Name 'deployFailure' -Value $deployError.Exception.Message
            Set-ObjectProperty -Object $state -Name 'rollbackFailure' -Value $rollbackError.Exception.Message
            Save-ActiveState $state
            throw "Deployment failed ('$($deployError.Exception.Message)') and exact rollback also failed ('$($rollbackError.Exception.Message)'). Inspect state and hashes; do not move add-in files blindly."
        }
        $state.status = 'Restored'
        Set-ObjectProperty -Object $state -Name 'deployFailure' -Value $deployError.Exception.Message
        Set-ObjectProperty -Object $state -Name 'restoredUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
        Save-ActiveState $state
        throw $deployError
    }
}

function Start-OwnedHttpServer {
    param([Parameter(Mandatory = $true)]$State, [int]$Port, [string]$SelectedProfile)
    if ($null -ne $State.server -and $null -ne $State.server.pid) {
        $existing = Assert-OwnedServerProcess $State.server
        if ($null -ne $existing) {
            if ([int]$State.server.port -ne $Port) { throw "The harness-owned server already runs on port $($State.server.port), not $Port." }
            if ([string]$State.server.profile -ne $SelectedProfile) { throw "The harness-owned server already runs with profile '$($State.server.profile)', not '$SelectedProfile'." }
            return $State.server
        }
    }
    if (-not (Test-PortAvailable $Port)) {
        throw "Port $Port is already in use. The harness will not stop or replace the owning process. Choose -HttpPort with a free loopback port."
    }

    $serverExe = [string]$State.paths.serverExe
    $currentRuntime = Get-ServerRuntimeInventory $State.paths
    Assert-InventoryMatches -Expected $State.source.server -Actual $currentRuntime -Label 'server runtime before launch'
    $sourceHash = Get-Sha256 $serverExe
    $stdout = Join-Path ([string]$State.runDirectory) 'server.stdout.log'
    $stderr = Join-Path ([string]$State.runDirectory) 'server.stderr.log'
    if (Test-Path -LiteralPath $stdout) { throw "Server stdout evidence already exists: '$stdout'." }
    if (Test-Path -LiteralPath $stderr) { throw "Server stderr evidence already exists: '$stderr'." }

    $process = Start-Process -FilePath $serverExe -ArgumentList @(
        '--target', '2026',
        '--profile', $SelectedProfile,
        '--disable-toolbaker',
        '--http', [string]$Port
    ) -WorkingDirectory (Split-Path -Parent $serverExe) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $record = [ordered]@{
        pid = $process.Id
        exe = $serverExe
        sha256 = $sourceHash
        runtime = $currentRuntime
        startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
        port = $Port
        profile = $SelectedProfile
        stdout = $stdout
        stderr = $stderr
    }
    try {
        Write-JsonAtomic -Path (Join-Path ([string]$State.runDirectory) 'server-starting.json') -Value $record
        $State.server = $record
        $State.status = 'ServerStarting'
        Save-ActiveState $State
        Start-Sleep -Milliseconds 200
        if ($process.HasExited) { throw "MCP server exited during startup. See '$stderr'." }
        Wait-HttpReady -Port $Port -TimeoutSeconds ([math]::Min($WaitSeconds, 60))
    } catch {
        $startupError = $_
        try {
            $owned = Assert-OwnedServerProcess $record
            if ($null -ne $owned) {
                Stop-Process -Id $owned.Id
                $owned.WaitForExit(10000)
            }
        } catch {
            Write-Warning "Server startup failed and its process could not be safely stopped: $($_.Exception.Message)"
        }
        throw $startupError
    }
    return $record
}

function Start-OrReuseRevit {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$Paths)
    $running = Get-RevitProcesses
    $copiedModel = $null
    $launched = $null

    if ($LaunchRevit) {
        if ($running.Count -gt 0) {
            if ($RunAuthoring) {
                throw 'Authoring smoke requires the harness to launch a fresh Revit process with its copied model. Close existing Revit instances first; the harness will not close them.'
            }
            Write-Host 'Revit is already running; reusing it for read-only smoke instead of launching another instance.'
        } else {
            $arguments = @()
            if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
                $sourceModel = Get-NormalizedPath $ModelPath
                Assert-LocalFilesystemPath -Path $sourceModel -Label 'source model'
                if (-not (Test-Path -LiteralPath $sourceModel -PathType Leaf)) { throw "Model not found: '$sourceModel'." }
                if (-not [System.IO.Path]::GetExtension($sourceModel).Equals('.rvt', [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "ModelPath must be a local .rvt file: '$sourceModel'."
                }
                $modelDir = Join-Path ([string]$State.runDirectory) 'models'
                New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
                $base = [System.IO.Path]::GetFileNameWithoutExtension($sourceModel)
                $copiedModel = Join-Path $modelDir "$base.cria-smoke-$($State.runId).rvt"
                if (Test-Path -LiteralPath $copiedModel) { throw "Copied smoke model already exists: '$copiedModel'." }
                Copy-Item -LiteralPath $sourceModel -Destination $copiedModel
                if ((Get-Sha256 $sourceModel) -ne (Get-Sha256 $copiedModel)) { throw 'Copied RVT hash mismatch before launch.' }
                $arguments += ('"{0}"' -f $copiedModel)
                Write-Host "Opening local smoke copy: $copiedModel"
                Write-Host "Original remains untouched: $sourceModel"
            } elseif ($RunAuthoring) {
                throw 'Authoring smoke requires -ModelPath so the harness can copy and open a disposable RVT.'
            }
            $launched = Start-Process -FilePath $Paths.revitExe -ArgumentList $arguments -PassThru
            $running = @($launched)
        }
    } elseif ($running.Count -eq 0) {
        throw 'Revit 2026 is not running. Start it manually with a disposable model, or rerun Run with -LaunchRevit and -ModelPath.'
    } elseif ($RunAuthoring) {
        throw 'Authoring smoke refuses an already-running Revit because it cannot prove the active model is a disposable copy. Use -LaunchRevit -ModelPath after closing Revit.'
    }

    $discovery = Wait-RevitDiscovery -Paths $Paths -TimeoutSeconds $WaitSeconds
    if ($null -ne $launched -and [int]$discovery.pid -ne $launched.Id) {
        throw "Revit discovery belongs to PID $($discovery.pid), but the harness launched PID $($launched.Id). Refusing to route model changes."
    }
    $activeRevit = Get-Process -Id ([int]$discovery.pid) -ErrorAction Stop
    Assert-ExactPath -Actual $activeRevit.Path -Expected ([string]$Paths.revitExe) -Label 'discovered Revit executable'
    return [ordered]@{
        pid = [int]$discovery.pid
        exe = [string]$activeRevit.Path
        startTimeUtc = $activeRevit.StartTime.ToUniversalTime().ToString('o')
        launchedByHarness = ($null -ne $launched)
        copiedModel = $copiedModel
        sourceModel = if ([string]::IsNullOrWhiteSpace($ModelPath)) { $null } else { Get-NormalizedPath $ModelPath }
        discovery = $discovery
    }
}

function Invoke-ProtocolAndReadSmoke {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory
    )
    Assert-PathUnder -Path $EvidenceDirectory -Parent ([string]$State.runDirectory) -Label 'HTTP evidence directory'
    $httpEvidence = $EvidenceDirectory
    if (-not (Test-Path -LiteralPath $httpEvidence)) { New-Item -ItemType Directory -Path $httpEvidence -Force | Out-Null }
    $port = [int]$State.server.port

    $discover = Invoke-McpHttp -Method 'server/discover' -Parameters ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '01-discover'
    if ([string]$discover.result.resultType -ne 'complete') { throw 'server/discover did not return resultType=complete.' }
    $serverName = [string]$discover.result._meta.'io.modelcontextprotocol/serverInfo'.name
    if ($serverName -ne 'cria-revit-mcp') { throw "Unexpected server identity: '$serverName'." }
    if (@($discover.result.supportedVersions) -notcontains $ProtocolVersion) { throw "server/discover does not advertise $ProtocolVersion." }

    $tools = Invoke-McpHttp -Method 'tools/list' -Parameters ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '02-tools-list'
    $toolNames = @($tools.result.tools | ForEach-Object { [string]$_.name })
    foreach ($required in @('revit_list_available_targets', 'revit_get_current_view_info', 'revit_analyze_model_statistics', 'revit_get_model_warnings_summary')) {
        if ($toolNames -notcontains $required) { throw "Required safe smoke tool is absent: $required."
        }
    }
    $forbiddenTools = @(
        'revit_delete_element',
        'revit_unload_family',
        'revit_purge_unused',
        'revit_wipe_empty_tags',
        'revit_remove_filter_from_view',
        'revit_unload_link',
        'revit_remove_parameter_binding',
        'revit_delete_view_template',
        'revit_delete_saved_selection',
        'revit_workflow_view_cleanup',
        'revit_send_code_to_revit'
    )
    if ([string]$State.server.profile -eq 'read-only') {
        $forbiddenTools += @(
            'revit_batch_execute',
            'revit_create_view',
            'revit_place_view_on_sheet',
            'revit_set_view_crop',
            'revit_set_view_scale',
            'revit_set_project_info'
        )
    }
    foreach ($forbidden in $forbiddenTools) {
        if ($toolNames -contains $forbidden) { throw "Safety regression: $forbidden is exposed under profile $($State.server.profile)." }
    }
    $requiredAuthoringTools = @('revit_create_level', 'revit_batch_execute', 'revit_find_elements_in_volume')
    if ([string]$State.server.profile -eq 'safe-authoring') {
        $missingAuthoringTools = @($requiredAuthoringTools | Where-Object { $toolNames -notcontains $_ })
        if ($missingAuthoringTools.Count -gt 0) {
            throw "safe-authoring profile is missing authoring smoke tools: $($missingAuthoringTools -join ', ')."
        }
    }

    $legacy = Invoke-WebRequest -Uri "http://127.0.0.1:$port/sse" -Method Get -SkipHttpErrorCheck -TimeoutSec 15
    [ordered]@{ statusCode = [int]$legacy.StatusCode; content = [string]$legacy.Content } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $httpEvidence '03-legacy-sse.json') -Encoding UTF8
    if ([int]$legacy.StatusCode -ne 404) { throw "Legacy /sse returned $($legacy.StatusCode), expected 404." }

    $targets = Invoke-McpTool -Name 'revit_list_available_targets' -Arguments ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '04-list-targets'
    $matchingTargets = @($targets.targets | Where-Object { [string]$_.year -eq '2026' -and [string]$_.transport -eq 'pipe' })
    if ([int]$targets.count -lt 1 -or $matchingTargets.Count -lt 1) { throw 'No live Revit 2026 named-pipe target was reported.' }

    $target = Invoke-McpTool -Name 'revit_get_current_target' -Arguments ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '05-current-target'
    if ([string]$target.pinned_target -ne '2026') { throw "Server is not pinned to Revit 2026: $($target.pinned_target)." }

    $view = Invoke-McpTool -Name 'revit_get_current_view_info' -Arguments ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '06-current-view'
    $statistics = Invoke-McpTool -Name 'revit_analyze_model_statistics' -Arguments ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '07-model-statistics'
    if ($null -ne $State.revit -and -not [string]::IsNullOrWhiteSpace([string]$State.revit.copiedModel)) {
        Assert-CompleteModelStatistics -Statistics $statistics -Label 'live copied-model statistics'
        if ([string]::IsNullOrWhiteSpace([string]$statistics.documentPath)) {
            throw 'Active Revit document is unsaved or omitted documentPath.'
        }
        Assert-ExactPath -Actual ([string]$statistics.documentPath) -Expected ([string]$State.revit.copiedModel) -Label 'live copied-model document path'
    }
    $warnings = Invoke-McpTool -Name 'revit_get_model_warnings_summary' -Arguments ([ordered]@{ include_examples = $true; max_examples_per_type = 3 }) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '08-model-warnings'
    $audit = $null
    $auditStatus = 'skipped: workflows toolset is absent from this profile'
    if ($toolNames -contains 'revit_workflow_model_audit') {
        $audit = Invoke-McpTool -Name 'revit_workflow_model_audit' -Arguments ([ordered]@{
            include_warnings = $true
            include_families = $true
            include_views = $true
            include_schedules = $true
            include_mep = $false
            limit_per_section = 20
        }) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '09-model-audit'
        $auditStatus = 'completed'
    }

    return [ordered]@{
        protocolVersion = $ProtocolVersion
        serverName = $serverName
        toolCount = $toolNames.Count
        forbiddenToolsAbsent = $true
        targetCount = [int]$targets.count
        view = $view
        statistics = $statistics
        warnings = $warnings
        auditStatus = $auditStatus
        audit = $audit
    }
}

function Get-AuthoringPlacementCandidates {
    $candidates = [System.Collections.Generic.List[object]]::new()
    $candidates.Add([pscustomobject]@{ index = 0; offsetX = 0.0; offsetY = 0.0 })
    $index = 1
    foreach ($radius in @(50000.0, 100000.0, 200000.0, 400000.0, 800000.0, 1600000.0)) {
        foreach ($pair in @(
            @($radius, $radius),
            @(-$radius, $radius),
            @(-$radius, -$radius),
            @($radius, -$radius)
        )) {
            $candidates.Add([pscustomobject]@{
                index = $index
                offsetX = [double]$pair[0]
                offsetY = [double]$pair[1]
            })
            $index++
        }
    }
    return $candidates.ToArray()
}

function New-AuthoringProbeVolume {
    param(
        [Parameter(Mandatory = $true)][double]$OffsetX,
        [Parameter(Mandatory = $true)][double]$OffsetY
    )
    # Autodesk supports model geometry within 16 km of the internal origin. Span
    # that full Z envelope so shared/project elevation settings cannot hide an
    # overlapping wall or floor from this preflight.
    return [ordered]@{
        min = [ordered]@{ x = $OffsetX - 2000.0; y = $OffsetY - 2000.0; z = -16000000.0 }
        max = [ordered]@{ x = $OffsetX + 8000.0; y = $OffsetY + 6000.0; z = 16000000.0 }
    }
}

function Test-AuthoringProbeIsEmpty {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$ExpectedVolume
    )
    if ([string]$Response.source -ne 'axis_aligned_volume') { throw 'Placement probe returned an unexpected source.' }
    if ([string]$Response.unit -ne 'mm') { throw 'Placement probe did not return millimeter coordinates.' }
    if ([string]$Response.match -ne 'intersects') { throw 'Placement probe did not use intersects matching.' }
    if ([int]$Response.limit -ne 1) { throw 'Placement probe did not echo its limit of 1.' }
    if ([int]$Response.returned -lt 0 -or [int]$Response.returned -gt 1) { throw 'Placement probe returned an invalid result count.' }
    if ([int]$Response.scanned -lt [int]$Response.returned) { throw 'Placement probe scanned count is smaller than its returned count.' }
    if (@($Response.failed).Count -ne 0) { throw 'Placement probe reported failed element reads.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Response.error)) { throw "Placement probe reported an error: $($Response.error)" }
    if (@($Response.elements).Count -ne [int]$Response.returned) { throw 'Placement probe element count does not match returned.' }

    foreach ($bound in @('min', 'max')) {
        foreach ($axis in @('x', 'y', 'z')) {
            $actual = [double]$Response.volume.$bound.$axis
            $expected = [double]$ExpectedVolume.$bound.$axis
            if ([math]::Abs($actual - $expected) -gt 0.001) {
                throw "Placement probe echoed unexpected $bound.$axis. Expected $expected; got $actual."
            }
        }
    }

    if ([int]$Response.returned -gt 0) { return $false }
    if ([bool]$Response.truncated) { throw 'Placement probe returned zero elements but reported truncated=true.' }
    return $true
}

function Find-AuthoringPlacement {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory
    )
    $categories = @('OST_Walls', 'OST_Floors', 'OST_StructuralFoundation')
    $candidates = @(Get-AuthoringPlacementCandidates)
    foreach ($candidate in $candidates) {
        $volume = New-AuthoringProbeVolume -OffsetX ([double]$candidate.offsetX) -OffsetY ([double]$candidate.offsetY)
        $probeName = '09b-placement-probe-{0:D2}' -f [int]$candidate.index
        $probe = Invoke-McpTool -Name 'revit_find_elements_in_volume' -Arguments ([ordered]@{
            volume = $volume
            categories = $categories
            match = 'intersects'
            limit = 1
        }) -Port $Port -EvidenceDirectory $EvidenceDirectory -EvidenceName $probeName
        if (Test-AuthoringProbeIsEmpty -Response $probe -ExpectedVolume $volume) {
            $selection = [ordered]@{
                strategy = 'empty-physical-volume-v1'
                candidateIndex = [int]$candidate.index
                attempts = [int]$candidate.index + 1
                offsetX = [double]$candidate.offsetX
                offsetY = [double]$candidate.offsetY
                probeVolume = $volume
                probeCategories = $categories
                probeMatch = 'intersects'
                probeLimit = 1
                zBasis = 'full-supported-internal-origin-envelope'
            }
            Write-JsonAtomic -Path (Join-Path $EvidenceDirectory '09c-placement-selection.json') -Value $selection
            return $selection
        }
    }
    throw "No empty authoring placement was found after $($candidates.Count) deterministic probes. No model write was attempted."
}

function New-AuthoringCommands {
    param(
        [Parameter(Mandatory = $true)][double]$OffsetX,
        [Parameter(Mandatory = $true)][double]$OffsetY,
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$GridName,
        [Parameter(Mandatory = $true)][string]$ViewName
    )
    return @(
        [ordered]@{ command = 'create_grid'; params = [ordered]@{ startX = $OffsetX - 1500; startY = $OffsetY - 1000; endX = $OffsetX - 800; endY = $OffsetY + 5000; name = $GridName } },
        [ordered]@{ command = 'create_line_based_element'; params = [ordered]@{ elementType = 'wall'; startX = $OffsetX; startY = $OffsetY; endX = $OffsetX + 6000; endY = $OffsetY; level = $Level; height = 3000 } },
        [ordered]@{ command = 'create_line_based_element'; params = [ordered]@{ elementType = 'wall'; startX = $OffsetX + 6000; startY = $OffsetY; endX = $OffsetX + 6000; endY = $OffsetY + 4000; level = $Level; height = 3000 } },
        [ordered]@{ command = 'create_line_based_element'; params = [ordered]@{ elementType = 'wall'; startX = $OffsetX + 6000; startY = $OffsetY + 4000; endX = $OffsetX; endY = $OffsetY + 4000; level = $Level; height = 3000 } },
        [ordered]@{ command = 'create_line_based_element'; params = [ordered]@{ elementType = 'wall'; startX = $OffsetX; startY = $OffsetY + 4000; endX = $OffsetX; endY = $OffsetY; level = $Level; height = 3000 } },
        [ordered]@{ command = 'create_surface_based_element'; params = [ordered]@{
            elementType = 'floor'
            points = @(
                [ordered]@{ x = $OffsetX; y = $OffsetY },
                [ordered]@{ x = $OffsetX + 6000; y = $OffsetY },
                [ordered]@{ x = $OffsetX + 6000; y = $OffsetY + 4000 },
                [ordered]@{ x = $OffsetX; y = $OffsetY + 4000 }
            )
            level = $Level
        } },
        [ordered]@{ command = 'create_view'; params = [ordered]@{ viewType = 'floorplan'; level = $Level; name = $ViewName } }
    )
}

function Invoke-AuthoringSmoke {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory
    )
    if (-not $ApproveModelChanges) {
        throw 'RunAuthoring creates elements in the copied smoke RVT. Rerun with -ApproveModelChanges after reviewing docs/testing/revit-2026-live-smoke.md.'
    }
    if ([string]$State.server.profile -ne 'safe-authoring') { throw 'Authoring smoke requires -Profile safe-authoring.' }
    if ($null -eq $State.revit -or [string]::IsNullOrWhiteSpace([string]$State.revit.copiedModel)) {
        throw 'Authoring smoke requires a harness-copied RVT.'
    }
    if (-not [bool]$State.revit.launchedByHarness) { throw 'Authoring smoke requires a Revit process launched by this run.' }

    $port = [int]$State.server.port
    Assert-PathUnder -Path $EvidenceDirectory -Parent ([string]$State.runDirectory) -Label 'authoring evidence directory'
    $httpEvidence = $EvidenceDirectory
    $baseline = $State.smoke.read.statistics
    Assert-CompleteModelStatistics -Statistics $baseline -Label 'authoring baseline statistics'
    $expectedDocumentPath = Get-NormalizedPath ([string]$State.revit.copiedModel)
    if ([string]::IsNullOrWhiteSpace([string]$baseline.documentPath)) {
        throw 'Active Revit document is unsaved or omitted documentPath. Refusing authoring calls.'
    }
    Assert-ExactPath -Actual ([string]$baseline.documentPath) -Expected $expectedDocumentPath -Label 'authoring active document path'
    $expectedTitle = [System.IO.Path]::GetFileNameWithoutExtension([string]$State.revit.copiedModel)
    if (-not ([string]$baseline.projectName).Equals($expectedTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Active Revit document '$($baseline.projectName)' is not the copied smoke model '$expectedTitle'. Refusing authoring calls."
    }
    $view = $State.smoke.read.view
    $level = ''
    foreach ($propertyName in @('levelName', 'level')) {
        $property = $view.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $level = [string]$property.Value
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($level)) {
        throw 'Active view has no level. Open a floor-plan view in the copied model and rerun RunAuthoring.'
    }

    $suffix = ([string]$State.runId -replace '[^A-Za-z0-9]', '').Substring(0, [math]::Min(10, ([string]$State.runId -replace '[^A-Za-z0-9]', '').Length))
    $placement = Find-AuthoringPlacement -Port $port -EvidenceDirectory $httpEvidence
    $rollbackName = "CRIA_E2E_ROLLBACK_$suffix"
    $rollbackCommands = @(
        [ordered]@{ command = 'create_level'; params = [ordered]@{ elevation = 12000; name = $rollbackName } },
        [ordered]@{ command = 'create_grid'; params = [ordered]@{ startX = 0; startY = 0; endX = 0; endY = 0; name = "CRIA_FAIL_$suffix" } }
    ) | ConvertTo-Json -Depth 10 -Compress
    $rollback = Invoke-McpTool -Name 'revit_batch_execute' -Arguments ([ordered]@{ commands = $rollbackCommands; continueOnError = $false }) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '10-rollback-batch'
    if ($rollback.rolledBack -ne $true) { throw 'Expected-failure batch did not report rolledBack=true.' }
    $rollbackLevelResults = @($rollback.results | Where-Object { [int]$_.index -eq 0 -and $_.ok -eq $true })
    if ($rollbackLevelResults.Count -ne 1 -or $null -eq $rollbackLevelResults[0].data.elementId) {
        throw 'Rollback batch did not return exactly one temporary level element ID.'
    }
    $rollbackLevelId = [long]$rollbackLevelResults[0].data.elementId
    $rollbackDetails = Invoke-McpTool -Name 'revit_get_element_details' -Arguments ([ordered]@{ elementIds = @($rollbackLevelId) }) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '11-rollback-level-details'
    if ([int]$rollbackDetails.returned -ne 0) {
        throw "TransactionGroup rollback failed: temporary level $rollbackLevelId still resolves."
    }
    $afterRollbackStats = Invoke-McpTool -Name 'revit_analyze_model_statistics' -Arguments ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '12-after-rollback-statistics'
    Assert-CompleteModelStatistics -Statistics $afterRollbackStats -Label 'post-rollback statistics'
    if ([int]$afterRollbackStats.elementsCounted -ne [int]$baseline.elementsCounted) {
        throw "Rollback batch changed element count from $($baseline.elementsCounted) to $($afterRollbackStats.elementsCounted)."
    }

    $gridName = "CRIA-$suffix"
    $viewName = "CRIA E2E PLAN $suffix"
    $commands = @(New-AuthoringCommands -OffsetX ([double]$placement.offsetX) -OffsetY ([double]$placement.offsetY) `
        -Level $level -GridName $gridName -ViewName $viewName)
    $commandJson = $commands | ConvertTo-Json -Depth 15 -Compress
    $authoring = Invoke-McpTool -Name 'revit_batch_execute' -Arguments ([ordered]@{ commands = $commandJson; continueOnError = $false }) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '13-authoring-batch'
    if ($authoring.rolledBack -eq $true) { throw 'Authoring batch rolled back.' }
    $failures = @($authoring.results | Where-Object { $_.ok -ne $true })
    if ($failures.Count -gt 0) { throw "Authoring batch reported $($failures.Count) failure(s)."
    }
    $ids = @($authoring.results | ForEach-Object { if ($null -ne $_.data.elementId) { [long]$_.data.elementId } })
    if ($ids.Count -lt 7) { throw "Authoring batch returned only $($ids.Count) created element IDs; expected at least 7." }
    $floorResults = @($authoring.results | Where-Object { [int]$_.index -eq 5 -and $_.ok -eq $true })
    if ($floorResults.Count -ne 1) { throw 'Authoring batch did not return exactly one successful surface-element result at index 5.' }
    $floorId = [long]$floorResults[0].data.elementId

    $details = Invoke-McpTool -Name 'revit_get_element_details' -Arguments ([ordered]@{ elementIds = $ids }) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '14-created-details'
    if ([int]$details.returned -ne $ids.Count) { throw "Only $($details.returned) of $($ids.Count) created elements resolved."
    }
    $floorDetails = @($details.elements | Where-Object { [long]$_.elementId -eq $floorId })
    if ($floorDetails.Count -ne 1) { throw "Created surface element $floorId did not resolve exactly once in element details." }
    $floorCategory = [string]$floorDetails[0].category
    if ($floorCategory -eq 'Structural Foundations') {
        throw "Floor regression: created surface element $floorId resolved to Structural Foundations."
    }
    if ($floorCategory -ne 'Floors') {
        throw "Created surface element $floorId resolved to unexpected category '$floorCategory'; expected Floors."
    }
    $geometryResults = @($authoring.results | Where-Object { [int]$_.index -ge 1 -and [int]$_.index -le 5 -and $_.ok -eq $true })
    if ($geometryResults.Count -ne 5) { throw 'Authoring batch did not return the expected four walls and one floor.' }
    $geometryIds = @($geometryResults | ForEach-Object { [long]$_.data.elementId })
    $geometryDetails = @($details.elements | Where-Object { $geometryIds -contains [long]$_.elementId })
    if ($geometryDetails.Count -ne 5) { throw 'Created geometry details did not include the expected four walls and one floor.' }
    foreach ($element in $geometryDetails) {
        if ($null -eq $element.boundingBox) { throw "Created geometry $($element.elementId) has no model bounding box." }
        $minX = [double]$element.boundingBox.min.x
        $minY = [double]$element.boundingBox.min.y
        $maxX = [double]$element.boundingBox.max.x
        $maxY = [double]$element.boundingBox.max.y
        if ($minX -lt ([double]$placement.probeVolume.min.x - 1.0) -or
            $minY -lt ([double]$placement.probeVolume.min.y - 1.0) -or
            $maxX -gt ([double]$placement.probeVolume.max.x + 1.0) -or
            $maxY -gt ([double]$placement.probeVolume.max.y + 1.0)) {
            throw "Created geometry $($element.elementId) lies outside the selected empty placement volume."
        }
    }
    $afterStats = Invoke-McpTool -Name 'revit_analyze_model_statistics' -Arguments ([ordered]@{}) -Port $port -EvidenceDirectory $httpEvidence -EvidenceName '15-after-authoring-statistics'
    Assert-CompleteModelStatistics -Statistics $afterStats -Label 'post-authoring statistics'

    $undoInstructions = @"
Authoring smoke created $($ids.Count) elements in the copied model:
$($State.revit.copiedModel)

In Revit, press Ctrl+Z exactly once and confirm the undo item is "MCP: batch_execute".
Do not close Revit yet. Then run:

pwsh scripts/revit-2026-smoke.ps1 -Phase VerifyUndo

The harness never saves, closes, deletes, or discards the copied model. You decide what to do with it after verification.
"@
    $undoInstructions | Set-Content -LiteralPath (Join-Path ([string]$State.runDirectory) 'UNDO_REQUIRED.txt') -Encoding UTF8
    return [ordered]@{
        rollbackVerifiedByIdAndElementCount = $true
        rollbackLevelId = $rollbackLevelId
        baselineElements = [int]$baseline.elementsCounted
        createdIds = $ids
        floorId = $floorId
        floorCategory = $floorCategory
        afterAuthoringElements = [int]$afterStats.elementsCounted
        viewName = $viewName
        placement = $placement
        copiedModel = [string]$State.revit.copiedModel
        undoRequired = $true
    }
}

function Invoke-Run {
    $paths = Get-Paths
    $state = Get-ActiveState
    if (@('Deployed', 'ServerStarting', 'ServerStarted', 'Running') -notcontains [string]$state.status) {
        throw "Run requires a verified deployed state; current status is '$($state.status)'."
    }
    Assert-DeployedPayloadUnchanged $state
    if ($RunAuthoring -and -not $ApproveModelChanges) {
        throw 'RunAuthoring requires -ApproveModelChanges.'
    }
    $isResume = [string]$state.status -eq 'Running'
    if ($WhatIfPreference) {
        if ($isResume) {
            Write-Host "Would validate and resume the exact recorded Revit/server session on $HttpPort, without starting or stopping either process."
        } else {
            Write-Host "Would start/reuse Revit, start an owned HTTP server on $HttpPort, and run $Profile smoke checks."
        }
        return
    }

    $attemptId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $httpEvidence = Join-Path ([string]$state.runDirectory) "http-attempt-$attemptId"
    Assert-PathUnder -Path $httpEvidence -Parent ([string]$state.runDirectory) -Label 'run-attempt evidence directory'
    if (Test-Path -LiteralPath $httpEvidence) { throw "Run-attempt evidence already exists: '$httpEvidence'." }
    New-Item -ItemType Directory -Path $httpEvidence | Out-Null
    $attemptPath = Join-Path $httpEvidence 'attempt.json'
    $attempt = [ordered]@{
        schemaVersion = 1
        attemptId = $attemptId
        runId = [string]$state.runId
        startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        resumed = $isResume
        initialState = [string]$state.status
        profile = $Profile
        httpPort = $HttpPort
        evidenceDirectory = $httpEvidence
        phase = 'session-validation'
        status = 'Running'
    }
    Write-JsonAtomic -Path $attemptPath -Value $attempt

    try {
        if ($isResume) {
            Assert-RunningSessionForResume -State $state -Paths $paths -Port $HttpPort -SelectedProfile $Profile
            Assert-RunResumeHasNoAmbiguousAuthoring $state
            Write-Host "Resuming harness-owned run $($state.runId); server PID $($state.server.pid) and Revit PID $($state.revit.pid) were identity-checked."
        } else {
            $state.logOffsets = Get-LogOffsets $paths
            $state.server = Start-OwnedHttpServer -State $state -Port $HttpPort -SelectedProfile $Profile
            $state.status = 'ServerStarted'
            Save-ActiveState $state
            $state.revit = Start-OrReuseRevit -State $state -Paths $paths
            $state.status = 'Running'
            Save-ActiveState $state
        }

        $attempt.phase = 'protocol-read'
        Write-JsonAtomic -Path $attemptPath -Value $attempt
        $read = Invoke-ProtocolAndReadSmoke -State $state -EvidenceDirectory $httpEvidence
        $state.smoke = [ordered]@{
            evidenceDirectory = $httpEvidence
            read = $read
            authoring = $null
            completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-ActiveState $state

        if ($RunAuthoring) {
            $attempt.phase = 'authoring'
            Write-JsonAtomic -Path $attemptPath -Value $attempt
            $state.smoke.authoring = Invoke-AuthoringSmoke -State $state -EvidenceDirectory $httpEvidence
            Save-ActiveState $state
            Write-Warning "Authoring smoke passed. Press Ctrl+Z exactly once in Revit, then run -Phase VerifyUndo. See '$($state.runDirectory)\UNDO_REQUIRED.txt'."
        } else {
            Write-Host "Protocol and live read smoke passed. Evidence: $httpEvidence"
        }
        $attempt.phase = 'complete'
        $attempt.status = 'Completed'
        $attempt.completedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-JsonAtomic -Path $attemptPath -Value $attempt
    } catch {
        $runError = $_
        try {
            $attempt.status = 'Failed'
            $attempt.failedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Write-JsonAtomic -Path $attemptPath -Value $attempt
            Write-JsonAtomic -Path (Join-Path $httpEvidence 'failure.json') -Value ([ordered]@{
                schemaVersion = 1
                attemptId = $attemptId
                failedUtc = $attempt.failedUtc
                phase = $attempt.phase
                exceptionType = $runError.Exception.GetType().FullName
                message = $runError.Exception.Message
                fullyQualifiedErrorId = [string]$runError.FullyQualifiedErrorId
                category = [string]$runError.CategoryInfo
                position = [string]$runError.InvocationInfo.PositionMessage
                scriptStackTrace = [string]$runError.ScriptStackTrace
            })
            Write-Warning "Run failed during '$($attempt.phase)'. Failure evidence: $(Join-Path $httpEvidence 'failure.json')"
        } catch {
            Write-Warning "Run failed, and failure evidence could not be completed: $($_.Exception.Message)"
        }
        throw $runError
    }
}

function Invoke-VerifyUndo {
    $state = Get-ActiveState
    if ([string]$state.status -ne 'Running') { throw "VerifyUndo requires Running state; got '$($state.status)'." }
    if ($null -eq $state.smoke.authoring -or @($state.smoke.authoring.createdIds).Count -eq 0) {
        throw 'No authoring smoke IDs are recorded for this run.'
    }
    $undoVerifiedProperty = $state.smoke.authoring.PSObject.Properties['undoVerified']
    if ($null -ne $undoVerifiedProperty -and [bool]$undoVerifiedProperty.Value) {
        Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoRequired' -Value $false
        Save-ActiveState $state
        $existingUndoMarker = Join-Path ([string]$state.runDirectory) 'UNDO_REQUIRED.txt'
        $existingUndoArchive = Join-Path ([string]$state.runDirectory) 'UNDO_INSTRUCTIONS.archived.txt'
        if (Test-Path -LiteralPath $existingUndoMarker -PathType Leaf) {
            if (Test-Path -LiteralPath $existingUndoArchive) {
                throw "Undo is already verified, but both '$existingUndoMarker' and '$existingUndoArchive' exist. Inspect them before changing either file."
            }
            Move-Item -LiteralPath $existingUndoMarker -Destination $existingUndoArchive
        }
        Write-Host 'Undo was already verified for this run; no MCP calls were repeated.'
        return
    }
    if (-not [bool]$state.revit.launchedByHarness -or [string]::IsNullOrWhiteSpace([string]$state.revit.copiedModel)) {
        throw 'Undo verification requires the recorded harness-launched copied model.'
    }
    Assert-PathUnder -Path ([string]$state.revit.copiedModel) -Parent ([string]$state.runDirectory) -Label 'recorded copied model'
    if (-not (Test-Path -LiteralPath ([string]$state.revit.copiedModel) -PathType Leaf)) {
        throw "Recorded copied model is missing: '$($state.revit.copiedModel)'."
    }
    Assert-RevitSessionIdentity $state | Out-Null
    $server = Assert-OwnedServerProcess $state.server
    if ($null -eq $server) { throw 'The harness-owned MCP server is not running.' }
    $ids = @($state.smoke.authoring.createdIds | ForEach-Object { [long]$_ })
    $httpEvidence = Join-Path ([string]$state.runDirectory) 'http'
    $evidenceProperty = $state.smoke.PSObject.Properties['evidenceDirectory']
    if ($null -ne $evidenceProperty -and -not [string]::IsNullOrWhiteSpace([string]$evidenceProperty.Value)) {
        $httpEvidence = [string]$evidenceProperty.Value
    }
    Assert-PathUnder -Path $httpEvidence -Parent ([string]$state.runDirectory) -Label 'undo HTTP evidence directory'
    if (-not (Test-Path -LiteralPath $httpEvidence -PathType Container)) {
        throw "Recorded HTTP evidence directory is missing: '$httpEvidence'."
    }
    $statistics = Invoke-McpTool -Name 'revit_analyze_model_statistics' -Arguments ([ordered]@{}) -Port ([int]$state.server.port) -EvidenceDirectory $httpEvidence -EvidenceName '16-after-undo-session-statistics'
    Assert-CompleteModelStatistics -Statistics $statistics -Label 'undo verification statistics'
    if ([string]::IsNullOrWhiteSpace([string]$statistics.documentPath)) {
        throw 'Undo verification active document is unsaved or omitted documentPath.'
    }
    Assert-ExactPath -Actual ([string]$statistics.documentPath) -Expected ([string]$state.revit.copiedModel) -Label 'undo active document path'
    $expectedTitle = [System.IO.Path]::GetFileNameWithoutExtension([string]$state.revit.copiedModel)
    if (-not ([string]$statistics.projectName).Equals($expectedTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Undo verification is routed to document '$($statistics.projectName)', not recorded copied model '$expectedTitle'."
    }
    if ([int]$statistics.elementsCounted -ne [int]$state.smoke.authoring.baselineElements) {
        throw "Active copied model has element count $($statistics.elementsCounted), not baseline $($state.smoke.authoring.baselineElements)."
    }
    $details = Invoke-McpTool -Name 'revit_get_element_details' -Arguments ([ordered]@{ elementIds = $ids }) -Port ([int]$state.server.port) -EvidenceDirectory $httpEvidence -EvidenceName '17-after-undo-details'
    if ([int]$details.returned -ne 0) {
        throw "Undo verification failed: $($details.returned) authoring element(s) still resolve. Do not press Undo repeatedly; inspect Revit's undo history."
    }
    Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoRequired' -Value $false
    Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoVerified' -Value $true
    Set-ObjectProperty -Object $state.smoke.authoring -Name 'undoVerifiedUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
    Save-ActiveState $state
    $undoRequiredMarker = Join-Path ([string]$state.runDirectory) 'UNDO_REQUIRED.txt'
    $archivedUndoInstructions = Join-Path ([string]$state.runDirectory) 'UNDO_INSTRUCTIONS.archived.txt'
    if (Test-Path -LiteralPath $undoRequiredMarker -PathType Leaf) {
        if (Test-Path -LiteralPath $archivedUndoInstructions) {
            throw "Undo is verified, but both '$undoRequiredMarker' and '$archivedUndoInstructions' exist. Inspect them before changing either file."
        }
        Move-Item -LiteralPath $undoRequiredMarker -Destination $archivedUndoInstructions
    }
    Write-Host 'Single-step Revit undo verified: all recorded IDs are gone, the element count returned to baseline, and the Undo-required marker was cleared.'
}

function Invoke-Collect {
    $paths = Get-Paths
    $dotnet = Get-DotNetInfo
    $state = Get-ActiveState
    $evidence = Join-Path ([string]$state.runDirectory) 'collected'
    if (Test-Path -LiteralPath $evidence) { throw "Collected evidence already exists: '$evidence'." }
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null

    $system = [ordered]@{
        collectedUtc = (Get-Date).ToUniversalTime().ToString('o')
        computerName = $env:COMPUTERNAME
        os = [System.Environment]::OSVersion.VersionString
        powershell = $PSVersionTable.PSVersion.ToString()
        dotnet = $dotnet
        revit = if (Test-Path -LiteralPath $paths.revitExe) {
            $item = Get-Item -LiteralPath $paths.revitExe
            [ordered]@{ path = $item.FullName; fileVersion = $item.VersionInfo.FileVersion; productVersion = $item.VersionInfo.ProductVersion; sha256 = Get-Sha256 $item.FullName }
        } else { $null }
        serverRuntime = Get-ServerRuntimeInventory $paths
        activeManifest = Get-FileSnapshot $paths.manifestTarget
        activePlugin = Get-TreeInventory $paths.pluginTarget
        statePath = [string]$state.statePath
    }
    Write-JsonAtomic -Path (Join-Path $evidence 'system.json') -Value $system

    if (-not [string]::IsNullOrWhiteSpace([string]$paths.discoveryFile) -and (Test-Path -LiteralPath $paths.discoveryFile)) {
        Write-JsonAtomic -Path (Join-Path $evidence 'revit-2026.discovery.sanitized.json') -Value (Get-SanitizedDiscovery $paths.discoveryFile)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$paths.localDataRoot)) {
        foreach ($name in @('debug.log', 'revit-mcp.log', 'mcp-calls.jsonl')) {
            $source = Join-Path $paths.localDataRoot $name
            $offset = 0
            if ($null -ne $state.logOffsets -and $null -ne $state.logOffsets.$name) { $offset = [long]$state.logOffsets.$name }
            Copy-AppendedLogBytes -Source $source -Offset $offset -Destination (Join-Path $evidence $name)
        }
    }
    Write-Host "Evidence collected locally: $evidence"
    Write-Host 'The discovery auth token was intentionally omitted. Only log bytes appended during this run were copied.'
}

function Invoke-InterruptedRestoreCompletion {
    param([Parameter(Mandatory = $true)]$State)
    if ($null -eq $State.restore) { throw 'Restoring state has no restore journal; refusing automatic recovery.' }
    $targetPlugin = Get-TreeInventory ([string]$State.paths.pluginTarget)
    $targetManifest = Get-FileSnapshot ([string]$State.paths.manifestTarget)
    $pluginIsBefore = Test-TreeInventoryEquivalent $State.before.plugin $targetPlugin
    $pluginIsSmoke = Test-TreeInventoryEquivalent $State.deployed.plugin $targetPlugin
    $manifestIsBefore = Test-FileSnapshotEquivalent $State.before.manifest $targetManifest
    $manifestIsSmoke = Test-FileSnapshotEquivalent $State.deployed.manifest $targetManifest
    if ([bool]$targetPlugin.exists -and -not $pluginIsBefore -and -not $pluginIsSmoke) {
        throw 'Interrupted restore found an unrecognized active plugin hash; refusing to move it.'
    }
    if ([bool]$targetManifest.exists -and -not $manifestIsBefore -and -not $manifestIsSmoke) {
        throw 'Interrupted restore found an unrecognized active manifest hash; refusing to move it.'
    }
    $archive = [string]$State.restore.deployedArchive
    $archivedPlugin = Join-Path $archive 'RvtMcp'
    $archivedManifest = Join-Path $archive 'RvtMcp.R26.addin'
    if (Test-Path -LiteralPath $archivedPlugin -PathType Container) {
        Assert-InventoryMatches -Expected $State.deployed.plugin -Actual (Get-TreeInventory $archivedPlugin) -Label 'interrupted restore archived smoke plugin'
    }
    if (Test-Path -LiteralPath $archivedManifest -PathType Leaf) {
        if (-not (Test-FileSnapshotEquivalent $State.deployed.manifest (Get-FileSnapshot $archivedManifest))) {
            throw 'Interrupted restore archived smoke manifest hash mismatch.'
        }
    }
    Write-Host 'Interrupted restore completion preview:'
    Write-Host "  Active plugin is pre-deploy state: $pluginIsBefore"
    Write-Host "  Active manifest is pre-deploy state: $manifestIsBefore"
    if (-not $PSCmdlet.ShouldProcess([string]$State.paths.addinsRoot, "Complete interrupted restore $($State.runId) to exact pre-deploy state")) { return $false }

    if (-not (Test-Path -LiteralPath $archive)) { New-Item -ItemType Directory -Path $archive | Out-Null }
    if (-not $pluginIsBefore -and $pluginIsSmoke) {
        if (Test-Path -LiteralPath $archivedPlugin) { throw 'Interrupted restore found both active and archived smoke plugin payloads.' }
        Move-Item -LiteralPath ([string]$State.paths.pluginTarget) -Destination $archivedPlugin
    }
    if (-not $manifestIsBefore -and $manifestIsSmoke) {
        if (Test-Path -LiteralPath $archivedManifest) { throw 'Interrupted restore found both active and archived smoke manifests.' }
        Move-Item -LiteralPath ([string]$State.paths.manifestTarget) -Destination $archivedManifest
    }

    if ([bool]$State.before.plugin.exists -and -not (Test-Path -LiteralPath ([string]$State.paths.pluginTarget) -PathType Container)) {
        $backupPlugin = Join-Path ([string]$State.runDirectory) 'backup\RvtMcp'
        Assert-InventoryMatches -Expected $State.before.plugin -Actual (Get-TreeInventory $backupPlugin) -Label 'interrupted restore plugin backup'
        Copy-DirectoryContents -Source $backupPlugin -Destination ([string]$State.paths.pluginTarget)
    }
    if ([bool]$State.before.manifest.exists -and -not (Test-Path -LiteralPath ([string]$State.paths.manifestTarget) -PathType Leaf)) {
        $backupManifest = Join-Path ([string]$State.runDirectory) 'backup\RvtMcp.R26.addin'
        if (-not (Test-FileSnapshotEquivalent $State.before.manifest (Get-FileSnapshot $backupManifest))) {
            throw 'Interrupted restore manifest backup hash mismatch.'
        }
        Copy-Item -LiteralPath $backupManifest -Destination ([string]$State.paths.manifestTarget)
    }
    Assert-InventoryMatches -Expected $State.before.plugin -Actual (Get-TreeInventory ([string]$State.paths.pluginTarget)) -Label 'interrupted restore final plugin'
    if (-not (Test-FileSnapshotEquivalent $State.before.manifest (Get-FileSnapshot ([string]$State.paths.manifestTarget)))) {
        throw 'Interrupted restore final manifest hash mismatch.'
    }

    $leftovers = Join-Path $archive 'recovery-leftovers'
    foreach ($entry in @(
        @{ Path = [string]$State.paths.originalPluginSibling; Kind = 'plugin'; Expected = $State.before.plugin; OwnedStage = $false },
        @{ Path = [string]$State.restore.pluginStage; Kind = 'plugin'; Expected = $State.before.plugin; OwnedStage = $true },
        @{ Path = [string]$State.paths.originalManifestSibling; Kind = 'manifest'; Expected = $State.before.manifest; OwnedStage = $false },
        @{ Path = [string]$State.restore.manifestStage; Kind = 'manifest'; Expected = $State.before.manifest; OwnedStage = $true }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
        $verified = $false
        if ($entry.Kind -eq 'plugin' -and -not $entry.OwnedStage) {
            Assert-InventoryMatches -Expected $entry.Expected -Actual (Get-TreeInventory $entry.Path) -Label 'interrupted restore leftover plugin'
            $verified = $true
        } elseif ($entry.Kind -eq 'manifest' -and -not $entry.OwnedStage -and -not (Test-FileSnapshotEquivalent $entry.Expected (Get-FileSnapshot $entry.Path))) {
            throw "Interrupted restore leftover manifest hash mismatch: '$($entry.Path)'."
        } elseif (-not $entry.OwnedStage) {
            $verified = $true
        } else {
            Assert-NoReparsePoint -Path $entry.Path -Label 'interrupted restore owned staging path'
        }
        if (-not (Test-Path -LiteralPath $leftovers)) { New-Item -ItemType Directory -Path $leftovers | Out-Null }
        $snapshot = if ($entry.Kind -eq 'plugin') { Get-TreeInventory $entry.Path } else { Get-FileSnapshot $entry.Path }
        $prefix = if ($entry.OwnedStage -and -not $verified) { 'unverified-partial-stage-' } else { 'verified-' }
        $leaf = Split-Path -Leaf $entry.Path
        Write-JsonAtomic -Path (Join-Path $leftovers "$prefix$leaf.inventory.json") -Value $snapshot
        $destination = Join-Path $leftovers "$prefix$leaf"
        if (Test-Path -LiteralPath $destination) { throw "Interrupted restore leftover archive collision: '$destination'." }
        Move-Item -LiteralPath $entry.Path -Destination $destination
    }
    $State.status = 'Restored'
    Set-ObjectProperty -Object $State -Name 'interruptedRestoreCompletedUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
    Save-ActiveState $State
    Write-Host 'Interrupted restore completed and the pre-deploy add-in state was hash-verified.'
    return $true
}

function Invoke-Restore {
    $state = Get-ActiveState
    if ([string]$state.status -eq 'Restored') {
        Write-Host "Run $($state.runId) is already restored."
        return
    }
    if (-not $WhatIfPreference -and -not $ApproveAddinChange) {
        throw 'Restore modifies %APPDATA%\Autodesk\Revit\Addins\2026. Preview with -WhatIf, then rerun with -ApproveAddinChange.'
    }
    Assert-RevitClosed

    if (@('Deploying', 'DeployRollbackFailed') -contains [string]$state.status) {
        Invoke-InterruptedDeployRecovery $state | Out-Null
        return
    }

    $ownedServer = $null
    $serverRecord = $state.server
    $serverStartingPath = Join-Path ([string]$state.runDirectory) 'server-starting.json'
    if (($null -eq $serverRecord -or $null -eq $serverRecord.pid) -and (Test-Path -LiteralPath $serverStartingPath -PathType Leaf)) {
        $serverRecord = Read-JsonFile $serverStartingPath
    }
    if ($null -ne $serverRecord -and $null -ne $serverRecord.pid) {
        $ownedServer = Assert-OwnedServerProcess $serverRecord
        if ($null -ne $ownedServer -and ($null -eq $state.server -or $null -eq $state.server.pid)) {
            $state.server = $serverRecord
            Save-ActiveState $state
        }
    }
    if ($null -ne $ownedServer -and -not $StopOwnedServer) {
        throw "Harness-owned server PID $($ownedServer.Id) is still running. Rerun Restore with -StopOwnedServer. No unrelated server will be touched."
    }
    if ([string]$state.status -eq 'Restoring') {
        if ($null -ne $ownedServer) { Stop-OwnedServerProcess $state }
        Invoke-InterruptedRestoreCompletion $state | Out-Null
        return
    }
    Assert-DeployedPayloadUnchanged $state
    Write-Host 'Restore preview:'
    Write-Host "  Current deployed plugin -> $($state.runDirectory)\deployed-at-restore\RvtMcp"
    Write-Host "  Restore plugin existed before: $($state.before.plugin.exists)"
    Write-Host "  Restore manifest existed before: $($state.before.manifest.exists)"
    if (-not $PSCmdlet.ShouldProcess([string]$state.paths.addinsRoot, "Restore exact pre-smoke add-in state for run $($state.runId)")) { return }

    if ($null -ne $ownedServer) { Stop-OwnedServerProcess $state }
    $deployedArchive = Join-Path ([string]$state.runDirectory) 'deployed-at-restore'
    $restorePluginStage = Join-Path ([string]$state.paths.addinsRoot) ".cria-$($state.runId)-restore-RvtMcp"
    $restoreManifestStage = Join-Path ([string]$state.paths.addinsRoot) ".cria-$($state.runId)-restore-RvtMcp.R26.addin.tmp"
    $restoreRecord = [ordered]@{
        deployedArchive = $deployedArchive
        pluginStage = $restorePluginStage
        manifestStage = $restoreManifestStage
        pluginArchived = $false
        manifestArchived = $false
        pluginRestored = $false
        manifestRestored = $false
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Set-ObjectProperty -Object $state -Name 'restore' -Value $restoreRecord
    $state.status = 'Restoring'
    Save-ActiveState $state

    if (Test-Path -LiteralPath $deployedArchive) { throw "Restore archive already exists: '$deployedArchive'." }
    New-Item -ItemType Directory -Path $deployedArchive -Force | Out-Null
    foreach ($stage in @($restorePluginStage, $restoreManifestStage)) {
        if (Test-Path -LiteralPath $stage) { throw "Restore staging collision: '$stage'." }
    }

    if ([bool]$state.before.plugin.exists) {
        $originalSibling = [string]$state.paths.originalPluginSibling
        if (Test-Path -LiteralPath $originalSibling -PathType Container) {
            Assert-InventoryMatches -Expected $state.before.plugin -Actual (Get-TreeInventory $originalSibling) -Label 'inactive original plugin'
            Copy-DirectoryContents -Source $originalSibling -Destination $restorePluginStage
        } else {
            $backupPlugin = Join-Path ([string]$state.runDirectory) 'backup\RvtMcp'
            Assert-InventoryMatches -Expected $state.before.plugin -Actual (Get-TreeInventory $backupPlugin) -Label 'plugin backup'
            Copy-DirectoryContents -Source $backupPlugin -Destination $restorePluginStage
        }
        Assert-InventoryMatches -Expected $state.before.plugin -Actual (Get-TreeInventory $restorePluginStage) -Label 'restore plugin staging'
    }
    if ([bool]$state.before.manifest.exists) {
        $originalManifestSibling = [string]$state.paths.originalManifestSibling
        $sourceManifest = if (Test-Path -LiteralPath $originalManifestSibling -PathType Leaf) {
            $originalManifestSibling
        } else {
            Join-Path ([string]$state.runDirectory) 'backup\RvtMcp.R26.addin'
        }
        if ((Get-Sha256 $sourceManifest) -ne [string]$state.before.manifest.sha256) { throw 'Original manifest hash does not match deployment state.' }
        Copy-Item -LiteralPath $sourceManifest -Destination $restoreManifestStage
    }

    $archivedPlugin = Join-Path $deployedArchive 'RvtMcp'
    $archivedManifest = Join-Path $deployedArchive 'RvtMcp.R26.addin'
    $pluginArchived = $false
    $manifestArchived = $false
    try {
        Move-Item -LiteralPath ([string]$state.paths.pluginTarget) -Destination $archivedPlugin
        $pluginArchived = $true
        $state.restore.pluginArchived = $true
        $state.restore.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-ActiveState $state
        Move-Item -LiteralPath ([string]$state.paths.manifestTarget) -Destination $archivedManifest
        $manifestArchived = $true
        $state.restore.manifestArchived = $true
        $state.restore.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-ActiveState $state
        if ([bool]$state.before.plugin.exists) {
            Move-Item -LiteralPath $restorePluginStage -Destination ([string]$state.paths.pluginTarget)
            $state.restore.pluginRestored = $true
            $state.restore.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-ActiveState $state
        }
        if ([bool]$state.before.manifest.exists) {
            Move-Item -LiteralPath $restoreManifestStage -Destination ([string]$state.paths.manifestTarget)
            $state.restore.manifestRestored = $true
            $state.restore.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-ActiveState $state
        }

        Assert-InventoryMatches -Expected $state.before.plugin -Actual (Get-TreeInventory ([string]$state.paths.pluginTarget)) -Label 'restored plugin'
        $restoredManifest = Get-FileSnapshot ([string]$state.paths.manifestTarget)
        if ([bool]$state.before.manifest.exists) {
            if (-not [bool]$restoredManifest.exists -or (Get-Sha256 ([string]$state.paths.manifestTarget)) -ne [string]$state.before.manifest.sha256) {
                throw 'Restored manifest hash mismatch.'
            }
        } elseif ([bool]$restoredManifest.exists) {
            throw 'Manifest existed after restore but was absent before deployment.'
        }

        foreach ($inactiveOriginal in @([string]$state.paths.originalPluginSibling, [string]$state.paths.originalManifestSibling)) {
            if (Test-Path -LiteralPath $inactiveOriginal) {
                $leaf = Split-Path -Leaf $inactiveOriginal
                Move-Item -LiteralPath $inactiveOriginal -Destination (Join-Path $deployedArchive "inactive-original-$leaf")
            }
        }
        $state.status = 'Restored'
        Set-ObjectProperty -Object $state -Name 'restoredUtc' -Value ((Get-Date).ToUniversalTime().ToString('o'))
        Save-ActiveState $state
        Write-Host 'Original Revit 2026 add-in state restored and hash-verified.'
        Write-Host "The smoke payload was moved, not deleted: $deployedArchive"
    } catch {
        $restoreError = $_
        Write-Warning "Restore stopped before completion: $($restoreError.Exception.Message)"
        $state.status = 'Restoring'
        Set-ObjectProperty -Object $state -Name 'restoreFailure' -Value $restoreError.Exception.Message
        Save-ActiveState $state
        throw "Restore is journaled as interrupted. Close Revit and rerun the same Restore command; exact hashes will be reconciled before any further move. Original error: $($restoreError.Exception.Message)"
    }
}

function Invoke-SelfTest {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cria-smoke-selftest-$([guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $source = Join-Path $tempRoot 'source'
        New-Item -ItemType Directory -Path (Join-Path $source 'nested') -Force | Out-Null
        'alpha' | Set-Content -LiteralPath (Join-Path $source 'a.txt') -Encoding UTF8
        'beta' | Set-Content -LiteralPath (Join-Path $source 'nested\b.txt') -Encoding UTF8
        $first = Get-TreeInventory $source
        if ($first.fileCount -ne 2) { throw 'SelfTest: inventory file count failed.' }

        $copy = Join-Path $tempRoot 'copy'
        Copy-DirectoryContents -Source $source -Destination $copy
        Assert-InventoryMatches -Expected $first -Actual (Get-TreeInventory $copy) -Label 'self-test copy'
        'changed' | Set-Content -LiteralPath (Join-Path $copy 'a.txt') -Encoding UTF8
        $changedRejected = $false
        try { Assert-InventoryMatches -Expected $first -Actual (Get-TreeInventory $copy) -Label 'changed self-test copy' } catch { $changedRejected = $true }
        if (-not $changedRejected) { throw 'SelfTest: changed inventory was not rejected.' }

        $pathRejected = $false
        try { Assert-PathUnder -Path (Join-Path $tempRoot '..\escape') -Parent $tempRoot -Label 'escape test' } catch { $pathRejected = $true }
        if (-not $pathRejected) { throw 'SelfTest: path escape was not rejected.' }

        $json = '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
        $parsedJson = ConvertFrom-McpHttpBody $json
        if ($parsedJson.result.ok -ne $true) { throw 'SelfTest: JSON MCP parse failed.' }
        Assert-McpJsonRpcSuccess -Parsed $parsedJson -Method 'self-test/result'
        $sse = "event: message`ndata: $json`n`n"
        if ((ConvertFrom-McpHttpBody $sse).result.ok -ne $true) { throw 'SelfTest: SSE MCP parse failed.' }
        $rpcErrorRejected = $false
        try {
            Assert-McpJsonRpcSuccess -Parsed ('{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"expected"}}' | ConvertFrom-Json) -Method 'self-test/error'
        } catch { $rpcErrorRejected = $true }
        if (-not $rpcErrorRejected) { throw 'SelfTest: an explicit JSON-RPC error was not rejected.' }

        $recordedUtc = [datetime]::Parse(
            '2026-08-13T00:33:04.1234567Z',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        $roundTrippedState = ([ordered]@{ startTimeUtc = $recordedUtc.ToString('o') } | ConvertTo-Json | ConvertFrom-Json)
        $roundTrippedUtc = ConvertTo-UtcDateTime -Value $roundTrippedState.startTimeUtc -Label 'self-test JSON timestamp'
        if ($roundTrippedUtc.Ticks -ne $recordedUtc.Ticks -or $roundTrippedUtc.Kind -ne [System.DateTimeKind]::Utc) {
            throw 'SelfTest: JSON round-trip changed the recorded UTC process start time.'
        }
        $stringUtc = ConvertTo-UtcDateTime -Value '2026-08-13T00:33:04.1234567Z' -Label 'self-test string timestamp'
        if ($stringUtc.Ticks -ne $recordedUtc.Ticks) { throw 'SelfTest: ISO string timestamp normalization changed the instant.' }

        $deserializedState = ([ordered]@{
            status = 'Running'
            server = $null
            smoke = [ordered]@{
                authoring = [ordered]@{
                    baselineElements = 1
                    createdIds = @(2)
                }
            }
        } | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        Set-ObjectProperty -Object $deserializedState -Name 'restore' -Value ([ordered]@{ pluginArchived = $false })
        Set-ObjectProperty -Object $deserializedState -Name 'restoreFailure' -Value 'expected self-test failure'
        if ($null -eq $deserializedState.restore -or $deserializedState.restore.pluginArchived -ne $false -or
            [string]$deserializedState.restoreFailure -ne 'expected self-test failure') {
            throw 'SelfTest: new recovery properties could not be added to JSON-deserialized state.'
        }
        $undoVerifiedUtc = '2026-08-13T00:33:04.1234567Z'
        Set-ObjectProperty -Object $deserializedState.smoke.authoring -Name 'undoRequired' -Value $false
        Set-ObjectProperty -Object $deserializedState.smoke.authoring -Name 'undoVerified' -Value $true
        Set-ObjectProperty -Object $deserializedState.smoke.authoring -Name 'undoVerifiedUtc' -Value $undoVerifiedUtc
        if ($deserializedState.smoke.authoring.undoRequired -ne $false -or
            $deserializedState.smoke.authoring.undoVerified -ne $true -or
            [string]$deserializedState.smoke.authoring.undoVerifiedUtc -ne $undoVerifiedUtc) {
            throw 'SelfTest: new undo verification properties could not be added to JSON-deserialized authoring state.'
        }

        $placementCandidates = @(Get-AuthoringPlacementCandidates)
        if ($placementCandidates.Count -ne 25) { throw 'SelfTest: authoring placement candidate count changed.' }
        if ([double]$placementCandidates[0].offsetX -ne 0 -or [double]$placementCandidates[0].offsetY -ne 0) {
            throw 'SelfTest: the first authoring placement candidate is not the origin.'
        }
        $candidateKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($candidate in $placementCandidates) {
            $key = '{0:R},{1:R}' -f [double]$candidate.offsetX, [double]$candidate.offsetY
            if (-not $candidateKeys.Add($key)) { throw "SelfTest: duplicate authoring placement candidate $key." }
        }

        $probeVolume = New-AuthoringProbeVolume -OffsetX 50000 -OffsetY -50000
        if ([double]$probeVolume.min.x -ne 48000 -or [double]$probeVolume.min.y -ne -52000 -or
            [double]$probeVolume.max.x -ne 58000 -or [double]$probeVolume.max.y -ne -44000 -or
            [double]$probeVolume.min.z -ne -16000000 -or [double]$probeVolume.max.z -ne 16000000) {
            throw 'SelfTest: authoring probe volume no longer contains the fixture with its safety margin.'
        }
        $emptyProbe = [pscustomobject]@{
            unit = 'mm'; source = 'axis_aligned_volume'; match = 'intersects'; volume = $probeVolume
            scanned = 0; returned = 0; limit = 1; truncated = $false; elements = @(); failed = @(); error = $null
        }
        if (-not (Test-AuthoringProbeIsEmpty -Response $emptyProbe -ExpectedVolume $probeVolume)) {
            throw 'SelfTest: a complete empty placement probe was not accepted.'
        }
        $occupiedProbe = [pscustomobject]@{
            unit = 'mm'; source = 'axis_aligned_volume'; match = 'intersects'; volume = $probeVolume
            scanned = 2; returned = 1; limit = 1; truncated = $true
            elements = @([pscustomobject]@{ element_id = 1; category = 'Walls' }); failed = @(); error = $null
        }
        if (Test-AuthoringProbeIsEmpty -Response $occupiedProbe -ExpectedVolume $probeVolume) {
            throw 'SelfTest: an occupied placement probe was accepted.'
        }
        $invalidEmptyProbe = [pscustomobject]@{
            unit = 'mm'; source = 'axis_aligned_volume'; match = 'intersects'; volume = $probeVolume
            scanned = 0; returned = 0; limit = 1; truncated = $true; elements = @(); failed = @(); error = $null
        }
        $invalidEmptyRejected = $false
        try { Test-AuthoringProbeIsEmpty -Response $invalidEmptyProbe -ExpectedVolume $probeVolume | Out-Null } catch { $invalidEmptyRejected = $true }
        if (-not $invalidEmptyRejected) { throw 'SelfTest: a truncated empty placement probe was not rejected.' }

        $selfTestCommands = @(New-AuthoringCommands -OffsetX 50000 -OffsetY -50000 -Level 'L1' -GridName 'G' -ViewName 'V')
        if ($selfTestCommands.Count -ne 7) { throw 'SelfTest: authoring command count changed.' }
        if ([double]$selfTestCommands[0].params.startX -ne 48500 -or [double]$selfTestCommands[0].params.endX -ne 49200 -or
            [double]$selfTestCommands[0].params.startY -ne -51000 -or [double]$selfTestCommands[0].params.endY -ne -45000) {
            throw 'SelfTest: authoring grid offset or diagonal changed.'
        }
        if ([double]$selfTestCommands[1].params.startX -ne 50000 -or [double]$selfTestCommands[1].params.startY -ne -50000 -or
            [double]$selfTestCommands[1].params.endX -ne 56000 -or [double]$selfTestCommands[1].params.endY -ne -50000) {
            throw 'SelfTest: authoring wall offset changed.'
        }
        if ([double]$selfTestCommands[5].params.points[2].x -ne 56000 -or [double]$selfTestCommands[5].params.points[2].y -ne -46000) {
            throw 'SelfTest: authoring floor offset changed.'
        }

        $resumeRoot = Join-Path $tempRoot 'resume-evidence'
        New-Item -ItemType Directory -Path $resumeRoot | Out-Null
        $resumeState = [pscustomobject]@{ runDirectory = $resumeRoot; smoke = $null }
        Assert-RunResumeHasNoAmbiguousAuthoring $resumeState
        $ambiguousDirectory = Join-Path $resumeRoot 'http-attempt-interrupted'
        New-Item -ItemType Directory -Path $ambiguousDirectory | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $ambiguousDirectory '10-rollback-batch.request.json') -Encoding UTF8
        $ambiguousRejected = $false
        try { Assert-RunResumeHasNoAmbiguousAuthoring $resumeState } catch { $ambiguousRejected = $true }
        if (-not $ambiguousRejected) { throw 'SelfTest: ambiguous authoring evidence did not block Run resume.' }

        $deployRoot = Join-Path $tempRoot 'early-deploy-failure'
        New-Item -ItemType Directory -Path $deployRoot -Force | Out-Null
        $targetPlugin = Join-Path $deployRoot 'RvtMcp'
        $targetManifest = Join-Path $deployRoot 'RvtMcp.R26.addin'
        New-Item -ItemType Directory -Path $targetPlugin -Force | Out-Null
        'original plugin' | Set-Content -LiteralPath (Join-Path $targetPlugin 'RvtMcp.Plugin.dll') -Encoding UTF8
        'original manifest' | Set-Content -LiteralPath $targetManifest -Encoding UTF8
        $beforePlugin = Get-TreeInventory $targetPlugin
        $beforeManifest = Get-FileSnapshot $targetManifest
        $payloadPluginRoot = Join-Path $deployRoot 'payload-plugin'
        New-Item -ItemType Directory -Path $payloadPluginRoot -Force | Out-Null
        'smoke plugin' | Set-Content -LiteralPath (Join-Path $payloadPluginRoot 'RvtMcp.Plugin.dll') -Encoding UTF8
        $payloadPlugin = Get-TreeInventory $payloadPluginRoot
        $payloadManifestPath = Join-Path $deployRoot 'payload-manifest.addin'
        'smoke manifest' | Set-Content -LiteralPath $payloadManifestPath -Encoding UTF8
        $payloadManifest = Get-FileSnapshot $payloadManifestPath
        $stagePlugin = Join-Path $deployRoot 'stage-plugin'
        Copy-DirectoryContents -Source $payloadPluginRoot -Destination $stagePlugin
        $stageManifest = Join-Path $deployRoot 'stage-manifest.addin.tmp'
        Copy-Item -LiteralPath $payloadManifestPath -Destination $stageManifest
        $failureDirectory = Join-Path $deployRoot 'failure-evidence'
        New-Item -ItemType Directory -Path $failureDirectory -Force | Out-Null
        $rollbackPaths = [pscustomobject]@{ pluginTarget = $targetPlugin; manifestTarget = $targetManifest }
        Invoke-DeployTargetRollback -Paths $rollbackPaths -BeforePlugin $beforePlugin -BeforeManifest $beforeManifest `
            -PayloadPlugin $payloadPlugin -PayloadManifest $payloadManifest `
            -OriginalPluginSibling (Join-Path $deployRoot 'unused-original-plugin') `
            -OriginalManifestSibling (Join-Path $deployRoot 'unused-original-manifest') `
            -StagePluginSibling $stagePlugin -StageManifestSibling $stageManifest `
            -FailureDirectory $failureDirectory -OriginalPluginMoved $false -PluginPayloadDeployed $false `
            -OriginalManifestMoved $false -ManifestPayloadDeployed $false
        Assert-InventoryMatches -Expected $beforePlugin -Actual (Get-TreeInventory $targetPlugin) -Label 'early-failure original plugin'
        $earlyManifest = Get-FileSnapshot $targetManifest
        if (-not ([string]$earlyManifest.sha256).Equals([string]$beforeManifest.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'SelfTest: early deploy failure changed the original manifest.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $failureDirectory 'failed-staging-plugin') -PathType Container) -or
            -not (Test-Path -LiteralPath (Join-Path $failureDirectory 'failed-staging-manifest.addin.tmp') -PathType Leaf)) {
            throw 'SelfTest: early deploy failure did not archive only its owned staging payload.'
        }

        $crashRoot = Join-Path $tempRoot 'interrupted-deploy'
        New-Item -ItemType Directory -Path $crashRoot -Force | Out-Null
        $crashTargetPlugin = Join-Path $crashRoot 'RvtMcp'
        $crashTargetManifest = Join-Path $crashRoot 'RvtMcp.R26.addin'
        $crashOriginalPlugin = Join-Path $crashRoot 'original-RvtMcp'
        $crashOriginalManifest = Join-Path $crashRoot 'original-RvtMcp.addin.disabled'
        $crashStagePlugin = Join-Path $crashRoot 'stage-RvtMcp'
        $crashStageManifest = Join-Path $crashRoot 'stage-RvtMcp.addin.tmp'
        New-Item -ItemType Directory -Path $crashTargetPlugin | Out-Null
        'before' | Set-Content -LiteralPath (Join-Path $crashTargetPlugin 'RvtMcp.Plugin.dll') -Encoding UTF8
        'before manifest' | Set-Content -LiteralPath $crashTargetManifest -Encoding UTF8
        $crashBeforePlugin = Get-TreeInventory $crashTargetPlugin
        $crashBeforeManifest = Get-FileSnapshot $crashTargetManifest
        New-Item -ItemType Directory -Path $crashStagePlugin | Out-Null
        'payload' | Set-Content -LiteralPath (Join-Path $crashStagePlugin 'RvtMcp.Plugin.dll') -Encoding UTF8
        'payload manifest' | Set-Content -LiteralPath $crashStageManifest -Encoding UTF8
        $crashPayloadPlugin = Get-TreeInventory $crashStagePlugin
        $crashPayloadManifest = Get-FileSnapshot $crashStageManifest
        Move-Item -LiteralPath $crashTargetPlugin -Destination $crashOriginalPlugin
        Move-Item -LiteralPath $crashStagePlugin -Destination $crashTargetPlugin
        Move-Item -LiteralPath $crashTargetManifest -Destination $crashOriginalManifest
        Move-Item -LiteralPath $crashStageManifest -Destination $crashTargetManifest
        $crashState = [pscustomobject]@{
            paths = [pscustomobject]@{
                pluginTarget = $crashTargetPlugin; manifestTarget = $crashTargetManifest
                originalPluginSibling = $crashOriginalPlugin; originalManifestSibling = $crashOriginalManifest
                stagePluginSibling = $crashStagePlugin; stageManifestSibling = $crashStageManifest
            }
            before = [pscustomobject]@{ plugin = $crashBeforePlugin; manifest = $crashBeforeManifest }
            source = [pscustomobject]@{ plugin = $crashPayloadPlugin; manifest = $crashPayloadManifest }
        }
        $crashPlan = Get-DeployRecoveryPlan $crashState
        if (-not $crashPlan.originalPluginMoved -or -not $crashPlan.pluginPayloadDeployed -or
            -not $crashPlan.originalManifestMoved -or -not $crashPlan.manifestPayloadDeployed) {
            throw 'SelfTest: interrupted deploy layout was not reconciled to all four completed moves.'
        }
        $crashEvidence = Join-Path $crashRoot 'recovery-evidence'
        New-Item -ItemType Directory -Path $crashEvidence | Out-Null
        Invoke-DeployTargetRollback -Paths $crashState.paths -BeforePlugin $crashBeforePlugin -BeforeManifest $crashBeforeManifest `
            -PayloadPlugin $crashPayloadPlugin -PayloadManifest $crashPayloadManifest `
            -OriginalPluginSibling $crashOriginalPlugin -OriginalManifestSibling $crashOriginalManifest `
            -StagePluginSibling $crashStagePlugin -StageManifestSibling $crashStageManifest `
            -FailureDirectory $crashEvidence -OriginalPluginMoved $crashPlan.originalPluginMoved `
            -PluginPayloadDeployed $crashPlan.pluginPayloadDeployed -OriginalManifestMoved $crashPlan.originalManifestMoved `
            -ManifestPayloadDeployed $crashPlan.manifestPayloadDeployed
        Assert-InventoryMatches -Expected $crashBeforePlugin -Actual (Get-TreeInventory $crashTargetPlugin) -Label 'interrupted deploy recovered plugin'
        if (-not (Test-FileSnapshotEquivalent $crashBeforeManifest (Get-FileSnapshot $crashTargetManifest))) {
            throw 'SelfTest: interrupted deploy manifest did not return to the pre-deploy hash.'
        }

        $completeStats = [pscustomobject]@{ projectName = 'Smoke'; documentPath = 'C:\Smoke\Smoke.rvt'; elementsCounted = 42; truncated = $false; cap = 100000 }
        Assert-CompleteModelStatistics -Statistics $completeStats -Label 'self-test complete statistics'
        $missingDocumentPathRejected = $false
        try { Assert-CompleteModelStatistics -Statistics ([pscustomobject]@{ projectName = 'Smoke'; elementsCounted = 42; truncated = $false; cap = 100000 }) -Label 'self-test missing document path' } catch { $missingDocumentPathRejected = $true }
        if (-not $missingDocumentPathRejected) { throw 'SelfTest: statistics without documentPath were not rejected.' }
        $wrongDocumentPathRejected = $false
        try { Assert-ExactPath -Actual (Join-Path $tempRoot 'source.rvt') -Expected (Join-Path $tempRoot 'copy.rvt') -Label 'self-test active document path' } catch { $wrongDocumentPathRejected = $true }
        if (-not $wrongDocumentPathRejected) { throw 'SelfTest: a different canonical document path was not rejected.' }
        $truncatedRejected = $false
        try { Assert-CompleteModelStatistics -Statistics ([pscustomobject]@{ projectName = 'Smoke'; documentPath = 'C:\Smoke\Smoke.rvt'; elementsCounted = 100000; truncated = $true; cap = 100000 }) -Label 'self-test truncated statistics' } catch { $truncatedRejected = $true }
        if (-not $truncatedRejected) { throw 'SelfTest: truncated statistics were not rejected.' }

        Write-Host 'Smoke harness self-test passed: paths, hashes, MCP parsing, timestamp normalization, resume guards, deploy rollback/recovery, and statistics completeness.'
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

switch ($Phase) {
    'Preflight' { Invoke-Preflight }
    'Build' { Invoke-Build }
    'Deploy' { Invoke-Deploy }
    'Run' { Invoke-Run }
    'VerifyUndo' { Invoke-VerifyUndo }
    'Collect' { Invoke-Collect }
    'Restore' { Invoke-Restore }
    'SelfTest' { Invoke-SelfTest }
}
