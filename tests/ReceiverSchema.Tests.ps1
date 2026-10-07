BeforeAll {
    $definition = Get-Content (Join-Path $PSScriptRoot '../infra/workflow-definition.json') -Raw | ConvertFrom-Json -Depth 100
    $schema = $definition.triggers.When_a_HTTP_request_is_received.inputs.schema | ConvertTo-Json -Depth 30
}

Describe 'Receiver payload schema' {
    It 'accepts optional notification fields but rejects wrong scalar and object types before processing' {
        $definition.triggers.When_a_HTTP_request_is_received.operationOptions | Should -Be 'EnableSchemaValidation'
        $cases = @(
            @{ body = '{}'; valid = $true },
            @{ body = '{"value":[{}]}'; valid = $true },
            @{ body = '{"value":[{"clientState":"synthetic","changeType":"created","resourceData":{"id":"synthetic-alert"}}]}'; valid = $true },
            @{ body = '{"value":[{"changeType":null,"resourceData":null}]}'; valid = $true },
            @{ body = '{"value":[{"changeType":123}]}'; valid = $false },
            @{ body = '{"value":[{"clientState":{}}]}'; valid = $false },
            @{ body = '{"value":[{"resourceData":[]}]}'; valid = $false },
            @{ body = '{"value":[{"resourceData":{"id":123}}]}'; valid = $false },
            @{ body = '{"value":"not-an-array"}'; valid = $false }
        )
        foreach ($case in $cases) {
            ($case.body | Test-Json -Schema $schema -ErrorAction SilentlyContinue) | Should -Be $case.valid
        }
    }
}
