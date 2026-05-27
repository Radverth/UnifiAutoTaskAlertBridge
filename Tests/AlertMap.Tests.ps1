#Requires -Modules Pester
<#
    Pester 5 unit tests for Get-AlertDescription and Get-AlertTitle.
    Run with:  Invoke-Pester ./Tests/AlertMap.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-UniFiAlerts.ps1') *>$null 2>&1
    function Write-Log { param([string]$Level, [string]$Message) }
}

Describe 'Get-AlertDescription' {

    Context 'Known event codes return plain English descriptions' {

        It 'Maps EVT_AP_Disconnected' {
            Get-AlertDescription -EventKey 'EVT_AP_Disconnected' |
                Should -Be 'Access point disconnected from the UniFi controller'
        }

        It 'Maps EVT_AP_Connected' {
            Get-AlertDescription -EventKey 'EVT_AP_Connected' |
                Should -Be 'Access point reconnected to the UniFi controller'
        }

        It 'Maps EVT_AP_Restarted' {
            Get-AlertDescription -EventKey 'EVT_AP_Restarted' |
                Should -Be 'Access point restarted'
        }

        It 'Maps EVT_AP_UpgradeScheduled' {
            Get-AlertDescription -EventKey 'EVT_AP_UpgradeScheduled' |
                Should -Be 'Access point firmware upgrade scheduled'
        }

        It 'Maps EVT_SW_Disconnected' {
            Get-AlertDescription -EventKey 'EVT_SW_Disconnected' |
                Should -Be 'Network switch disconnected from the UniFi controller'
        }

        It 'Maps EVT_SW_Connected' {
            Get-AlertDescription -EventKey 'EVT_SW_Connected' |
                Should -Be 'Network switch reconnected to the UniFi controller'
        }

        It 'Maps EVT_GW_Disconnected' {
            Get-AlertDescription -EventKey 'EVT_GW_Disconnected' |
                Should -Be 'Gateway / router disconnected from the UniFi controller'
        }

        It 'Maps EVT_GW_Connected' {
            Get-AlertDescription -EventKey 'EVT_GW_Connected' |
                Should -Be 'Gateway / router reconnected to the UniFi controller'
        }

        It 'Maps EVT_GW_WANTransitioned' {
            Get-AlertDescription -EventKey 'EVT_GW_WANTransitioned' |
                Should -Be 'WAN connection changed state (failover or recovery)'
        }

        It 'Maps EVT_GW_VPNDown' {
            Get-AlertDescription -EventKey 'EVT_GW_VPNDown' |
                Should -Be 'VPN tunnel went down'
        }

        It 'Maps EVT_GW_VPNUp' {
            Get-AlertDescription -EventKey 'EVT_GW_VPNUp' |
                Should -Be 'VPN tunnel came back up'
        }

        It 'Maps EVT_LTE_Disconnected' {
            Get-AlertDescription -EventKey 'EVT_LTE_Disconnected' |
                Should -Be 'LTE failover link disconnected'
        }

        It 'Maps EVT_LTE_Connected' {
            Get-AlertDescription -EventKey 'EVT_LTE_Connected' |
                Should -Be 'LTE failover link reconnected'
        }

        It 'Maps EVT_CLIENT_Roam' {
            Get-AlertDescription -EventKey 'EVT_CLIENT_Roam' |
                Should -Be 'Wireless client roamed between access points'
        }

        It 'Maps EVT_CLIENT_Blocked' {
            Get-AlertDescription -EventKey 'EVT_CLIENT_Blocked' |
                Should -Be 'Wireless client was blocked'
        }
    }

    Context 'Unknown event codes return fallback description' {

        It 'Prefixes unknown codes with "Unknown event:"' {
            Get-AlertDescription -EventKey 'EVT_TOTALLY_UNKNOWN' |
                Should -BeLike 'Unknown event:*EVT_TOTALLY_UNKNOWN*'
        }

        It 'Handles an empty event key gracefully' {
            Get-AlertDescription -EventKey '' | Should -BeLike 'Unknown event:*'
        }

        It 'Does not return null for an unknown code' {
            Get-AlertDescription -EventKey 'NONSENSE' | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-AlertTitle' {

    It 'Returns a short title for EVT_AP_Disconnected' {
        Get-AlertTitle -EventKey 'EVT_AP_Disconnected' | Should -Be 'AP Disconnected'
    }

    It 'Returns a short title for EVT_GW_VPNDown' {
        Get-AlertTitle -EventKey 'EVT_GW_VPNDown' | Should -Be 'VPN Tunnel Down'
    }

    It 'Returns a fallback for unknown codes' {
        Get-AlertTitle -EventKey 'EVT_UNKNOWN_XYZ' | Should -BeLike '*EVT_UNKNOWN_XYZ*'
    }

    It 'Title does not contain the raw event code for known events' {
        $title = Get-AlertTitle -EventKey 'EVT_SW_Disconnected'
        $title | Should -Not -BeLike '*EVT_*'
    }
}
