$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

$script:credentialCalls = 0
$script:credentialAvailable = $true
function Get-Command { param($Name, $CommandType, $ErrorAction) [pscustomobject]@{ Source = 'Invoke-FixtureGh' } }
function Invoke-FixtureGh {
    $script:credentialCalls++
    $global:LASTEXITCODE = if ($script:credentialAvailable) { 0 } else { 1 }
    if ($script:credentialAvailable) { 'gho_SYNTHETIC_SECRET' }
}
try {
    $api = [System.Net.HttpWebRequest]::CreateHttp('https://api.github.com/repos/owner/repo/releases/latest')
    $output = @(Set-CpaStackGitHubAuthentication -Request $api)
    Assert-Equal 0 $output.Count 'Credential is not written to output'
    Assert-Equal 'Bearer gho_SYNTHETIC_SECRET' $api.Headers['Authorization'] 'API receives authentication'
    foreach ($uri in @('https://github.com/owner/repo', 'https://release-assets.githubusercontent.com/asset', 'https://api.github.com.evil.example/', 'http://api.github.com/', 'https://api.github.com:8443/')) {
        $hop = [System.Net.HttpWebRequest]::CreateHttp($uri)
        Set-CpaStackGitHubAuthentication -Request $hop
        Assert-True ([string]::IsNullOrEmpty($hop.Headers['Authorization'])) 'Non-API redirect receives no credential'
    }
    Assert-Equal 1 $script:credentialCalls 'Non-API hosts do not access credentials'
    $script:credentialAvailable = $false
    $anonymous = [System.Net.HttpWebRequest]::CreateHttp('https://api.github.com/')
    Set-CpaStackGitHubAuthentication -Request $anonymous
    Assert-True ([string]::IsNullOrEmpty($anonymous.Headers['Authorization'])) 'Logged-out users retain anonymous access'
} finally {
    Remove-Item Function:Get-Command, Function:Invoke-FixtureGh
}
'GitHub authentication tests passed.'
