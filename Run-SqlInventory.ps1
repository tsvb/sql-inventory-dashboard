<#
.SYNOPSIS
    Enterprise SQL-Server & host-OS inventory – v2.3 (Refactored v2)
.DESCRIPTION
    Deep-dive estate inventory with CSV outputs per data domain.
    This refactored version includes a defined server processing scriptblock,
    enhanced validation, dry-run capability, and improved summary.
    v2.3 features include:
     • Central parameter splatting
     • Enhanced logging with severity
     • Exponential retry back-off
     • Flexible command truncation
     • Improved timeout handling
     • Clear parallel execution messaging
     • Dry-run mode
     • Improved completion summary
.NOTES
    DEPENDENCY: This script uses Invoke-Sqlcmd for SQL Server queries.
    The 'SqlServer' PowerShell module is typically required on the machine
    running this script.

    CUSTOMIZATION: The main data collection logic is within the $serverScript
    scriptblock. Add or modify collections there as needed.
.PARAMETER ExportBackoffMS
    Milliseconds base for Export-InventoryData exponential back-off (default 200)
.PARAMETER DryRun
    If specified, the script will log actions it would take but will not write any CSV files.
    Data collection commands (Get-CimInstance, Invoke-Sqlcmd) will still be attempted to test connectivity.
#>

#region --- parameters --------------------------------------------------------
[CmdletBinding(SupportsShouldProcess=$true)] # Added SupportsShouldProcess for -WhatIf (though DryRun is custom)
param(
    [Parameter(Mandatory)][string[]]$ServerNames,
    [Parameter(Mandatory)]
    [ValidateScript({
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
        if (-not (Get-Item $_).PSIsContainer) { throw "OutputPath is not a directory" }
        try { $tmp = Join-Path $_ 'w.tmp'; 'x' | Set-Content $tmp; Remove-Item $tmp -Force }
        catch { throw "No write permission to $_" }; $true
    })][string]$OutputPath,
    [string]$LogPath,
    [ValidateSet(1,2,4,8,16,32)][int]$ThrottleLimit = 1,
    [string]$SqlUsername,
    [string]$SqlPassword,
    [string]$OsUsername,
    [string]$OsPassword,
    [System.Management.Automation.PSCredential]$DirectSqlCredentialInput, # Renamed from SqlCredential
    [System.Management.Automation.PSCredential]$DirectOsCredentialInput, # Renamed from Credential
    [int]$CommandTruncateLength = 120,
    [int]$QueryTimeout          = 120,
    [int]$TopTablesCount        = 20,
    [int]$BackupHistoryDays     = 30,
    [int]$ExportSliceSize       = 1000,
    [int]$MaxServerSeconds      = 3600,
    [int]$ExportBackoffMS       = 200,
    [ValidateSet('HostOS','SqlInstanceInfo','SqlInstanceConfig','SqlNetworkConfig',
                 'SqlLogins','SqlServerRoles','SqlServerPermissions','SqlAudits',
                 'Databases','BackupHistory','MaintenancePlans','LinkedServers',
                 'ActiveConnections','AgentJobs')]
    [string[]]$SkipCollections = @(),
    [switch]$DryRun
)
#endregion

#region --- Initial Checks & Setup ---------------------------------------------
# Check for Invoke-Sqlcmd
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    throw "CRITICAL: Invoke-Sqlcmd command not found. Please ensure the 'SqlServer' PowerShell module is installed and imported. Script cannot continue."
}

# Determine effective credentials
$EffectiveSqlCredential = $null
if ($SqlUsername -and $SqlPassword) {
    $EffectiveSqlCredential = New-Object System.Management.Automation.PSCredential($SqlUsername, (ConvertTo-SecureString $SqlPassword -AsPlainText -Force))
    Write-Log "Using SQL credentials provided via SqlUsername/SqlPassword parameters."
} elseif ($DirectSqlCredentialInput) {
    $EffectiveSqlCredential = $DirectSqlCredentialInput
    Write-Log "Using SQL credentials provided via DirectSqlCredentialInput parameter."
}

