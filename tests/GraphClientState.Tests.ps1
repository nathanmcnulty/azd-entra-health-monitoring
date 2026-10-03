BeforeAll {
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $bootstrapPath = Join-Path $repositoryRoot 'scripts/Initialize-GraphClientState.ps1'
    $subscriptionId = '43babb60-9e73-4dc8-b769-4401c01aad73'
    $tenantId = '847b5907-ca15-40f4-b171-eb18619dbfab'
    $claims = @{ tid = $tenantId; oid = '00000000-0000-0000-0000-000000000123' } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $token = "header.$encoded.signature"
    $bootstrapArgs = @{
        SubscriptionId = $subscriptionId
        TenantId = $tenantId
        ResourceGroupName = 'rg-health-test'
        Location = 'westus2'
        EnvironmentName = 'health-test'
        LogicAppName = 'la-health-test'
    }
}

Describe 'Graph notification clientState bootstrap' {
    BeforeEach {
        $global:azCalls = [Collections.Generic.List[string]]::new()
        $global:azdCalls = [Collections.Generic.List[string]]::new()
        $global:secretWrites = [Collections.Generic.List[string]]::new()
        $global:secretValue = $null
        $global:vaultExists = $false
        $global:workflowExists = $false
        $global:lifecycleDisabled = $false
        function az {
            $command = ($args | ForEach-Object { [string]$_ }) -join ' '
            $global:azCalls.Add($command)
            $global:LASTEXITCODE = 0
            if ($command.StartsWith('account show ')) {
                return @{ id = $subscriptionId; tenantId = $tenantId; environmentName = 'AzureCloud' } | ConvertTo-Json -Compress
            }
            if ($command.StartsWith('account get-access-token ')) { return $token }
            if ($command.StartsWith('group exists ')) { return 'true' }
            if ($command.StartsWith('keyvault create ')) { $global:vaultExists = $true; return }
        }
        function azd {
            $global:azdCalls.Add(($args | ForEach-Object { [string]$_ }) -join ' ')
            $global:LASTEXITCODE = 0
        }
        function Invoke-RestMethod {
            param($Method, $Uri, $Headers, $Body, $ContentType)
            if ($Uri -like 'https://management.azure.com/*') {
                if ($Uri -like '*Microsoft.KeyVault/vaults/*') {
                    if (-not $global:vaultExists) {
                        throw [Net.Http.HttpRequestException]::new('missing', $null, [Net.HttpStatusCode]::NotFound)
                    }
                    $name = [regex]::Match($Uri, '/vaults/([a-z0-9-]+)').Groups[1].Value
                    return @{ id = "/subscriptions/$subscriptionId/resourceGroups/rg-health-test/providers/Microsoft.KeyVault/vaults/$name";
                        properties = @{ tenantId = $tenantId; enableRbacAuthorization = $false };
                        tags = @{ 'entra-health-env' = 'health-test' } }
                }
                if ($Uri -like '*la-graph-subscription-management*') {
                    return @{ properties = @{ state = $(if ($global:lifecycleDisabled) { 'Disabled' } else { 'Enabled' }) } }
                }
                if ($global:workflowExists) { return @{ id = 'existing-workflow' } }
                throw [Net.Http.HttpRequestException]::new('missing', $null, [Net.HttpStatusCode]::NotFound)
            }
            if ($Method -eq 'GET') {
                if ($null -ne $global:secretValue) { return @{ value = $global:secretValue } }
                throw [Net.Http.HttpRequestException]::new('missing', $null, [Net.HttpStatusCode]::NotFound)
            }
            if ($Method -eq 'PUT') {
                $global:secretValue = [string](($Body | ConvertFrom-Json).value)
                $global:secretWrites.Add([string]$Uri)
                return @{ id = 'secret-id' }
            }
            throw 'Unexpected offline request.'
        }
    }

    It 'generates a 256-bit secret once and stores only its Key Vault reference in azd' {
        $output = (& $bootstrapPath @bootstrapArgs 6>&1 | Out-String)
        $global:secretValue | Should -Match '^[A-Za-z0-9_-]{43}$'
        $global:secretWrites.Count | Should -Be 1
        $global:azdCalls.Count | Should -Be 1
        $global:azdCalls[0] | Should -Match '^env set GRAPH_SUBSCRIPTION_CLIENT_STATE akvs://'
        $global:azdCalls[0] | Should -Not -Match [regex]::Escape($global:secretValue)
        $output | Should -Not -Match [regex]::Escape($global:secretValue)

        $global:vaultExists = $true
        $reference = [regex]::Match($global:azdCalls[0], 'akvs://\S+').Value
        & $bootstrapPath @bootstrapArgs -ExistingReference $reference | Out-Null
        $global:secretWrites.Count | Should -Be 1
        $global:azdCalls.Count | Should -Be 1
    }

    It 'refuses an existing deterministic-state workflow before any Azure writes' {
        $global:workflowExists = $true
        { & $bootstrapPath @bootstrapArgs } | Should -Throw '*explicit Graph subscription migration*'
        $global:secretWrites.Count | Should -Be 0
        @($global:azCalls | Where-Object { $_ -match 'keyvault create|keyvault set-policy|group create' }).Count | Should -Be 0
    }

    It 'rejects a plaintext or wrong-environment reference before any Azure writes' {
        { & $bootstrapPath @bootstrapArgs -ExistingReference 'predictable-guid' } |
            Should -Throw '*environment-owned Key Vault secret*'
        $global:secretWrites.Count | Should -Be 0
    }

    It 'rotates only after explicit absence confirmation and a disabled lifecycle workflow' {
        & $bootstrapPath @bootstrapArgs | Out-Null
        $old = $global:secretValue
        $reference = [regex]::Match($global:azdCalls[0], 'akvs://\S+').Value
        $global:vaultExists = $true
        { & $bootstrapPath @bootstrapArgs -ExistingReference $reference -Rotate } |
            Should -Throw '*explicit verification*'
        { & $bootstrapPath @bootstrapArgs -ExistingReference $reference -Rotate -VerifiedSubscriptionAbsent } |
            Should -Throw '*Disable the lifecycle workflow*'
        $global:secretWrites.Count | Should -Be 1
        $global:lifecycleDisabled = $true
        & $bootstrapPath @bootstrapArgs -ExistingReference $reference -Rotate -VerifiedSubscriptionAbsent | Out-Null
        $global:secretWrites.Count | Should -Be 2
        $global:secretValue | Should -Not -Be $old
        $global:azdCalls.Count | Should -Be 1
    }

    It 'allows a legacy workflow to migrate only after both ownership review and lifecycle disablement' {
        $global:workflowExists = $true
        { & $bootstrapPath @bootstrapArgs -MigrationVerified -VerifiedSubscriptionAbsent } |
            Should -Throw '*Disable the lifecycle workflow*'
        $global:secretWrites.Count | Should -Be 0
        $global:lifecycleDisabled = $true
        & $bootstrapPath @bootstrapArgs -MigrationVerified -VerifiedSubscriptionAbsent | Out-Null
        $global:secretWrites.Count | Should -Be 1
        $global:azdCalls.Count | Should -Be 1
    }

    It 'refuses an existing weak or malformed secret without replacing it' {
        & $bootstrapPath @bootstrapArgs | Out-Null
        $reference = [regex]::Match($global:azdCalls[0], 'akvs://\S+').Value
        $global:vaultExists = $true
        $global:secretValue = 'predictable-guid'
        { & $bootstrapPath @bootstrapArgs -ExistingReference $reference } |
            Should -Throw '*not a supported 256-bit value*'
        $global:secretWrites.Count | Should -Be 1
    }
}
