#Requires -Modules Pester
<#
    Pester 5 unit tests for Get-AccountPrefix.
    Run with:  Invoke-Pester ./Tests/AccountParse.Tests.ps1 -Output Detailed
#>

BeforeAll {
    # Dot-source only the ACCOUNT-PARSE region by loading the full script.
    # We redirect Write-Output so log noise stays out of test output.
    . (Join-Path $PSScriptRoot '..\Invoke-UniFiAlerts.ps1') *>$null 2>&1

    # Suppress Write-Log output during tests
    function Write-Log { param([string]$Level, [string]$Message) }
}

Describe 'Get-AccountPrefix' {

    Context 'Normal prefix extraction' {

        It 'Returns the prefix for a standard site name' {
            Get-AccountPrefix -SiteName 'AFF001_A1 Taxis' | Should -Be 'AFF001'
        }

        It 'Returns the prefix when the suffix contains multiple words' {
            Get-AccountPrefix -SiteName 'BCC002_B2 Garage Services Ltd' | Should -Be 'BCC002'
        }

        It 'Stops at the first underscore only (ignores subsequent ones)' {
            Get-AccountPrefix -SiteName 'XYZ003_Some_Site_Name' | Should -Be 'XYZ003'
        }

        It 'Returns an upper-case prefix unchanged' {
            Get-AccountPrefix -SiteName 'ACME99_ACME Corp' | Should -Be 'ACME99'
        }

        It 'Trims surrounding whitespace from the prefix' {
            Get-AccountPrefix -SiteName '  TRM001 _Trimmed Site' | Should -Be 'TRM001'
        }

        It 'Handles a trailing underscore with an empty suffix' {
            Get-AccountPrefix -SiteName 'SUF001_' | Should -Be 'SUF001'
        }

        It 'Handles Unicode characters in the suffix' {
            Get-AccountPrefix -SiteName 'UNI001_Ünïcödé Site' | Should -Be 'UNI001'
        }

        It 'Handles numeric-only prefixes' {
            Get-AccountPrefix -SiteName '12345_Numeric Prefix' | Should -Be '12345'
        }
    }

    Context 'No underscore — should return $null' {

        It 'Returns $null for a plain site name with no underscore' {
            Get-AccountPrefix -SiteName 'NoUnderscore' | Should -BeNullOrEmpty
        }

        It 'Returns $null for an empty string' {
            Get-AccountPrefix -SiteName '' | Should -BeNullOrEmpty
        }

        It 'Returns $null for a site name that is only spaces' {
            Get-AccountPrefix -SiteName '   ' | Should -BeNullOrEmpty
        }
    }

    Context 'Leading underscore — prefix is empty, should return $null' {

        It 'Returns $null when the site name starts with an underscore' {
            Get-AccountPrefix -SiteName '_LeadingUnderscore' | Should -BeNullOrEmpty
        }

        It 'Returns $null when the site name is only an underscore' {
            Get-AccountPrefix -SiteName '_' | Should -BeNullOrEmpty
        }
    }
}