$EffectiveOsCredential = $null
if ($OsUsername -and $OsPassword) {
    $EffectiveOsCredential = New-Object System.Management.Automation.PSCredential($OsUsername, (ConvertTo-SecureString $OsPassword -AsPlainText -Force))
    Write-Log "Using OS credentials provided via OsUsername/OsPassword parameters."
} elseif ($DirectOsCredentialInput) {
    $EffectiveOsCredential = $DirectOsCredentialInput
    Write-Log "Using OS credentials provided via DirectOsCredentialInput parameter."
}

# Credential Warnings
if (-not $EffectiveOsCredential) {
    Write-Warning "No effective OS credential available. Remote WMI/CIM operations might fail if the current user context lacks permissions on target servers."
}
if (-not $EffectiveSqlCredential) {
    Write-Warning "No effective SQL credential available. SQL Server connections will attempt to use the current user's integrated security. This might fail if the user context lacks SQL permissions."
}
#endregion

#region --- enhanced logging --------------------------------------------------
if(-not $LogPath){$LogPath = Join-Path $OutputPath 'Logs'}
$null = New-Item -ItemType Directory -Path $LogPath -Force
$runStamp = Get-Date -Format 'yyMMdd_HHmmss'
$Global:LogFile = Join-Path $LogPath "InventoryLog_$runStamp.log" # Made explicitly Global for easier access if needed, though passing is preferred

function Write-Log{
    param([string]$Message,[string]$Severity='INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Severity] $Message" | Tee-Object -FilePath $Global:LogFile -Append
}
Start-Transcript -Path (Join-Path $LogPath "InventoryTranscript_$runStamp.log") -Append
Write-Log "Script execution started. OutputPath: $OutputPath, LogPath: $LogPath"
if ($DryRun) { Write-Log "DRY RUN MODE ENABLED: No CSV files will be written." 'WARN' }
#endregion

#region --- helper module (for CSV export) ------------------------------------
$helperModule = @"
function Export-InventoryData {
    param(
        [object[]]$Data,
        [string]$Prefix,
        [string]$Dir,
        [string]$Stamp, # ServerName
        [int]$Slice,
        [int]$Backoff,
        [System.Collections.Concurrent.ConcurrentBag[string]]$Bag,
        [switch]$IsDryRun, # Added DryRun switch
        [string]`$PassedLogFile # For logging from within the module if ever needed directly
    )

    # Helper for logging within the module, if Write-Log isn't directly available or for specific module logs
    # For now, this is not used, but demonstrates how one might log from here.
    # function Write-ModuleLog { param([string]$Msg, [string]$Sev='INFO') { "$((Get-Date).ToString('u')) [$Sev] (Export-InventoryData) $Msg" | Tee-Object -FilePath `$PassedLogFile -Append } }

    if(-not $Data -or $Data.Count -eq 0){return}
    $file = Join-Path $Dir ("${Prefix}_${Stamp}.csv")

    if ($IsDryRun) {
        $Bag.Add("DRYRUN: Would export ${Prefix} data for server ${Stamp} to ${file} ($($Data.Count) records).")
        # Write-ModuleLog "DRYRUN: Would export to $file for server $Stamp" # Example of module specific log
        return
    }

    for($i=0;$i -lt $Data.Count;$i+=$Slice){
        $chunk=$Data[$i..([math]::Min($i+$Slice-1,$Data.Count-1))]
        for($t=1;$t -le 3;$t++){
            try{
                $p=@{Path=$file;NoTypeInformation=$true; Encoding = ([System.Text.UTF8Encoding]::new($false))} # Corrected Encoding
                if((Test-Path $file) -and (Get-Item $file).Length -gt 0){$p.Append=$true}
                $chunk|Export-Csv @p;break
            }catch{
                if($t -eq 3){$Bag.Add("EXPORT-FAIL $Prefix -> $file (Server: $Stamp) : $($_.Exception.Message)")}
                else{
                    $delay = $Backoff*[math]::Pow(2,$t-1)
                    Start-Sleep -Milliseconds $delay
                }
            }
        }
    }
    if(-not (Test-Path $file) -and -not $IsDryRun){$Bag.Add("VERIFY-FAIL (File not created) $file (Server: $Stamp)")}
}
"@
Import-Module (New-Module -Name SqlInvHelpers -ScriptBlock ([scriptblock]::Create($helperModule))) -Force
Write-Log "Helper module 'SqlInvHelpers' loaded."
#endregion

