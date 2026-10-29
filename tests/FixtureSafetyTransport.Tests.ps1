BeforeAll {
    if(-not('EntraHealthFixtures.BoundedIO'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'Health.FixtureIO.cs')}
    if(-not('HealthFixtureRecordingHandler'-as[type])){Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class HealthFixtureRecordingHandler : HttpMessageHandler {
    public int Calls; public int Status=200; public int Delay=0;
    public byte[] Body=Array.Empty<byte>(); public byte[] SentBody;
    public string Authorization; public string ContentType; public string RunId="exact-run"; public bool DuplicateRunId;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken t){
        Calls++;Authorization=r.Headers.Authorization?.ToString();ContentType=r.Content?.Headers.ContentType?.ToString();
        SentBody=r.Content==null?null:await r.Content.ReadAsByteArrayAsync(t);
        if(Delay>0)await Task.Delay(Delay,t);
        var response=new HttpResponseMessage((HttpStatusCode)Status){Content=new ByteArrayContent(Body)};
        response.Headers.TryAddWithoutValidation("x-ms-workflow-run-id",DuplicateRunId?new[]{RunId,"other-run"}:new[]{RunId});
        return response;
    }
}
'@}
    function Send-Fake($Handler,[string]$Method,[uri]$Uri,$Token,$Body,$Bytes,$ContentType){
        $client=[Net.Http.HttpClient]::new($Handler,$false)
        try {
            $methodInfo=[EntraHealthFixtures.BoundedIO].GetMethod('SendCore',[Reflection.BindingFlags]'NonPublic,Static')
            [object[]]$args=@($client,$Method,$Uri,$Token,$Body,1,$Bytes,$ContentType)
            $methodInfo.Invoke($null,$args).GetAwaiter().GetResult()
        }finally{$client.Dispose()}
    }
}
Describe 'Actual fixture transport with an in-memory HTTP handler' {
    It 'keeps GET body null and binds the bearer token' {
        $h=[HealthFixtureRecordingHandler]::new()
        $r=Send-Fake $h GET 'https://management.azure.com/fixed' 'synthetic' $null $null $null
        $h.Calls|Should -Be 1;$h.SentBody|Should -BeNullOrEmpty;$h.Authorization|Should -BeExactly 'Bearer synthetic'
        $r.WorkflowRunId|Should -BeExactly 'exact-run'
    }
    It 'sends an empty UTF8 text body without a bearer token for callbacks' {
        $h=[HealthFixtureRecordingHandler]::new()
        $null=Send-Fake $h POST 'https://fixture.logic.azure.com/fixed?sig=synthetic' $null $null ([byte[]]::new(0)) 'text/plain;charset=utf-8'
        $h.Calls|Should -Be 1;($null-eq$h.SentBody)|Should -BeFalse;$h.SentBody.Length|Should -Be 0
        $h.Authorization|Should -BeNullOrEmpty;$h.ContentType|Should -Match '^text/plain; charset=utf-8$'
    }
    It 'rejects a declared oversized response' {
        $h=[HealthFixtureRecordingHandler]::new();$h.Body=[byte[]]::new(1048577)
        {Send-Fake $h GET 'https://management.azure.com/fixed' 'synthetic' $null $null $null}|Should -Throw
        $h.Calls|Should -Be 1
    }
    It 'cancels a request which exceeds its deadline' {
        $h=[HealthFixtureRecordingHandler]::new();$h.Delay=5000
        {Send-Fake $h GET 'https://management.azure.com/fixed' 'synthetic' $null $null $null}|Should -Throw
        $h.Calls|Should -Be 1
    }
    It 'rejects cleartext HTTP before dispatch' {
        $h=[HealthFixtureRecordingHandler]::new()
        {Send-Fake $h GET 'http://management.azure.com/fixed' 'synthetic' $null $null $null}|Should -Throw
        $h.Calls|Should -Be 0
    }
    It 'rejects multiple run-ID header values rather than joining them' {
        $h=[HealthFixtureRecordingHandler]::new();$h.DuplicateRunId=$true
        {Send-Fake $h POST 'https://fixture.logic.azure.com/fixed?sig=synthetic' $null $null ([byte[]]::new(0)) 'text/plain'}|Should -Throw
        $h.Calls|Should -Be 1
    }
}
