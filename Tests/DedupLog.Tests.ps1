#Requires -Modules Pester
<#
    Pester 5 unit tests for the deduplication log functions.
    Run with:  Invoke-Pester ./Tests/DedupLog.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-UniFiAlerts.ps1') *>$null 2>&1
    function Write-Log { param([string]$Level, [string]$Message) }

    # Point the dedup log at a temp file for tests
    $Script:DedupLogPath = Join-Path $TestDrive 'dedup-test.json'
}

Describe 'Read-DedupLog' {

    It 'Returns an empty hashtable when the log file does not exist' {
        $result = Read-DedupLog
        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It 'Returns an empty hashtable when the log file is corrupt JSON' {
        Set-Content -Path $Script:DedupLogPath -Value 'NOT VALID JSON{{{'
        Read-DedupLog | Should -BeOfType [hashtable]
    }

    It 'Reads a valid log file and returns the correct entries' {
        $data = @{ 'alert-id-1' = @{ ticketId = 100; timestamp = (Get-Date -Format 'o') } }
        $data | ConvertTo-Json -Depth 5 | Set-Content -Path $Script:DedupLogPath -Encoding UTF8

        $result = Read-DedupLog
        $result.ContainsKey('alert-id-1') | Should -Be $true
        $result['alert-id-1'].ticketId | Should -Be 100
    }
}

Describe 'Write-DedupLog' {

    BeforeEach {
        # Fresh log for each test
        if (Test-Path $Script:DedupLogPath) { Remove-Item $Script:DedupLogPath -Force }
    }

    It 'Creates the log file if it does not exist' {
        $log = @{}
        Write-DedupLog -Log $log -AlertId 'new-alert-1' -TicketId 999
        Test-Path $Script:DedupLogPath | Should -Be $true
    }

    It 'Writes the alert ID and ticket ID correctly' {
        $log = @{}
        Write-DedupLog -Log $log -AlertId 'new-alert-2' -TicketId 42
        $saved = Get-Content $Script:DedupLogPath | ConvertFrom-Json
        $saved.'new-alert-2'.ticketId | Should -Be 42
    }

    It 'Preserves existing entries when appending' {
        $existingTime = (Get-Date).AddHours(-1).ToString('o')
        $log = @{ 'existing-alert' = @{ ticketId = 1; timestamp = $existingTime } }
        Write-DedupLog -Log $log -AlertId 'new-alert-3' -TicketId 77
        $saved = Get-Content $Script:DedupLogPath | ConvertFrom-Json
        $saved.'existing-alert' | Should -Not -BeNullOrEmpty
        $saved.'new-alert-3'.ticketId | Should -Be 77
    }
}

Describe 'Test-AlreadyLogged' {

    It 'Returns $false for an alert ID not in the log' {
        Test-AlreadyLogged -Log @{} -AlertId 'missing-id' | Should -Be $false
    }

    It 'Returns $true for a recent alert ID' {
        $log = @{ 'recent-id' = @{ ticketId = 1; timestamp = (Get-Date -Format 'o') } }
        Test-AlreadyLogged -Log $log -AlertId 'recent-id' | Should -Be $true
    }

    It 'Returns $false for an expired alert ID (older than 7 days)' {
        $old = (Get-Date).AddDays(-8).ToString('o')
        $log = @{ 'old-id' = @{ ticketId = 1; timestamp = $old } }
        Test-AlreadyLogged -Log $log -AlertId 'old-id' | Should -Be $false
    }

    It 'Returns $true for an alert exactly at the retention boundary' {
        # 6 days 23 hours old — should still count as logged
        $recent = (Get-Date).AddDays(-6).AddHours(-23).ToString('o')
        $log = @{ 'boundary-id' = @{ ticketId = 1; timestamp = $recent } }
        Test-AlreadyLogged -Log $log -AlertId 'boundary-id' | Should -Be $true
    }
}

Describe 'Remove-ExpiredDedupEntries' {

    It 'Removes entries older than 7 days' {
        $old = (Get-Date).AddDays(-8).ToString('o')
        $log = @{
            'old-alert'    = @{ ticketId = 1; timestamp = $old }
            'fresh-alert'  = @{ ticketId = 2; timestamp = (Get-Date -Format 'o') }
        }
        $cleaned = Remove-ExpiredDedupEntries -Log $log
        $cleaned.ContainsKey('old-alert')   | Should -Be $false
        $cleaned.ContainsKey('fresh-alert') | Should -Be $true
    }

    It 'Returns the same log unchanged when all entries are fresh' {
        $log = @{
            'a' = @{ ticketId = 1; timestamp = (Get-Date -Format 'o') }
            'b' = @{ ticketId = 2; timestamp = (Get-Date -Format 'o') }
        }
        $cleaned = Remove-ExpiredDedupEntries -Log $log
        $cleaned.Count | Should -Be 2
    }

    It 'Handles an empty log without error' {
        { Remove-ExpiredDedupEntries -Log @{} } | Should -Not -Throw
    }
}
