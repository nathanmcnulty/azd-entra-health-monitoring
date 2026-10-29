"""Offline integration: real gates/framing/HTTP/projector, fake OS/network edges."""
import base64
import copy
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts/m21'))
from control import Refused,canonical,digest,Journal
from live_io import Authority,OwnedTransport,handle_frame,validate_route,validate_token_claims,WORKER,WindowsJob,worker_main,bootstrap
from native import NativeController,main,qualified_absence
from test_m21_readiness import plan,oracle_record,Clock,Response
from build_fixture import candidate_plan,source_hashes
from oracle import context_bindings
from prepare_native import prepare
from m21_role_fixture import synthetic_inherited_roles


class Clock:
    def __call__(self):return time.time()


class GateFiles:
    def __init__(self,root):
        self.root=Path(root);self.exe=self.root/'worker.exe';self.exe.write_bytes(b'FAKE-NEVER-EXECUTED')
        p=plan();p['stub_cidrs']=json.loads((WORKER.parent/'ingress-policy.json').read_bytes())['outboundCIDRs']
        context={k:p[k] for k in ('attempt','kind','subscription','group','operator_cidr','stub_cidrs','disposition')}
        self.plan=candidate_plan(context)
        pins={str((WORKER.parent/n).resolve()):h for n,h in source_hashes().items()}
        pins[str(self.exe.resolve())]=hashlib.sha256(self.exe.read_bytes()).hexdigest()
        self.packet={'schema':'m21-live-decision@1','plan':self.plan,'tenant':'22222222-2222-2222-2222-222222222222',
            'operator':'operator@example.invalid','runtimePins':pins,'workerPython':str(self.exe.resolve()),
            'workerFile':str(WORKER),'ingressComplete':True,'incrementalEnvelopeUSD':3,'recoveryOperator':'Nathan','kind':'normal',
            'operatorObjectId':'33333333-3333-3333-3333-333333333333','inheritedRoleBaseline':[]}
        self.paths=[str(self.root/(n+'.json')) for n in ('packet','decision','ready')]
        self.write(0,self.packet)
        self.decision={'approvedPacketSha256':self.sha(),'attempt':self.plan['attempt'],'approved':True,
            'dispositionApproved':True,'financialUnknownsAccepted':True,'userMessageId':'synthetic-approval'}
        self.ready={'attempt':self.plan['attempt'],'packetSha256':self.sha(),'phrase':"I'm ready",'recoveryOperator':'Nathan',
            'windowMinutes':120,'userMessageId':'synthetic-ready','materialChange':False}
        self.write(1,self.decision);self.write(2,self.ready)
    def write(self,n,value):Path(self.paths[n]).write_bytes(canonical(value))
    def sha(self):return hashlib.sha256(Path(self.paths[0]).read_bytes()).hexdigest()
    def authority(self):return Authority(*self.paths)
    def set_baseline(self,rows):
        self.packet['inheritedRoleBaseline']=copy.deepcopy(rows);self.write(0,self.packet)
        self.decision['approvedPacketSha256']=self.sha();self.write(1,self.decision)
        self.ready['packetSha256']=self.sha();self.write(2,self.ready)


class EventPipe:
    def __init__(self):self.event=threading.Event();self.data=None
    def set(self,data):self.data=io.BytesIO(data);self.event.set()
    def read(self,n):
        if not self.event.wait(3):raise RuntimeError('fake-pipe-timeout')
        return self.data.read(n)
    def close(self):pass


class FakeJob:
    def __init__(self,child):self.child=child;child.assigned=True
    def terminate(self):self.child.kill()
    def finish(self):return True


