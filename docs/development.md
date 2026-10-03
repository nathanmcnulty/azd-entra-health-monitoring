# Development and publishing

Contributor checks should be run from a clean checkout and must not use device-code authentication or tenant writes.

Recommended validation:

```powershell
Test-Path .\azure.yaml
az bicep build --file .\infra\main.bicep --stdout | Out-Null
pwsh -NoProfile -Command 'Get-ChildItem .\scripts -Filter *.ps1 | ForEach-Object { [scriptblock]::Create((Get-Content -Raw $_.FullName)) | Out-Null }; Invoke-Pester -Path .\tests'
```

Validate README links and ensure the root quickstart remains the exact default-branch `azd init -t` command. A real `azd init`/`azd up` smoke test requires an administrator's explicit Azure and Teams consent and is outside documentation-only validation. Publish changes through the default branch after local checks and hosted CI.
