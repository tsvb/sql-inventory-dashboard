@(New-UDDashboard -Title "SQL Inventory Dashboard" -Content {
    New-UDForm -Title "Run SQL Inventory Scan" -Content {
        New-UDTextbox -Id 'serverNames' -Label 'Server Names (comma separated)' -Multiline
        New-UDTextbox -Id 'outputPath' -Label 'Output Path' -Value "C:\\SQLInventory"
        New-UDTextbox -Id 'logPath' -Label 'Log Path (optional)'
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

        $outputPath = $EventData.outputPath
        $logPath = if ($EventData.logPath) { $EventData.logPath } else { Join-Path $outputPath 'Logs' }
        $throttleLimit = [int]$EventData.throttleLimit
        $dryRun = [bool]$EventData.dryRun
        $skipCollections = $EventData.skipCollections

        $sqlCred = New-Object System.Management.Automation.PSCredential($EventData.sqlUsername,(ConvertTo-SecureString $EventData.sqlPassword -AsPlainText -Force))
        $osCred = New-Object System.Management.Automation.PSCredential($EventData.osUsername,(ConvertTo-SecureString $EventData.osPassword -AsPlainText -Force))

        $scriptParams = @{
            ServerNames = $serverNames
            OutputPath = $outputPath
            LogPath = $logPath
            ThrottleLimit = $throttleLimit
            DryRun = $dryRun
            SqlCredential = $sqlCred
            Credential = $osCred
        }
        if ($skipCollections) { $scriptParams.SkipCollections = $skipCollections }

        $paramStr = $scriptParams.GetEnumerator() | ForEach-Object {
            if ($_.Value -is [System.Collections.IEnumerable] -and -not ($_.Value -is [string])) {
                "-{0} \"{1}\"" -f $_.Key, ($_.Value -join ',')
            } elseif ($_.Value -is [switch] -and $_.Value.IsPresent) {
                "-{0}" -f $_.Key
            } elseif ($_.Value -is [System.Management.Automation.PSCredential]) {
                "-{0} \"{1}\"" -f $_.Key, $_.Value.UserName
            } else {
                "-{0} \"{1}\"" -f $_.Key, $_.Value
            }
        } | Out-String

        $inventoryScriptPath = "C:\\Scripts\\Run-SqlInventory.ps1"
        $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$inventoryScriptPath`" $paramStr"

        Invoke-Expression $cmd | Out-Null

        Show-UDToast -Message "Inventory script executed. Showing output..." -Duration 5000

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
            $logTail = Get-Content -Path (Join-Path $logPath ("InventoryLog_" + (Get-Date -Format 'yyMMdd_HHmmss') + ".log")) -Tail 20 -ErrorAction SilentlyContinue
            New-UDCodeBlock -Code ($logTail -join "`n") -Language text
        }
    }
})