class FakeProcess:
    """Only injected HTTP and credential callback; no real process/auth/network."""
    def __init__(self,argv,provider,**kwargs):
        self.returncode=None;self.assigned=False;self.stdout=EventPipe();self.stderr=EventPipe();self.provider=provider
        owner=self
        class Input(io.BytesIO):
            def close(self):
                raw=self.getvalue()
                if not owner.assigned:raise RuntimeError('feed-before-job')
                try:
                    if int.from_bytes(raw[:4],'big')!=len(raw)-4:raise Refused('frame')
                    frame=json.loads(raw[4:])
                    if getattr(provider,'mutate_frame',None):frame=provider.mutate_frame(frame)
                    result=handle_frame(frame,profile_token=lambda a:'SYNTHETIC_TOKEN',
                        connection_factory=owner.provider.connection,expected_parent=os.getpid())
                    out=canonical(result);owner.stdout.set(len(out).to_bytes(4,'big')+out);owner.stderr.set(b'');owner.returncode=0
                except Exception:
                    owner.stdout.set(b'');owner.stderr.set(b'');owner.returncode=2
                super().close()
        self.stdin=Input()
    def poll(self):return self.returncode
    def wait(self,timeout=None):return self.returncode
    def kill(self):self.returncode=2;self.stdout.set(b'');self.stderr.set(b'')


class Provider:
    def __init__(self):self.routes={};self.sent=[]
    def connection(self,host,port,seconds):
        owner=self
        class C:
            def request(self,method,path,body,headers):
                owner.sent.append((method,host,path,headers.copy()));self.path=path
                if getattr(owner,'on_request',None):owner.on_request(method,path,body)
            def getresponse(self):
                row=owner.routes.get(self.path,(404,{'error':{'code':'NotFound'}}))
                status,value=row[:2]
                r=Response(canonical(value));r.status=status;r.headers=row[2] if len(row)>2 else [];return r
            def close(self):pass
        return C()


