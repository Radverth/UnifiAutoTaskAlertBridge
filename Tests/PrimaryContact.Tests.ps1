#Requires -Modules Pester
<#
    Pester 5 unit tests for Get-PrimaryContact and its null-handling behaviour.
    Because Get-PrimaryContact makes real HTTP calls, these tests mock
    Invoke-AutoTaskRequest to keep the suite offline.

    Run with:  Invoke-Pester ./Tests/PrimaryContact.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-UniFiAlerts.ps1') *>$null 2>&1
    function Write-Log { param([string]$Level, [string]$Message) }

    $Script:AtBaseUrl  = 'https://mock-at.example.com/ATServicesRest'
    $Script:AtUsername = 'test@example.com'
    $Script:AtSecret   = 'secret'
}

Describe 'Get-PrimaryContact' {

    Context 'When a primary contact exists' {

        BeforeEach {
            Mock Invoke-AutoTaskRequest {
                return [PSCustomObject]@{
                    items = @(
                        [PSCustomObject]@{
                            id           = 99
                            firstName    = 'Jane'
                            lastName     = 'Smith'
                            phone        = '07700 900123'
                            emailAddress = 'jane.smith@example.com'
                            isPrimary    = $true
                            Active       = $true
                        }
                    )
                }
            } -ModuleName $null
        }

        It 'Returns a hashtable with ContactID' {
            $result = Get-PrimaryContact -CompanyID 12345
            $result | Should -Not -BeNullOrEmpty
            $result.ContactID | Should -Be 99
        }

        It 'Returns the correct Name' {
            $result = Get-PrimaryContact -CompanyID 12345
            $result.Name | Should -Be 'Jane Smith'
        }

        It 'Returns the correct Phone' {
            $result = Get-PrimaryContact -CompanyID 12345
            $result.Phone | Should -Be '07700 900123'
        }

        It 'Returns the correct Email' {
            $result = Get-PrimaryContact -CompanyID 12345
            $result.Email | Should -Be 'jane.smith@example.com'
        }
    }

    Context 'When no contacts exist for the company' {

        BeforeEach {
            Mock Invoke-AutoTaskRequest {
                return [PSCustomObject]@{ items = @() }
            } -ModuleName $null
        }

        It 'Returns $null gracefully' {
            Get-PrimaryContact -CompanyID 99999 | Should -BeNullOrEmpty
        }
    }

    Context 'When the API call throws an error' {

        BeforeEach {
            Mock Invoke-AutoTaskRequest { throw 'Connection refused' } -ModuleName $null
        }

        It 'Returns $null instead of propagating the exception' {
            { Get-PrimaryContact -CompanyID 1 } | Should -Not -Throw
            Get-PrimaryContact -CompanyID 1 | Should -BeNullOrEmpty
        }
    }

    Context 'When no contact is flagged as isPrimary' {

        BeforeEach {
            Mock Invoke-AutoTaskRequest {
                return [PSCustomObject]@{
                    items = @(
                        [PSCustomObject]@{
                            id           = 55
                            firstName    = 'Bob'
                            lastName     = 'Builder'
                            phone        = '01234 567890'
                            emailAddress = 'bob@example.com'
                            isPrimary    = $false
                            Active       = $true
                        }
                    )
                }
            } -ModuleName $null
        }

        It 'Falls back to the first active contact' {
            $result = Get-PrimaryContact -CompanyID 12345
            $result | Should -Not -BeNullOrEmpty
            $result.ContactID | Should -Be 55
            $result.Name | Should -Be 'Bob Builder'
        }
    }
}