#region --- Initialize Error and Success Bags ---
$ErrBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
$SuccessBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new() # For tracking successful servers
Write-Log "Error and Success bags initialized."
#endregion

#region --- Server Processing ScriptBlock ($serverScript) ---------------------
$serverScript = {
    param(
        [string]$Srv, 
        [string]$MainOutputPath,
        [System.Management.Automation.PSCredential]$PassedSqlCredential, # This will be $EffectiveSqlCredential from parent
        [System.Management.Automation.PSCredential]$PassedOsCredential,   # This will be $EffectiveOsCredential from parent
        [int]$PassedCommandTruncateLength,
        [int]$PassedQueryTimeout,
        # [int]$PassedTopTablesCount, # Not used in current example collections
        # [int]$PassedBackupHistoryDays, # Not used in current example collections
        [int]$PassedExportSliceSize,
        [int]$PassedExportBackoffMS,
        [string[]]$PassedSkipCollections,
        [System.Collections.Concurrent.ConcurrentBag[string]]$PassedErrBag,
        [System.Collections.Concurrent.ConcurrentBag[string]]$PassedSuccessBag, # Added
        [int]$PassedMaxServerSeconds,
        [string]$ScriptLogFile, # Passed LogFile path
        [switch]$ScriptDryRun # Passed DryRun switch
    )
    
    # Re-define Write-Log or ensure it's accessible if issues arise with global scope in threads.
    # For simple cases, global function might be found. For robustness, could pass as scriptblock or redefine.
    # Assuming global Write-Log is accessible here for now. If not, it would need to be passed/redefined.
    # $Global:LogFile is used by Write-Log, so it should pick up the correct file.

    $serverSpecificLogPrefix = "Server '$Srv':" # To prepend to log messages for clarity

    # Start stopwatch for per-server timeout
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "$serverSpecificLogPrefix Processing started (Max time: $PassedMaxServerSeconds seconds, DryRun: $ScriptDryRun)." -Severity 'INFO'
    $serverHadError = $false # Flag to track if any error occurred for this server

    # Helper function for command truncation
    function Truncate-Command ($commandString) {
        if ($PassedCommandTruncateLength -gt 0 -and $commandString -and $commandString.Length -gt $PassedCommandTruncateLength) {
            return $commandString.Substring(0, $PassedCommandTruncateLength) + '…'
        }
        return $commandString
    }

    # --- HostOS Collection ---
    if ('HostOS' -notin $PassedSkipCollections) {
        Write-Log "$serverSpecificLogPrefix Collecting HostOS info."
        try {
            if ($stopwatch.Elapsed.TotalSeconds -gt $PassedMaxServerSeconds) {
                Write-Log "$serverSpecificLogPrefix TIMEOUT before HostOS collection. Elapsed: $($stopwatch.Elapsed.TotalSeconds)s" 'WARN'; $serverHadError = $true
                $PassedErrBag.Add("$Srv:TIMEOUT - HostOS collection skipped due to overall server timeout.")
                return 
            }
            $cimParams = @{ ClassName = 'CIM_OperatingSystem'; ComputerName = $Srv; ErrorAction = 'Stop' }
            if ($PassedOsCredential) { $cimParams.Credential = $PassedOsCredential }
            
            $hostOsData = Get-CimInstance @cimParams | Select-Object PSComputerName, Caption, Version, OSArchitecture, CSName, NumberOfUsers, TotalVisibleMemorySize, FreePhysicalMemory
            
            $cmdToLog = "Get-CimInstance -ClassName CIM_OperatingSystem -ComputerName $Srv"
            Write-Log "$serverSpecificLogPrefix Executed: $(Truncate-Command $cmdToLog)"
            Export-InventoryData -Data $hostOsData -Prefix "HostOS" -Dir $MainOutputPath -Stamp $Srv -Slice $PassedExportSliceSize -Backoff $PassedExportBackoffMS -Bag $PassedErrBag -IsDryRun:$ScriptDryRun -PassedLogFile $ScriptLogFile
        } catch {
            $errMsg = "$Srv:ERROR collecting HostOS: $($_.Exception.Message)"
            Write-Log "$serverSpecificLogPrefix $errMsg" 'ERROR'; $serverHadError = $true
            $PassedErrBag.Add($errMsg)
        }
    } else { Write-Log "$serverSpecificLogPrefix Skipping HostOS collection as per SkipCollections." }

    # --- SqlInstanceInfo Collection ---
    if ('SqlInstanceInfo' -notin $PassedSkipCollections -and !$serverHadError) { # Added !$serverHadError to potentially skip if prior critical step failed
        Write-Log "$serverSpecificLogPrefix Collecting SqlInstanceInfo."
        try {
            if ($stopwatch.Elapsed.TotalSeconds -gt $PassedMaxServerSeconds) {
                Write-Log "$serverSpecificLogPrefix TIMEOUT before SqlInstanceInfo. Elapsed: $($stopwatch.Elapsed.TotalSeconds)s" 'WARN'; $serverHadError = $true
                $PassedErrBag.Add("$Srv:TIMEOUT - SqlInstanceInfo collection skipped.")
                return 
            }
            $sqlQuery = "SELECT SERVERPROPERTY('ServerName') AS ServerName, SERVERPROPERTY('InstanceName') AS InstanceName, SERVERPROPERTY('ProductVersion') AS ProductVersion, SERVERPROPERTY('ProductLevel') AS ProductLevel, SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('EngineEdition') AS EngineEdition, @@VERSION AS FullVersionString;"
            Write-Log "$serverSpecificLogPrefix Executing SQL for SqlInstanceInfo: $(Truncate-Command $sqlQuery)"
            
            $sqlCmdParams = @{ ServerInstance = $Srv; Query = $sqlQuery; QueryTimeout = $PassedQueryTimeout; ErrorAction = 'Stop' }
            if ($PassedSqlCredential) { $sqlCmdParams.Credential = $PassedSqlCredential }

            $sqlInstanceData = Invoke-Sqlcmd @sqlCmdParams
            Export-InventoryData -Data $sqlInstanceData -Prefix "SqlInstanceInfo" -Dir $MainOutputPath -Stamp $Srv -Slice $PassedExportSliceSize -Backoff $PassedExportBackoffMS -Bag $PassedErrBag -IsDryRun:$ScriptDryRun -PassedLogFile $ScriptLogFile
        } catch {
            $errMsg = "$Srv:ERROR collecting SqlInstanceInfo: $($_.Exception.Message)"
            Write-Log "$serverSpecificLogPrefix $errMsg" 'ERROR'; $serverHadError = $true
            $PassedErrBag.Add($errMsg)
        }
    } else { if ('SqlInstanceInfo' -in $PassedSkipCollections) {Write-Log "$serverSpecificLogPrefix Skipping SqlInstanceInfo collection as per SkipCollections."} }

    # --- Databases Collection ---
    if ('Databases' -notin $PassedSkipCollections -and !$serverHadError) {
        Write-Log "$serverSpecificLogPrefix Collecting Databases info."
        try {
            if ($stopwatch.Elapsed.TotalSeconds -gt $PassedMaxServerSeconds) {
                Write-Log "$serverSpecificLogPrefix TIMEOUT before Databases. Elapsed: $($stopwatch.Elapsed.TotalSeconds)s" 'WARN'; $serverHadError = $true
                $PassedErrBag.Add("$Srv:TIMEOUT - Databases collection skipped.")
                return
            }
            $sqlQuery = "SELECT name, database_id, create_date, compatibility_level, collation_name, user_access_desc, state_desc, recovery_model_desc, page_verify_option_desc FROM sys.databases WHERE database_id > 4 ORDER BY name;"
            Write-Log "$serverSpecificLogPrefix Executing SQL for Databases: $(Truncate-Command $sqlQuery)"

            $sqlCmdParams = @{ ServerInstance = $Srv; Query = $sqlQuery; QueryTimeout = $PassedQueryTimeout; ErrorAction = 'Stop' }
            if ($PassedSqlCredential) { $sqlCmdParams.Credential = $PassedSqlCredential }

            $databasesData = Invoke-Sqlcmd @sqlCmdParams
            Export-InventoryData -Data $databasesData -Prefix "Databases" -Dir $MainOutputPath -Stamp $Srv -Slice $PassedExportSliceSize -Backoff $PassedExportBackoffMS -Bag $PassedErrBag -IsDryRun:$ScriptDryRun -PassedLogFile $ScriptLogFile
        } catch {
            $errMsg = "$Srv:ERROR collecting Databases: $($_.Exception.Message)"
            Write-Log "$serverSpecificLogPrefix $errMsg" 'ERROR'; $serverHadError = $true
            $PassedErrBag.Add($errMsg)
        }
    } else { if ('Databases' -in $PassedSkipCollections) {Write-Log "$serverSpecificLogPrefix Skipping Databases collection as per SkipCollections."} }

    # --- AgentJobs Collection ---
    if ('AgentJobs' -notin $PassedSkipCollections -and !$serverHadError) {
        Write-Log "$serverSpecificLogPrefix Collecting AgentJobs info."
        try {
            if ($stopwatch.Elapsed.TotalSeconds -gt $PassedMaxServerSeconds) {
                Write-Log "$serverSpecificLogPrefix TIMEOUT before AgentJobs. Elapsed: $($stopwatch.Elapsed.TotalSeconds)s" 'WARN'; $serverHadError = $true
                $PassedErrBag.Add("$Srv:TIMEOUT - AgentJobs collection skipped.")
                return
            }
            $sqlQuery = "USE msdb; SELECT j.name AS JobName, j.enabled AS IsEnabled, j.description AS JobDescription, c.name AS CategoryName, SUSER_SNAME(j.owner_sid) AS JobOwner, j.date_created AS DateCreated, j.date_modified AS DateModified FROM dbo.sysjobs j INNER JOIN dbo.syscategories c ON j.category_id = c.category_id ORDER BY j.name;"
            Write-Log "$serverSpecificLogPrefix Executing SQL for AgentJobs: $(Truncate-Command $sqlQuery)"

            $sqlCmdParams = @{ ServerInstance = $Srv; Query = $sqlQuery; QueryTimeout = $PassedQueryTimeout; ErrorAction = 'Stop' }
            if ($PassedSqlCredential) { $sqlCmdParams.Credential = $PassedSqlCredential }
            
            $agentJobsData = Invoke-Sqlcmd @sqlCmdParams
            Export-InventoryData -Data $agentJobsData -Prefix "AgentJobs" -Dir $MainOutputPath -Stamp $Srv -Slice $PassedExportSliceSize -Backoff $PassedExportBackoffMS -Bag $PassedErrBag -IsDryRun:$ScriptDryRun -PassedLogFile $ScriptLogFile
        } catch {
            $errMsg = "$Srv:ERROR collecting AgentJobs: $($_.Exception.Message)"
            Write-Log "$serverSpecificLogPrefix $errMsg" 'ERROR'; $serverHadError = $true
            $PassedErrBag.Add($errMsg)
        }
    } else { if ('AgentJobs' -in $PassedSkipCollections) {Write-Log "$serverSpecificLogPrefix Skipping AgentJobs collection as per SkipCollections."} }

    # --- Placeholder for other collections ---
    # Remember to check $stopwatch.Elapsed.TotalSeconds and !$serverHadError before each.
    # Consider if a failure in one collection should prevent subsequent ones for that server.

    $stopwatch.Stop()
    if (-not $serverHadError) {
        $PassedSuccessBag.Add($Srv) # Add to success bag if no errors for this server
        Write-Log "$serverSpecificLogPrefix Processing finished successfully. Total time: $($stopwatch.Elapsed.ToString('g'))" -Severity 'INFO'
    } else {
        Write-Log "$serverSpecificLogPrefix Processing finished with errors. Total time: $($stopwatch.Elapsed.ToString('g'))" -Severity 'WARN'
    }
    # Note: More advanced timeout handling (e.g., graceful kill) is a potential future enhancement.
}
Write-Log "Server processing scriptblock defined."
#endregion

