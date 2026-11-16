param(
    [Parameter(Mandatory = $true)][string]$Msi,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Scheme = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$msiPath = (Resolve-Path -LiteralPath $Msi).Path
$installRoot = Join-Path $env:RUNNER_TEMP 'rivet-taskboard-installed-icon'
$logInstall = Join-Path $OutputDirectory 'msi-install.log'
$logUninstall = Join-Path $OutputDirectory 'msi-uninstall.log'

function Invoke-Msi {
    param(
        [ValidateSet('i','x')][string]$Action,
        [string]$LogFile
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new('msiexec.exe')
    $start.UseShellExecute = $false
    foreach ($arg in @("/$Action", $msiPath, '/qn', '/norestart', '/l*v', $LogFile)) {
        [void]$start.ArgumentList.Add($arg)
    }
    if ($Action -eq 'i') {
        [void]$start.ArgumentList.Add("INSTALLFOLDER=$installRoot")
    }
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            throw "msiexec /$Action exceeded 120 seconds"
        }
        if ($process.ExitCode -ne 0) {
            throw "msiexec /$Action failed with exit code $($process.ExitCode); see $LogFile"
        }
    } finally {
        $process.Dispose()
    }
}

$installed = $false
$schemeKey = if ([string]::IsNullOrEmpty($Scheme)) { '' } else {
    "Registry::HKEY_LOCAL_MACHINE\Software\Classes\$Scheme"
}
try {
    Invoke-Msi -Action i -LogFile $logInstall
    $installed = $true
    $exe = Join-Path $installRoot 'RivetHost.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "MSI did not install RivetHost.exe under requested INSTALLFOLDER: $installRoot"
    }
    $installedEvidence = Join-Path $OutputDirectory 'installed-host'
    if ([string]::IsNullOrEmpty($Scheme)) {
        & (Join-Path $PSScriptRoot 'windows-uia.ps1') -Executable $exe -OutputDirectory $installedEvidence
    } else {
        # Verify the *actual MSI registration* under the installing user's
        # Classes hive before invoking a URI through ShellExecute.
        $commandKey = "$schemeKey\shell\open\command"
        if (-not (Test-Path -LiteralPath $commandKey)) {
            throw "MSI installed no machine-scoped URL handler for $Scheme"
        }
        $registeredCommand = (Get-Item -LiteralPath $commandKey).GetValue('')
        if (-not $registeredCommand -or
            $registeredCommand.IndexOf($exe, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "MSI registered the wrong URL handler for $Scheme : $registeredCommand"
        }
        $uri = "${Scheme}://activation-test/msi-shell"
        & (Join-Path $PSScriptRoot 'windows-uia.ps1') -Executable $exe -OutputDirectory $installedEvidence -ShellUri $uri
    }
    $activationTracePath = Join-Path $installedEvidence 'second-instance-trace.json'
    if (-not (Test-Path -LiteralPath $activationTracePath -PathType Leaf)) {
        throw 'Installed MSI did not produce second-instance activation evidence'
    }
    $activationTrace = Get-Content -LiteralPath $activationTracePath -Raw | ConvertFrom-Json
    if (-not $activationTrace.secondaryExited -or
        -not $activationTrace.primaryStillRunning -or
        -not $activationTrace.exactExpectedActivationArrived -or
        [int]$activationTrace.nativeDeliveryCount -ne 1 -or
        ([bool]$activationTrace.viaRegisteredShellUri -ne (-not [string]::IsNullOrEmpty($Scheme)))) {
        throw 'Installed MSI failed exact-once two-process native activation acceptance'
    }
    [ordered]@{
        artifact = [System.IO.Path]::GetFileName($msiPath)
        installKind = 'msi'
        installedExe = $exe
        installedSecondInstanceActivation = $true
        nativeDeliveryCount = [int]$activationTrace.nativeDeliveryCount
        # This proves the installed executable's command-line redirection.
        # Actual ShellExecute of a registered URL/file association is separate.
        registeredShellAssociationAcceptance = if ([string]::IsNullOrEmpty($Scheme)) { 'unrun' } else { 'passed' }
        registeredScheme = $Scheme
        assertions = @(
            'MSI silently installed its exact packaged host',
            'installed host redirected second process to live primary exactly once',
            'installed host exposed two titled WinUI windows',
            'both windows resolved the executable icon resource',
            'installed process completed the native UI and orderly exit scenario'
        )
    } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'msi-icon-evidence.json') -Encoding utf8
} finally {
    if ($installed) {
        Invoke-Msi -Action x -LogFile $logUninstall
        if ($schemeKey -and (Test-Path -LiteralPath $schemeKey)) {
            throw "MSI uninstall left protocol handler registration for $Scheme"
        }
        if (Test-Path -LiteralPath $installRoot) {
            $binaries = @(Get-ChildItem -LiteralPath $installRoot -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue)
            if ($binaries.Count -gt 0) { throw "MSI uninstall left application executables under $installRoot" }
        }
    }
}
