#Requires -Version 7.6
# Explicit offline review check; this is not a deployment/runtime dependency.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReferencePath,[Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Composition output must be new.'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
Import-Module (Join-Path $PSScriptRoot 'Health.M20Preparation.psm1') -Force
$reader=Join-Path $ReferencePath 'tooling/Test-AzdNativeObservationCandidate.ps1'
foreach($scenario in @('normal','unknown-delete')){
    $p=Export-HealthM20ObservationPrototype -OutputDirectory (Join-Path $OutputDirectory $scenario) -Scenario $scenario
    $r=& $reader -RecordPath $p.recordPath -EvidenceRoot $p.evidenceRoot -BindingFiles $p.bindingFiles
    if($r.evidenceMode -cne 'simulation' -or $r.modeledOutcome -cne 'incomplete' -or $r.nativeQualified -or $r.executionAuthorized -or $r.publicationAuthorized){throw 'Composition overstated evidence.'}
    if(@($r.stages|Select-Object -First 5|Where-Object passed).Count){throw 'Unsupported proof became passing.'}
    if($scenario -eq 'unknown-delete' -and -not $r.recoveryEvidence){throw 'Unknown operation lost recovery evidence.'}
}
$p=Export-HealthM20ObservationPrototype -OutputDirectory (Join-Path $OutputDirectory 'drift')
[IO.File]::AppendAllText((Join-Path $p.evidenceRoot 'configuration.json'),' ')
$refused=$false
try{& $reader -RecordPath $p.recordPath -EvidenceRoot $p.evidenceRoot -BindingFiles $p.bindingFiles|Out-Null}catch{$refused=$true}
if(-not $refused){throw 'Composition accepted drift.'}
[pscustomobject]@{check='actual-Health-producer-to-Reference-reader';checks=3;passed=3;nativeQualified=$false;providerCalls=0}
