BeforeAll {
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $postprovisionPath = Join-Path $repositoryRoot 'scripts/postprovision.ps1'
    $statusPath = Join-Path $repositoryRoot 'scripts/status.ps1'
    $sentinel = 'https://example.invalid/callback?sig=callback-sentinel'
}

Describe 'Callback URL output' {
    It 'keeps the callback URL out of the postprovision summary' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($postprovisionPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $summaryFunction = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-DeploymentSummary'
        }, $true)
        $summaryFunction | Should -Not -BeNullOrEmpty

        & {
            . ([scriptblock]::Create($summaryFunction.Extent.Text))
            $previous = @{}
            foreach ($name in @('LOGIC_APP_NAME', 'LIFECYCLE_LOGIC_APP_NAME', 'AZURE_RESOURCE_GROUP', 'TEAMS_CONNECTION_NAME')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, "test-$name", 'Process')
            }
            try {
                $arguments = @{ ConnectionStatus = 'Connected' }
                if ((Get-Command Write-DeploymentSummary).Parameters.ContainsKey('NotificationUrl')) {
                    $arguments.NotificationUrl = $sentinel
                }
                $output = Write-DeploymentSummary @arguments 6>&1 | Out-String
                $output | Should -Match 'Teams Connection Status: Connected'
                $output | Should -Not -Match 'callback-sentinel'
                $output | Should -Not -Match 'Webhook URL:'
            } finally {
                foreach ($name in $previous.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
                }
            }
        }
    }

    It 'keeps a cached callback URL out of status output' {
        & {
            function azd {
                @(
                    'LOGIC_APP_NAME=alert-workflow',
                    'LIFECYCLE_LOGIC_APP_NAME=lifecycle-workflow',
                    'AZURE_RESOURCE_GROUP=test-group',
                    'AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001',
                    'TEAMS_CONNECTION_NAME=teams-test',
                    "GRAPH_NOTIFICATION_URL=$sentinel"
                )
            }
            function az { 'test-arm-token' }
            function Invoke-RestMethod {
                param($Method, $Uri, $Headers)
                if ($Uri -like '*Microsoft.Web/connections*') {
                    return [pscustomobject]@{ properties = [pscustomobject]@{ statuses = @([pscustomobject]@{ status = 'Connected' }) } }
                }
                return [pscustomobject]@{ value = @([pscustomobject]@{ properties = [pscustomobject]@{ status = 'Succeeded'; startTime = '2026-10-03T00:00:00Z' } }) }
            }

            $previous = @{}
            foreach ($name in @('LOGIC_APP_NAME', 'LIFECYCLE_LOGIC_APP_NAME', 'AZURE_RESOURCE_GROUP', 'AZURE_SUBSCRIPTION_ID', 'TEAMS_CONNECTION_NAME', 'GRAPH_NOTIFICATION_URL')) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            try {
                $output = & $statusPath 6>&1 | Out-String
                $output | Should -Match 'Teams Connection Status: Connected'
                $output | Should -Match 'Latest Lifecycle Run Status: Succeeded'
                $output | Should -Not -Match 'callback-sentinel'
                $output | Should -Not -Match 'Webhook URL:'
            } finally {
                foreach ($name in $previous.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
                }
            }
        }
    }
}
