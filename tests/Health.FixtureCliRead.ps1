#Requires -Version 7.6
# Invoked only by the bounded fixture process transport; no sign-in or defaults.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$inputValue=[Console]::In.ReadToEnd()|ConvertFrom-Json -AsHashtable
if($inputValue -isnot [Collections.IDictionary] -or $inputValue.Count -ne 2 -or
   $inputValue.action -isnot [string] -or $inputValue.action -cnotin @('Account','ArmToken') -or
   $inputValue.subscription -isnot [string] -or $inputValue.subscription -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'Invalid fixed CLI read request.'}
$null=Get-Command az -CommandType Application -ErrorAction Stop
if($inputValue.action -ceq 'Account') { & az account show --subscription $inputValue.subscription --output json --only-show-errors }
else { & az account get-access-token --subscription $inputValue.subscription --resource 'https://management.azure.com/' --output json --only-show-errors }
exit $LASTEXITCODE