#region --- execution (parallel or serial) ------------------------------------
$executionStartTime = Get-Date
Write-Log "Starting server processing at $executionStartTime"

if($ThrottleLimit -gt 1 -and $PSVersionTable.PSVersion.Major -ge 7){
    Write-Log "Running in PARALLEL mode with throttle limit: $ThrottleLimit for $($ServerNames.Count) servers." 'INFO'
    $ServerNames | ForEach-Object -Parallel $serverScript -ThrottleLimit $ThrottleLimit 
        -ArgumentList $_, $OutputPath, $EffectiveSqlCredential, $EffectiveOsCredential, $CommandTruncateLength,
                      $QueryTimeout, $ExportSliceSize, $ExportBackoffMS, $SkipCollections, 
                      $ErrBag, $SuccessBag, $MaxServerSeconds, $Global:LogFile, $DryRun # Removed TopTables, BackupHistoryDays as not used in example
} else {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Log "PowerShell version less than 7.0 detected. Parallel execution unavailable." 'WARN'
    }
    Write-Log "Running in SERIAL mode for $($ServerNames.Count) servers." 'WARN'
    foreach($s in $ServerNames){
        try {
            # Note: $TopTablesCount and $BackupHistoryDays are not used in the current $serverScript examples.
            # If you add collections that use them, ensure they are passed here too.
            & $serverScript $s $OutputPath $EffectiveSqlCredential $EffectiveOsCredential $CommandTruncateLength
                           $QueryTimeout $ExportSliceSize $ExportBackoffMS $SkipCollections 
                           $ErrBag $SuccessBag $MaxServerSeconds $Global:LogFile $DryRun
        } catch {
            $errMsg = "FATAL SCRIPTBLOCK ERROR processing server $s in serial mode: $($_.Exception.Message). n$($_.ScriptStackTrace)"
            Write-Log $errMsg 'ERROR'
            $ErrBag.Add("$s:FATAL_SCRIPTBLOCK_ERROR - $errMsg") # Ensure server name is in ErrBag
        }
    }
}
$executionEndTime = Get-Date
Write-Log "Server processing finished at $executionEndTime. Total execution time: $($executionEndTime - $executionStartTime)."
#endregion

