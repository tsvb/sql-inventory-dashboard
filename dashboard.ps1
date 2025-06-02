@(New-UDDashboard -Title "SQL Inventory Dashboard" -Content {
    New-UDForm -Title "Run SQL Inventory Scan" -Content {
        New-UDTextbox -Id 'serverNames' -Label 'Server Names (comma separated)' -Multiline
        New-UDTextbox -Id 'outputPath' -Label 'Output Path' -Value "/app/output"
        New-UDTextbox -Id 'logPath' -Label 'Log Path (optional)' # User can specify, or it defaults to /app/logs
        New-UDTextbox -Id 'sqlUsername' -Label 'SQL Username'
        New-UDTextbox -Id 'sqlPassword' -Label 'SQL Password' -Type 'password'
        New-UDTextbox -Id 'osUsername' -Label 'OS Username'
        New-UDTextbox -Id 'osPassword' -Label 'OS Password' -Type 'password'
        New-UDDropdown -Id 'throttleLimit' -Label 'Throttle Limit' -Options @(1,2,4,8,16,32)
        New-UDCheckbox -Id 'dryRun' -Label 'Dry Run (no file writes)'
        New-UDCheckboxGroup -Id 'skipCollections' -Label 'Skip Collections' -Options @(
            'HostOS','SqlInstanceInfo','SqlInstanceConfig','SqlNetworkConfig','SqlLogins',
            'SqlServerRoles','SqlServerPermissions','SqlAudits','Databases','BackupHistory',
            'MaintenancePlans','LinkedServers','ActiveConnections','AgentJobs')
    } -OnSubmit {
        $serverNamesRaw = $EventData.serverNames
        $serverNames = $serverNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

        $outputPath = $EventData.outputPath # This will be /app/output if user doesn't change it
        $logPath = if ($EventData.logPath) { $EventData.logPath } else { "/app/logs" } # Default to /app/logs
        $throttleLimit = [int]$EventData.throttleLimit
        $dryRun = [bool]$EventData.dryRun
        $skipCollections = $EventData.skipCollections

        # $sqlCred = New-Object System.Management.Automation.PSCredential($EventData.sqlUsername,(ConvertTo-SecureString $EventData.sqlPassword -AsPlainText -Force)) # REMOVED
        # $osCred = New-Object System.Management.Automation.PSCredential($EventData.osUsername,(ConvertTo-SecureString $EventData.osPassword -AsPlainText -Force)) # REMOVED

        $scriptParams = @{
            ServerNames = $serverNames
            OutputPath = $outputPath
            LogPath = $logPath
            ThrottleLimit = $throttleLimit
            DryRun = $dryRun
            # SqlCredential = $sqlCred # REMOVED
            # Credential = $osCred    # REMOVED
        }
        if ($EventData.sqlUsername -and $EventData.sqlPassword) {
            $scriptParams.SqlUsername = $EventData.sqlUsername
            $scriptParams.SqlPassword = $EventData.sqlPassword
        }
        if ($EventData.osUsername -and $EventData.osPassword) {
            $scriptParams.OsUsername = $EventData.osUsername
            $scriptParams.OsPassword = $EventData.osPassword
        }
        if ($skipCollections) { $scriptParams.SkipCollections = $skipCollections }

        $paramStr = $scriptParams.GetEnumerator() | ForEach-Object {
            if ($_.Value -is [System.Collections.IEnumerable] -and -not ($_.Value -is [string])) {
                "-{0} \"{1}\"" -f $_.Key, ($_.Value -join ',')
            } elseif ($_.Value -is [switch] -and $_.Value.IsPresent) {
                "-{0}" -f $_.Key
            # REMOVED elseif block for PSCredential
            } else {
                "-{0} \"{1}\"" -f $_.Key, $_.Value
            }
        } | Out-String

        $inventoryScriptPath = "/app/scripts/Run-SqlInventory.ps1"
        $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$inventoryScriptPath`" $paramStr"

        $errorMessages = ""
        $outputMessages = ""
        Invoke-Expression $cmd *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $errorMessages += $_.ToString() + "`n"
            } else {
                $outputMessages += $_.ToString() + "`n"
            }
        }

        if ($LASTEXITCODE -ne 0) {
            $toastMessage = "Inventory script failed (Exit Code: $LASTEXITCODE)."
            if ($errorMessages) {
                # Take first 5 non-empty lines of error messages, join with semicolon for toast
                $errorSummary = ($errorMessages -split "`n" | Where-Object {$_ -match "\S"} | Select-Object -First 5) -join '; '
                $toastMessage += " Errors: " + $errorSummary
            } elseif ($outputMessages) {
                # Take first 2 non-empty lines of output messages, join with semicolon for toast
                $outputSummary = ($outputMessages -split "`n" | Where-Object {$_ -match "\S"} | Select-Object -First 2) -join '; '
                $toastMessage += " Output: " + $outputSummary
            }
            Show-UDToast -Message $toastMessage -Severity Error -Duration 15000
        } else {
            Show-UDToast -Message "Inventory script executed successfully. Showing output..." -Duration 5000
        }

        $csvFiles = Get-ChildItem -Path $outputPath -Filter *.csv -Recurse | Sort-Object LastWriteTime -Descending
        foreach ($csv in $csvFiles) {
            New-UDCollapsible -Items {
                New-UDCollapsibleItem -Title $csv.Name -Content {
                    $data = Import-Csv $csv.FullName
                    New-UDTable -Data $data -ShowPagination -PageSize 10
                }
            }
        }

        New-UDMonitor -Title "Real-time Log" -RefreshInterval 5 -Content {
            # Determine the actual log path. $logPath comes from the form.
            # If $logPath is empty, it defaults inside Run-SqlInventory.ps1 to OutputPath\Logs.
            # For the dashboard, we need to ensure $logPath used here is the one Run-SqlInventory.ps1 will use.
            # The $scriptParams hashtable now contains the definitive LogPath being passed.
            $effectiveLogPath = $scriptParams.LogPath
            # If $scriptParams.LogPath was not set because the user left the field blank,
            # then it would have defaulted inside Run-SqlInventory to Join-Path $scriptParams.OutputPath 'Logs'.
            # We need to replicate this logic here for the monitor to find the logs.
            if (-not $effectiveLogPath) {
                $effectiveLogPath = Join-Path $scriptParams.OutputPath 'Logs'
            }

            $latestLogFile = Get-ChildItem -Path $effectiveLogPath -Filter "InventoryLog_*.log" -ErrorAction SilentlyContinue |
                             Sort-Object LastWriteTime -Descending |
                             Select-Object -First 1

            $logTail = "" # Default to empty string
            if ($latestLogFile) {
                $logTail = Get-Content -Path $latestLogFile.FullName -Tail 20 -ErrorAction SilentlyContinue
            }
            New-UDCodeBlock -Code ($logTail -join "`n") -Language text
        }
    }
})
