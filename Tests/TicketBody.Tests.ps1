#Requires -Modules Pester
<#
    Pester 5 unit tests for ticket title/description formatting.
    Run with:  Invoke-Pester ./Tests/TicketBody.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-UniFiAlerts.ps1') *>$null 2>&1
    function Write-Log { param([string]$Level, [string]$Message) }

    # Minimal mock environment for New-AutoTaskTicket (so it does not call the network)
    $Script:AtBaseUrl    = 'https://mock-autotask.example.com/ATServicesRest'
    $Script:AtQueueId    = '1'
    $Script:AtSourceId   = '4'
    $Script:AtPriorityId = '1'
    $Script:AtUsername   = 'test@example.com'
    $Script:AtSecret     = 'secret'

    # Shared test fixtures
    $Script:SampleAlert = [PSCustomObject]@{
        _id       = '64a1f3c2b5e4d20001a3f812'
        key       = 'EVT_AP_Disconnected'
        datetime  = '2024-01-15T09:23:41Z'
        site_name = 'AFF001_A1 Taxis'
        ap        = 'aa:bb:cc:dd:ee:ff'
        ap_name   = 'AP-Reception'
        subsystem = 'wlan'
        msg       = 'AP[aa:bb:cc:dd:ee:ff] was disconnected'
        archived  = $false
        count     = 1
    }

    $Script:SampleCompany = @{
        CompanyID   = 12345
        CompanyName = 'A1 Taxis'
    }

    $Script:SampleContact = @{
        ContactID = 99
        Name      = 'Jane Smith'
        Phone     = '07700 900123'
        Email     = 'jane.smith@a1taxis.co.uk'
    }
}

Describe 'Build-TicketDescription' {

    BeforeAll {
        $Script:Desc = Build-TicketDescription `
            -Alert         $Script:SampleAlert `
            -Company       $Script:SampleCompany `
            -Contact       $Script:SampleContact `
            -AccountPrefix 'AFF001'
    }

    It 'Contains an ALERT SUMMARY section' {
        $Script:Desc | Should -Match 'ALERT SUMMARY'
    }

    It 'Contains the client name and account prefix in ALERT SUMMARY' {
        $Script:Desc | Should -Match 'A1 Taxis'
        $Script:Desc | Should -Match 'AFF001'
    }

    It 'Contains the device name' {
        $Script:Desc | Should -Match 'AP-Reception'
    }

    It 'Contains the MAC address' {
        $Script:Desc | Should -Match 'aa:bb:cc:dd:ee:ff'
    }

    It 'Contains a WHAT HAPPENED section' {
        $Script:Desc | Should -Match 'WHAT HAPPENED'
    }

    It 'WHAT HAPPENED section contains plain English, not raw event code' {
        $Script:Desc | Should -Match 'Access point'
        $Script:Desc | Should -Not -Match 'EVT_AP_Disconnected'
    }

    It 'Contains a NEXT STEPS section' {
        $Script:Desc | Should -Match 'NEXT STEPS'
    }

    It 'NEXT STEPS contains the UniFi Cloud Controller reboot instruction' {
        $Script:Desc | Should -Match 'UniFi Cloud Controller'
        $Script:Desc | Should -Match 'Restart'
    }

    It 'NEXT STEPS contains primary contact scheduling language' {
        $Script:Desc | Should -Match 'primary contact'
        $Script:Desc | Should -Match 'schedule'
    }

    It 'Contains a PRIMARY CONTACT section' {
        $Script:Desc | Should -Match 'PRIMARY CONTACT'
    }

    It 'PRIMARY CONTACT section shows contact name, phone and email' {
        $Script:Desc | Should -Match 'Jane Smith'
        $Script:Desc | Should -Match '07700 900123'
        $Script:Desc | Should -Match 'jane\.smith@a1taxis\.co\.uk'
    }

    It 'Contains a RAW ALERT DATA section' {
        $Script:Desc | Should -Match 'RAW ALERT DATA'
    }

    It 'RAW ALERT DATA contains the alert ID' {
        $Script:Desc | Should -Match '64a1f3c2b5e4d20001a3f812'
    }

    It 'RAW ALERT DATA contains the raw event code' {
        $Script:Desc | Should -Match 'EVT_AP_Disconnected'
    }

    It 'Sections appear in the correct order' {
        $summaryPos  = $Script:Desc.IndexOf('ALERT SUMMARY')
        $happenedPos = $Script:Desc.IndexOf('WHAT HAPPENED')
        $stepsPos    = $Script:Desc.IndexOf('NEXT STEPS')
        $contactPos  = $Script:Desc.IndexOf('PRIMARY CONTACT')
        $rawPos      = $Script:Desc.IndexOf('RAW ALERT DATA')

        $summaryPos  | Should -BeLessThan $happenedPos
        $happenedPos | Should -BeLessThan $stepsPos
        $stepsPos    | Should -BeLessThan $contactPos
        $contactPos  | Should -BeLessThan $rawPos
    }
}

Describe 'Build-TicketDescription — no primary contact' {

    It 'Shows manual assignment note when contact is null' {
        $desc = Build-TicketDescription `
            -Alert         $Script:SampleAlert `
            -Company       $Script:SampleCompany `
            -Contact       $null `
            -AccountPrefix 'AFF001'

        $desc | Should -Match 'No primary contact'
        $desc | Should -Match 'assign manually'
    }
}

Describe 'Build-TicketDescription — device name fallback' {

    It 'Falls back to MAC address when ap_name is missing' {
        $alertNoName = $Script:SampleAlert | Select-Object *
        $alertNoName.ap_name = $null

        $desc = Build-TicketDescription `
            -Alert         $alertNoName `
            -Company       $Script:SampleCompany `
            -Contact       $null `
            -AccountPrefix 'AFF001'

        # MAC address should appear in the Device field
        $desc | Should -Match 'aa:bb:cc:dd:ee:ff'
    }
}

Describe 'Ticket title format (Get-AlertTitle)' {

    It 'Title is plain English for a known event code' {
        $title = Get-AlertTitle -EventKey 'EVT_AP_Disconnected'
        $title | Should -Be 'AP Disconnected'
        $title | Should -Not -Match 'EVT_'
    }

    It 'Title includes the event code in brackets for unknown codes' {
        $title = Get-AlertTitle -EventKey 'EVT_BRAND_NEW'
        $title | Should -Match 'EVT_BRAND_NEW'
    }
}