#region --- summary and exit --------------------------------------------------
Write-Log "---------------- SCRIPT EXECUTION SUMMARY ----------------"
$totalServers = $ServerNames.Count
$successfulServersCount = $SuccessBag.Count
$failedServersCount = $totalServers - $successfulServersCount 

Write-Log "Total servers targeted: $totalServers"
Write-Log "Servers processed successfully (no errors reported by script logic): $successfulServersCount"
Write-Log "Servers with errors or not fully processed: $failedServersCount"

if ($DryRun) {
    Write-Log "DRY RUN MODE WAS ENABLED. No CSV files were written. Review logs for intended actions." 'WARN'
}

Write-Log "Total errors/warnings accumulated in ErrBag: $($ErrBag.Count)"
if ($ErrBag.Count -gt 0) {
    Write-Log "Details of errors/warnings from ErrBag:"
    $ErrBag | ForEach-Object { Write-Log $_ 'ERROR' } 
}

Write-Log "Output directory: $OutputPath"
Write-Log "Log file: $Global:LogFile"
Write-Log "Transcript file: $(Join-Path $LogPath "InventoryTranscript_$runStamp.log")"
Write-Log "Script execution finished."
Stop-Transcript | Out-Null

if($ErrBag.Count -gt 0 -or $failedServersCount -gt 0){ # Consider failed servers as an error condition too
    Write-Warning "Inventory script completed with issues. Successful Servers: $successfulServersCount/$totalServers. Errors in ErrBag: $($ErrBag.Count). Check logs for details."
    exit 1
} else {
    Write-Host "Inventory script completed successfully for all $totalServers servers." -ForegroundColor Green
    exit 0
}
#endregion