class NativeTests(unittest.TestCase):
    def test_gates_fail_before_worker(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);g.decision['approved']=False;g.write(1,g.decision)
            with self.assertRaises(Refused):g.authority()
            g.decision['approved']=True;g.write(1,g.decision);g.ready['materialChange']=True;g.write(2,g.ready)
            with self.assertRaises(Refused):g.authority()

    def test_ready_is_attempt_specific(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);g.ready['attempt']='b'*32;g.write(2,g.ready)
            with self.assertRaises(Refused):g.authority()

    def test_default_entry_never_authenticates(self):
        with patch('live_io.cached_arm_token',side_effect=AssertionError('auth')):
            with self.assertRaises(Refused):main()

    def test_runtime_drift_refused(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);g.exe.write_bytes(b'CHANGED')
            with self.assertRaises(Refused):g.authority()

    def test_worker_route_auth_and_callback_separation(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority();provider=Provider()
            c=NativeController(g.plan,Path(d)/'j',OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,provider,**kw),job_factory=FakeJob),Clock())
            try:
                c.call('group-read',allowed=(404,))
                self.assertEqual(provider.sent[-1][3]['Authorization'],'Bearer SYNTHETIC_TOKEN')
            finally:c.close();a.close()

    def test_wrong_parent_and_scope_refused_before_auth(self):
        with self.assertRaises(Refused):handle_frame({'paths':[],'request':{},'parentPid':0},lambda a:self.fail('auth'),expected_parent=1)
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority()
            try:
                for url in ('https://example.invalid/','https://management.azure.com/subscriptions/other?api-version=2022-12-01'):
                    with self.assertRaises(Refused):validate_route(a,{'method':'GET','url':url,'class':'arm','body':'','provenance':{}})
            finally:a.close()

    def test_real_controller_worker_framing_http_pipeline(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority();provider=Provider()
            t=OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,provider,**kw),job_factory=FakeJob)
            c=NativeController(g.plan,Path(d)/'journal',t,Clock())
            try:
                result=c.call('group-read',allowed=(404,))
                self.assertEqual(result['error']['code'],'NotFound');self.assertEqual(c.counts['normal'],1)
                with self.assertRaises(Refused):c.test_approve(digest(c.plan))
                self.assertEqual(Journal.inspect(c.journal.root/'events.jsonl')[0]['data']['mode'],'native-observation')
                ledger=(c.journal.root/'events.jsonl').read_text()
                self.assertNotIn('SYNTHETIC_TOKEN',ledger);self.assertNotIn('https://',ledger)
            finally:c.close();a.close()

    def test_collection_false_nextlink_is_incomplete(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority();provider=Provider()
            path='/subscriptions/'+g.plan['subscription']+'/resourceGroups/'+g.plan['group']+'/resources?api-version=2021-04-01'
            provider.routes[path]=(200,{'value':[],'nextLink':False})
            c=NativeController(g.plan,Path(d)/'j',OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,provider,**kw),job_factory=FakeJob),Clock())
            try:
                with self.assertRaises(Refused):c.collection('https://management.azure.com'+path)
            finally:c.close();a.close()

    def test_actual_projector_through_gates_frames_and_http(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);g.set_baseline(synthetic_inherited_roles(g.plan['subscription'],g.packet['tenant']))
            a=g.authority();provider=Provider()
            c=NativeController(g.plan,Path(d)/'j',OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,provider,**kw),job_factory=FakeJob),Clock())
            try:
                r,_=oracle_record();r['bindings']=context_bindings(g.plan)
                def iso(n):return datetime.fromtimestamp(n,timezone.utc).isoformat()
                def route(url,value,status=200,headers=None):provider.routes[urlsplit_path(url)]=(status,value,headers or [])
                def record(alias,run,start=0,end=10):
                    url=c.workflow_url(alias)+'/runs/'+run
                    v={'id':url.removeprefix('https://management.azure.com'),'name':run,'properties':{'status':'Succeeded','startTime':iso(start),'endTime':iso(end)}}
                    route(url+'?api-version=2019-05-01',v);return v
                def action(alias,run,name,outputs=None,inputs=None,status='Succeeded',start=0,end=1,rep=None):
                    url=c.workflow_url(alias)+'/runs/'+run+'/actions/'+name
                    cap=c._endpoints[alias]+'/runs/'+run+'/actions/'+name+'/'
                    if rep:url+='/repetitions/'+rep;cap+='repetitions/'+rep+'/'
                    v={'id':url.removeprefix('https://management.azure.com'),'name':rep or name,'properties':{'status':status,'startTime':iso(start),'endTime':iso(end)}}
                    for key,value in (('inputs',inputs),('outputs',outputs)):
                        if value is not None:
                            uri=cap+'contents/Action'+key.title()+'?api-version=2016-10-01&sp=read&sv=1.0&sig=SYNTHETIC_CAPABILITY'
                            v['properties'][key+'Link']={'uri':uri};route(uri,value)
                    route(url+'?api-version=2019-05-01',v)
                for alias in c.plan['bodies']:
                    c._endpoints[alias]='https://prod-00.westus2.logic.azure.com/workflows/id-'+alias
                    value=copy.deepcopy(c.plan['bodies'][alias]);value.update({'id':c.workflow_url(alias).removeprefix('https://management.azure.com'),'name':'m21-'+alias})
                    value['properties'].update({'provisioningState':'Succeeded','accessEndpoint':c._endpoints[alias]})
                    route(c.workflow_url(alias)+'?api-version=2019-05-01',value)
                for alias,run in [('receiver-duplicate',r['receivers'][0]['run']),('receiver-mismatch',r['receivers'][1]['run']),('lifecycle-create','parent-1')]:
                    cap=c._endpoints[alias]+'/triggers/When_a_HTTP_request_is_received/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2FWhen_a_HTTP_request_is_received%2Frun&sv=1.0&sig=SYNTHETIC_CAPABILITY'
                    c._capabilities[alias]=cap
                    route(cap,{},202,[('x-ms-workflow-run-id',run)])
                record('lifecycle-create','parent-1')
                for i,kind in enumerate(('list','create')):
                    action('lifecycle-create','parent-1','Observe_'+kind+'_intent',r['parent']['intents'][i])
                    p=r['parent']['actions'][i];action('lifecycle-create','parent-1',p['name'],start=p['start'],end=p['end'])
                complete={k:v for k,v in r['complete'].items() if k!='status'}
                action('lifecycle-create','parent-1','Observe_create_branch_complete',complete)
                rows=[]
                for s in r['stubs']:
                    kind='list' if s['event']['parentAction']=='List_subscriptions' else 'create';run=s['run']
                    rows.append(record('response-stub',run,s['start'],s['end']))
                    action('response-stub',run,'Observe_'+kind,s['event'])
                    action('response-stub',run,'Observe_'+('create' if kind=='list' else 'list'),status='Skipped')
                    action('response-stub',run,'Respond_'+kind,inputs={'statusCode':s['response']['statusCode'],'body':s['response']['body']},end=s['end'])
                route(c.workflow_url('response-stub')+'/runs?api-version=2019-05-01',{'value':rows})
                for rr in r['receivers']:
                    alias,run=rr['case'],rr['run'];record(alias,run)
                    action(alias,run,'Select_notifications',{'body':[{'valid':v,'alertId':aid} for v,aid in zip(rr['selectedValid'],rr['alertIds'])]})
                    route(c.workflow_url(alias)+'/runs/'+run+'/actions/For_each_notification/scopeRepetitions?api-version=2019-05-01',{'value':[{'name':'000000'}]})
                    action(alias,run,'Check_notification',{'expressionResult':rr['checkNotificationResult']},rep='000000')
                    action(alias,run,'Post_message_in_a_chat_or_channel',outputs=rr['deliveryOutputs'][0] if rr['deliveryOutputs'] else None,status=rr['deliveryStatuses'][0],rep='000000')
                group=c.group_url;scope=group.removeprefix('https://management.azure.com')
                absent={'error':{'code':'ResourceGroupNotFound','message':"Resource group '"+g.plan['group']+"' could not be found."}}
                route('https://management.azure.com/subscriptions/'+g.plan['subscription']+'?api-version=2022-12-01',{'subscriptionId':g.plan['subscription'],'tenantId':g.packet['tenant'],'state':'Enabled'})
                route(group+'?api-version=2022-09-01',absent,404)
                for alias in c.plan['bodies']:
                    cap=c._endpoints[alias]+'/triggers/When_a_HTTP_request_is_received/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2FWhen_a_HTTP_request_is_received%2Frun&sv=1.0&sig=SYNTHETIC_CAPABILITY'
                    route(c.workflow_url(alias)+'/triggers/When_a_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01',{'value':cap})
                    route(c.workflow_url(alias)+'/enable?api-version=2019-05-01',{})
                def create(method,path,body):
                    if method=='PUT' and path==urlsplit_path(group+'?api-version=2022-09-01'):
                        p={'id':scope,**json.loads(body)};provider.routes[path]=(201,p)
                    for alias in c.plan['bodies']:
                        workflow=c.workflow_url(alias)
                        if method=='PUT' and path==urlsplit_path(workflow+'?api-version=2019-05-01'):
                            value=json.loads(body);value.update({'id':workflow.removeprefix('https://management.azure.com'),'name':'m21-'+alias})
                            value['properties'].update({'accessEndpoint':'https://prod-00.westus2.logic.azure.com/workflows/id-'+alias,'provisioningState':'Succeeded'})
                            provider.routes[path]=(200,value)
                        if method=='POST' and path==urlsplit_path(workflow+'/enable?api-version=2019-05-01'):
                            provider.routes[urlsplit_path(workflow+'?api-version=2019-05-01')][1]['properties']['state']='Enabled'
                provider.on_request=create;c._endpoints={};c._capabilities={};c._observed_configs={}
                result=c.start();self.assertTrue(result['functionObserved']);self.assertFalse(result['nativeQualified'])
                self.assertEqual(len(c.known_runs),5)
                # Removing actual response content must fail, never substitute the expected answer.
                key=next(k for k in provider.routes if '/Respond_list?' in k)
                provider.routes[key][1]['properties'].pop('inputsLink')
                with self.assertRaises(Refused):c.project()
                ledger=(c.journal.root/'events.jsonl').read_text()
                self.assertNotIn('SYNTHETIC_CAPABILITY',ledger);self.assertNotIn('SYNTHETIC_TOKEN',ledger)
                self.assertTrue(any(host.endswith('.logic.azure.com') and 'Authorization' not in h for m,host,p,h in provider.sent))
                # Complete the same actual start/project pipeline with recovery.
                resources=[{'id':c.workflow_url(a).removeprefix('https://management.azure.com'),'type':'Microsoft.Logic/workflows',
                    'properties':{'providerExtra':'SYNTHETIC_NEVER_HASH_OR_PERSIST'}} for a in c.plan['bodies']]
                route(group+'?api-version=2022-09-01',{'id':scope,'location':'westus2','tags':{'attempt':g.plan['attempt']}})
                route(group+'/resources?api-version=2021-04-01',{'value':resources})
                role_url=group+'/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
                role_page2=role_url+'&$skipToken=fixture-page-2'
                route(role_url,{'value':copy.deepcopy(g.packet['inheritedRoleBaseline'][:11]),'nextLink':role_page2})
                route(role_page2,{'value':copy.deepcopy(g.packet['inheritedRoleBaseline'][11:])})
                route('https://management.azure.com/subscriptions/'+g.plan['subscription']+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01',{'value':[]})
                for alias in c.plan['bodies']:
                    rows=[provider.routes[urlsplit_path(c.workflow_url(alias)+'/runs/'+run+'?api-version=2019-05-01')][1] for a,run in c.known_runs if a==alias]
                    route(c.workflow_url(alias)+'/runs?api-version=2019-05-01',{'value':rows})
                    route(c.workflow_url(alias)+'/disable?api-version=2019-05-01',{})
                deleted=[False]
                def cleanup(method,path,body):
                    if method=='POST':
                        for alias in c.plan['bodies']:
                            if path==urlsplit_path(c.workflow_url(alias)+'/disable?api-version=2019-05-01'):
                                provider.routes[urlsplit_path(c.workflow_url(alias)+'?api-version=2019-05-01')][1]['properties']['state']='Disabled'
                    if method=='DELETE':
                        deleted[0]=True;route(group+'?api-version=2022-09-01',{},202)
                    if method=='GET' and deleted[0]:
                        if path==urlsplit_path(group+'?api-version=2022-09-01'):route(group+'?api-version=2022-09-01',absent,404)
                        for alias in c.plan['bodies']:
                            if path==urlsplit_path(c.workflow_url(alias)+'?api-version=2019-05-01'):route(c.workflow_url(alias)+'?api-version=2019-05-01',absent,404)
                provider.on_request=cleanup
                def safe_digest(value):
                    self.assertNotIn('SYNTHETIC_NEVER_HASH_OR_PERSIST',canonical(value).decode())
                    return digest(value)
                with patch('native.digest',safe_digest):disposed=c.recover()
                self.assertTrue(disposed['disposalObserved']);self.assertTrue(disposed['absenceObserved'])
                self.assertFalse(disposed['deleteOperationSucceeded'])
                self.assertEqual(sum(m=='GET' and '/roleAssignments?' in path for m,h,path,headers in provider.sent),4)
            finally:c.close();a.close()

    def test_selected_token_claims(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority()
            try:
                claims={'tid':a.packet['tenant'],'oid':a.packet['operatorObjectId'],'aud':'https://management.azure.com/',
                    'exp':int(time.time())+600,'nbf':int(time.time())-60}
                def token(c):return 'synthetic.'+base64.urlsafe_b64encode(canonical(c)).decode().rstrip('=')+'.synthetic'
                validate_token_claims(token(claims),a)
                for key,value in [('tid','other'),('oid','other'),('aud','https://graph.microsoft.com/'),('exp',0)]:
                    changed={**claims,key:value}
                    with self.assertRaises(Refused):validate_token_claims(token(changed),a)
            finally:a.close()

    def test_exact_worker_body_authority_and_phase(self):
        def badbody(f):f['request']['body']=base64.b64encode(b'{"location":"elsewhere"}').decode();return f
        def badauthority(f):f['bindings']['authority'][0]='0'*64;return f
        def badphase(f):f['context']['phase']='recovery';return f
        def badoperation(f):
            f['context']['operation']='delete';f['request']['method']='DELETE';f['request']['body']='';return f
        for mutate in (badbody,badauthority,badphase,badoperation):
            with self.subTest(mutate=mutate.__name__),tempfile.TemporaryDirectory() as d:
                g=GateFiles(d);a=g.authority();p=Provider();p.mutate_frame=mutate
                c=NativeController(g.plan,Path(d)/'j',OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,p,**kw),job_factory=FakeJob),Clock())
                try:
                    with self.assertRaises(Refused):c.call('group-read',allowed=(404,)) if mutate is badoperation else c.call('group-create',allowed=(201,))
                    self.assertEqual(p.sent,[])
                    self.assertEqual(c.counts['normal'],1)
                finally:c.close();a.close()

    def test_recovery_resume_and_synchronous_delete_observation(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority();p=Provider()
            def transport():return OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,p,**kw),job_factory=FakeJob)
            c=NativeController(g.plan,Path(d)/'j',transport(),Clock())
            group=c.group_url;sid=g.plan['subscription'];scope=group.removeprefix('https://management.azure.com')
            p.routes[urlsplit_path(group+'?api-version=2022-09-01')]=(201,{'id':scope,'location':'westus2','tags':{'attempt':g.plan['attempt']}})
            c.call('group-create',allowed=(201,))
            p.routes[urlsplit_path(group+'?api-version=2022-09-01')]=(200,{'id':scope,'location':'westus2','tags':{'attempt':g.plan['attempt']}})
            p.routes['/subscriptions/'+sid+'?api-version=2022-12-01']=(200,{'subscriptionId':sid,'tenantId':g.packet['tenant'],'state':'Enabled'})
            p.routes['/subscriptions/'+sid+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01']=(200,{'value':[]})
            resources=[]
            for alias in c.plan['bodies']:
                url=c.workflow_url(alias);rid=url.removeprefix('https://management.azure.com')
                resources.append({'id':rid,'type':'Microsoft.Logic/workflows'})
                value=copy.deepcopy(c.plan['bodies'][alias]);value.update({'id':rid,'name':'m21-'+alias})
                value['properties'].update({'provisioningState':'Succeeded','accessEndpoint':'https://prod-00.westus2.logic.azure.com/workflows/id-'+alias})
                p.routes[urlsplit_path(url+'?api-version=2019-05-01')]=(200,value)
                p.routes[urlsplit_path(url+'/disable?api-version=2019-05-01')]=(200,{})
                p.routes[urlsplit_path(url+'/runs?api-version=2019-05-01')]=(200,{'value':[]})
            p.routes[urlsplit_path(group+'/resources?api-version=2021-04-01')]=(200,{'value':resources})
            p.routes[urlsplit_path(group+'/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01')]=(200,{'value':[]})
            # Deliberate interruption after the first acknowledged disable.
            c.once_recovery('disable','receiver-duplicate');c.close()
            c=NativeController(g.plan,Path(d)/'j',transport(),Clock(),recovery=True)
            lockpath='/subscriptions/'+sid+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01'
            for parent in ('/subscriptions/'+sid,scope,scope+'/providers/Microsoft.Logic/workflows/m21-receiver-duplicate'):
                p.routes[lockpath]=(200,{'value':[{'id':(parent+'/providers/Microsoft.Authorization/locks/guard').upper(),
                    'name':'guard','type':'Microsoft.Authorization/locks','properties':{'level':'ReadOnly'}}]})
                with self.assertRaisesRegex(Refused,'relevant-lock-preserve'):c.recover()
                self.assertEqual(sum(m=='DELETE' for m,h,pth,hs in p.sent),0)
            p.routes[lockpath]=(200,{'value':[{'id':parent+'/providers/Microsoft.Authorization/locks/guard',
                'name':'guard','type':'Microsoft.Authorization/locks','properties':{'level':'ReadOnly'}}
                for parent in (scope+'-unrelated','/subscriptions/'+sid+'/resourceGroups/other')]})
            def delete(method,path,body):
                if method=='DELETE':
                    absent={'error':{'code':'ResourceGroupNotFound','message':"Resource group '"+g.plan['group']+"' could not be found."}}
                    p.routes[urlsplit_path(group+'?api-version=2022-09-01')]=(404,absent)
                    for alias in c.plan['bodies']:p.routes[urlsplit_path(c.workflow_url(alias)+'?api-version=2019-05-01')]=(404,absent)
            p.on_request=delete
            # DELETE itself returns 404 after the hook: this is a refused result,
            # so absence can be observed but disposal must remain unqualified.
            try:
                result=c.recover();self.assertTrue(result['absenceObserved']);self.assertFalse(result['disposalObserved'])
                self.assertEqual(sum(m=='DELETE' for m,h,pth,hs in p.sent),1)
                self.assertEqual(sum(m=='POST' and '/m21-receiver-duplicate/disable?' in pth for m,h,pth,hs in p.sent),1)
            finally:c.close()
            c=NativeController(g.plan,Path(d)/'j',transport(),Clock(),recovery=True)
            try:
                again=c.recover();self.assertTrue(again['absenceObserved'])
                self.assertEqual(sum(m=='DELETE' for m,h,pth,hs in p.sent),1)
            finally:c.close();a.close()

    def test_untyped_or_wrong_target_404_refused(self):
        for value in ({},{'error':{'code':'NotFound','message':'wrong'}},{'error':{'code':'ResourceGroupNotFound','message':'other'}}):
            with self.assertRaises(Refused):qualified_absence(value,'expected-group')
        for name in ('expected-group-other','other-expected-group'):
            with self.assertRaises(Refused):qualified_absence({'error':{'code':'ResourceGroupNotFound','message':"Resource group '"+name+"' not found"}},'expected-group')
        for name in ('m21-receiver-duplicate-other','other-m21-receiver-duplicate'):
            with self.assertRaises(Refused):qualified_absence({'error':{'code':'WorkflowNotFound','message':"Resource group 'expected-group', workflow '"+name+"' not found"}},'expected-group','receiver-duplicate')

    def test_worker_bootstrap_and_main_without_auth_or_network(self):
        with tempfile.TemporaryDirectory() as d:
            g=GateFiles(d);a=g.authority();p=Provider()
            c=NativeController(g.plan,Path(d)/'j',OwnedTransport(a,popen=lambda argv,**kw:FakeProcess(argv,p,**kw),job_factory=FakeJob),Clock())
            try:
                identity='group-read:group:none:'+str(len(c.journal.events))
                c.append('intent',{'id':identity,'phase':'normal','workload':{'triggers':0,'actions':0,'bytes':0},'at':time.time()})
                frame={'paths':g.paths,'parentPid':os.getppid(),'bindings':{'authority':[a.packet_hash,a.decision_hash,a.ready_hash],
                    'attempt':g.plan['attempt'],'plan':digest(g.plan)},
                    'context':{'ledger':str(c.journal.root/'events.jsonl'),'intent':identity,'operation':'group-read','alias':None,'run':None,'phase':'normal'},
                    'request':{'method':'GET','url':c.group_url+'?api-version=2022-09-01','body':'','class':'arm','provenance':{'kind':'fixed-catalog'}}}
                holds=bootstrap(frame)
                for s in holds:s.close()
                raw=canonical(frame);out=io.BytesIO()
                original=handle_frame
                def injected(f):return original(f,lambda a:'SYNTHETIC_TOKEN',p.connection)
                with patch('sys.stdin',SimpleNamespace(buffer=io.BytesIO(len(raw).to_bytes(4,'big')+raw))),patch('sys.stdout',SimpleNamespace(buffer=out)),patch('live_io.handle_frame',injected):
                    self.assertEqual(worker_main(),0)
                framed=out.getvalue();self.assertEqual(int.from_bytes(framed[:4],'big'),len(framed)-4)
                self.assertEqual(json.loads(framed[4:])['status'],404)
                frame['bindings']['authority'][0]='0'*64
                with self.assertRaises(RuntimeError):bootstrap(frame)
            finally:c.close();a.close()

    @unittest.skipUnless(os.name=='nt','Windows owned process tree')
    def test_real_windows_owned_job_with_inert_child(self):
        # This child only waits for one stdin byte then exits; no SDK/auth/HTTP.
        child=subprocess.Popen([sys.executable,'-I','-B','-c','import sys; sys.stdin.buffer.read(1)'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW)
        job=None
        try:
            job=WindowsJob(child);child.stdin.write(b'x');child.stdin.close();child.wait(timeout=3)
            self.assertTrue(job.finish());job=None
        finally:
            if job:job.terminate();job.finish()
            if child.poll() is None:child.kill();child.wait(timeout=2)
            for stream in (child.stdin,child.stdout,child.stderr):stream.close()

    def test_local_proposals_leave_missing_ingress_and_authority_blocked(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);g=GateFiles(d)
            context={'subscription':g.plan['subscription'],'tenant':g.packet['tenant'],'operator':g.packet['operator'],
                'operator_cidr':None,'normalAttempt':'a'*32,'lateAttempt':'b'*32,'stub_cidrs':None}
            actor={'target':{'subscriptionId':context['subscription'],'tenantId':context['tenant'],'expectedUser':context['operator'],'operatorObjectId':g.packet['operatorObjectId']}}
            for name,value in (('context',context),('actor',actor),('roles',{'value':[]})):(root/(name+'.json')).write_bytes(canonical(value))
            scope='/subscriptions/'+context['subscription']
            (root/'roles.json').write_bytes(canonical({'value':[{'id':'inherited','properties':{'scope':scope}},
                {'id':'root','properties':{'scope':'/'}},
                {'id':'tenant-root','properties':{'scope':'/providers/Microsoft.Management/managementGroups/'+context['tenant']}},
                {'id':'other-cell','properties':{'scope':scope+'/resourceGroups/existing-other-cell'}}]}))
            cli=root/'cli';cli.mkdir()
            for name in ('python.exe','python314.dll','python314.zip','python314._pth'):(cli/name).write_bytes(b'SYNTHETIC-NOT-EXECUTED')
            with self.assertRaisesRegex(ValueError,'SDK file missing'):prepare(root/'context.json',root/'actor.json',root/'roles.json',cli,root/'missing-sdk')
            out=prepare(root/'context.json',root/'actor.json',root/'roles.json',cli,root/'out',synthetic_fixture=True)
            normal=json.loads((out/'normal-proposal.json').read_bytes());late=json.loads((out/'late-proposal.json').read_bytes())
            self.assertFalse(normal['ingressComplete']);self.assertNotEqual(normal['plan']['attempt'],late['plan']['attempt'])
            self.assertFalse(json.loads((out/'preparation.json').read_bytes())['approvalFilesCreated'])
            self.assertEqual(len(normal['inheritedRoleBaseline']),3)
            self.assertEqual(json.loads((out/'preparation.json').read_bytes())['outsideProposedCells'],['other-cell'])
            (root/'roles.json').write_bytes(canonical({'value':[{'id':'unexpected','properties':{'scope':scope+'/resourceGroups/'+normal['plan']['group']}}]}))
            with self.assertRaisesRegex(ValueError,'proposed-cell'):prepare(root/'context.json',root/'actor.json',root/'roles.json',cli,root/'bad-roles',synthetic_fixture=True)
            for malformed in ('','/subscriptions',scope+'/resourceGroups/',scope+'/resourceGroups/.',
                    scope+'/resourceGroups/..',scope+'/resourceGroups/other/../cell',scope+'/resourceGroups/%2fother',
                    scope+'/resourceGroups/other?query',scope+'/resourceGroups/other#fragment',scope+'/resourceGroups/other/providers/Microsoft.Storage/storageAccounts',
                    '/providers/Microsoft.Management/managementGroups/unrelated'):
                (root/'roles.json').write_bytes(canonical({'value':[{'id':'bad','properties':{'scope':malformed}}]}))
                with self.subTest(scope=malformed),self.assertRaises(ValueError):prepare(root/'context.json',root/'actor.json',root/'roles.json',cli,root/'malformed-roles',synthetic_fixture=True)


def urlsplit_path(url):
    from urllib.parse import urlsplit
    u=urlsplit(url);return u.path+('?' + u.query if u.query else '')


if __name__=='__main__':unittest.main()
