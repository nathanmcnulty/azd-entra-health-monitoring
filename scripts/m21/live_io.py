"""Approval-gated, single-request owned worker. Default entry never authenticates.

Request/response capabilities travel only over bounded anonymous pipes. The ARM
credential remains inside the owned worker. No token is serialized or exported.
"""
import base64
import contextlib
import hashlib
import io
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit, parse_qsl
sys.path.insert(0,str(Path(__file__).resolve().parent))
if sys.argv[1:]!=['--owned-worker']:
    from control import Refused, canonical, digest, strict_json, freeze_plan, one_shot

MAX_FRAME = 2097152
WORKER = Path(__file__).resolve()


def held_read(path):
    """Windows deny-write/delete hold; caller retains handle for the attempt."""
    if os.name!='nt':return Path(path).open('rb')
    import ctypes as c
    from ctypes import wintypes as w
    import msvcrt
    k=c.WinDLL('kernel32',use_last_error=True)
    k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,c.c_void_p,w.DWORD,w.DWORD,w.HANDLE]
    k.CreateFileW.restype=w.HANDLE
    h=k.CreateFileW(str(Path(path).resolve()),0x80000000,1,None,3,0x80,None)
    if h==c.c_void_p(-1).value:raise OSError('pinned-file-unavailable')
    return os.fdopen(msvcrt.open_osfhandle(h,os.O_RDONLY|os.O_BINARY),'rb')


def bootstrap(frame):
    """Before importing executable project modules in the worker.

    Hostile same-identity replacement of this bootstrap itself is outside the
    trusted local supervisor boundary. Exact source transport verifies it first.
    """
    holds=[]
    try:
        records=[]
        for path,expected in zip(frame['paths'],frame['bindings']['authority']):
            s=held_read(path);holds.append(s);raw=s.read(1048577)
            if len(raw)>1048576 or hashlib.sha256(raw).hexdigest()!=expected:raise ValueError()
            records.append(json.loads(raw))
        pins=records[0]['runtimePins']
        required=[str(WORKER),str(WORKER.parent/'control.py'),str(WORKER.parent/'build_fixture.py'),str(WORKER.parent/'native.py'),str(WORKER.parent/'oracle.py'),str(WORKER.parent/'ingress-policy.json')]
        if any(p not in pins for p in required):raise ValueError()
        for path,expected in pins.items():
            s=held_read(path);holds.append(s)
            if hashlib.file_digest(s,'sha256').hexdigest()!=expected:raise ValueError()
        return holds
    except Exception:
        for s in holds:s.close()
        raise RuntimeError('bootstrap-binding-refused') from None


class WindowsJob:
    """Owned worker tree; assignment precedes feeding the first request byte."""
    def __init__(self, child):
        if os.name != 'nt':raise Refused('windows-owned-worker-required')
        import ctypes as c
        from ctypes import wintypes as w
        self.c=c;self.k=c.WinDLL('kernel32',use_last_error=True)
        class Basic(c.Structure):
            _fields_=[('user',c.c_int64),('kernel',c.c_int64),('flags',w.DWORD),
                ('minimum',c.c_size_t),('maximum',c.c_size_t),('active',w.DWORD),
                ('affinity',c.c_size_t),('priority',w.DWORD),('scheduling',w.DWORD)]
        class IO(c.Structure):
            _fields_=[(x,c.c_uint64) for x in ('read','write','other','readBytes','writeBytes','otherBytes')]
        class Extended(c.Structure):
            _fields_=[('basic',Basic),('io',IO),('processMemory',c.c_size_t),
                ('jobMemory',c.c_size_t),('peakProcess',c.c_size_t),('peakJob',c.c_size_t)]
        class Accounting(c.Structure):
            _fields_=[('user',c.c_int64),('kernel',c.c_int64),('periodUser',c.c_int64),
                ('periodKernel',c.c_int64),('faults',w.DWORD),('total',w.DWORD),
                ('active',w.DWORD),('terminated',w.DWORD)]
        self.Accounting=Accounting
        for name,args,result in (
            ('CreateJobObjectW',[c.c_void_p,w.LPCWSTR],w.HANDLE),
            ('SetInformationJobObject',[w.HANDLE,c.c_int,c.c_void_p,w.DWORD],w.BOOL),
            ('AssignProcessToJobObject',[w.HANDLE,w.HANDLE],w.BOOL),
            ('QueryInformationJobObject',[w.HANDLE,c.c_int,c.c_void_p,w.DWORD,c.c_void_p],w.BOOL),
            ('TerminateJobObject',[w.HANDLE,w.UINT],w.BOOL),('CloseHandle',[w.HANDLE],w.BOOL)):
            f=getattr(self.k,name);f.argtypes=args;f.restype=result
        self.handle=self.k.CreateJobObjectW(None,None)
        limits=Extended();limits.basic.flags=0x2000
        if (not self.handle or not self.k.SetInformationJobObject(self.handle,9,c.byref(limits),c.sizeof(limits))
                or not self.k.AssignProcessToJobObject(self.handle,int(child._handle))):
            if self.handle:self.k.CloseHandle(self.handle)
            raise Refused('owned-job-assignment')

    def terminate(self):
        if self.handle:self.k.TerminateJobObject(self.handle,2)

    def finish(self):
        if not self.handle:return False
        # Closing kills descendants; verify locally before releasing the handle.
        self.terminate();deadline=time.monotonic()+2;verified=False
        while time.monotonic()<deadline:
            info=self.Accounting()
            if not self.k.QueryInformationJobObject(self.handle,1,self.c.byref(info),self.c.sizeof(info),None):break
            if info.active==0:verified=True;break
            time.sleep(.01)
        self.k.CloseHandle(self.handle);self.handle=None
        return verified


def read_object(path, limit=1048576):
    path = Path(path)
    if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
        raise Refused('approval-link')
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise Refused('approval-bound')
    value = strict_json(raw)
    if type(value) is not dict:
        raise Refused('approval-object')
    return value, hashlib.sha256(raw).hexdigest()


class Authority:
    """Trusted local human-decision records; not cryptographic human identity.

    Agent policy must only create these after actual action approval/readiness.
    Same-identity hostile code/file fabrication is outside this local boundary.
    """
    def __init__(self, packet_path, decision_path, ready_path, recovery=False):
        self.paths = [str(Path(p).resolve()) for p in (packet_path, decision_path, ready_path)]
        packet, packet_hash = read_object(packet_path)
        decision, decision_hash = read_object(decision_path, 65536)
        ready, ready_hash = read_object(ready_path, 65536)
        required = {'schema','plan','tenant','operator','runtimePins','workerPython','workerFile',
                    'ingressComplete','incrementalEnvelopeUSD','recoveryOperator','kind','operatorObjectId','inheritedRoleBaseline'}
        if set(packet) != required or packet['schema'] != 'm21-live-decision@1':
            raise Refused('exact-live-packet')
        self.plan = packet['plan']
        if (packet['kind'] != self.plan['kind'] or packet['ingressComplete'] is not True
                or self.plan['operator_cidr'] is None or not self.plan['stub_cidrs']
                or packet['incrementalEnvelopeUSD'] != 3):
            raise Refused('unresolved-live-packet')
        if set(decision) != {'approvedPacketSha256','attempt','approved','dispositionApproved',
                            'financialUnknownsAccepted','userMessageId'}:
            raise Refused('closed-action-decision')
        if (decision['approvedPacketSha256'] != packet_hash or decision['attempt'] != self.plan['attempt']
                or any(decision[k] is not True for k in ('approved','dispositionApproved','financialUnknownsAccepted'))
                or not safe_id(decision['userMessageId'])):
            raise Refused('live-approval-required')
        if set(ready) != {'attempt','packetSha256','phrase','recoveryOperator','windowMinutes','userMessageId','materialChange'}:
            raise Refused('closed-readiness')
        if (ready['attempt'] != self.plan['attempt'] or ready['packetSha256'] != packet_hash
                or ready['phrase'] != "I'm ready" or ready['windowMinutes'] != 120
                or ready['recoveryOperator'] != packet['recoveryOperator']
                or ready['materialChange'] is not False or not safe_id(ready['userMessageId'])):
            raise Refused('waiting-for-Nathan-ready')
        if type(packet['tenant']) is not str or not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', packet['tenant']):
            raise Refused('tenant-binding')
        if type(packet['operator']) is not str or not re.fullmatch(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+',packet['operator']):
            raise Refused('operator-binding')
        if not re.fullmatch('[a-f0-9-]{36}',packet['operatorObjectId']) or type(packet['inheritedRoleBaseline']) is not list:raise Refused('actor-role-baseline')
        if type(packet['runtimePins']) is not dict or not packet['runtimePins']:
            raise Refused('runtime-pins')
        self.holds = []
        try:
            for path,expected in zip(self.paths,(packet_hash,decision_hash,ready_hash)):
                stream=held_read(path);self.holds.append(stream)
                if hashlib.file_digest(stream,'sha256').hexdigest()!=expected:raise Refused('authority-race')
            for name, expected in packet['runtimePins'].items():
                f = Path(name)
                if f.is_symlink() or not re.fullmatch('[a-f0-9]{64}', expected):
                    raise Refused('runtime-pin-shape')
                stream = held_read(f); self.holds.append(stream)
                if hashlib.file_digest(stream,'sha256').hexdigest() != expected:
                    raise Refused('runtime-drift')
            for path in (str(WORKER),packet['workerPython'],packet['workerFile']):
                if str(Path(path).resolve()) not in packet['runtimePins']:
                    raise Refused('unheld-worker-path')
            if Path(packet['workerFile']).resolve() != WORKER:
                raise Refused('worker-source-binding')
            for name, expected in self.plan['source_hashes'].items():
                path=str((WORKER.parent/name).resolve())
                if packet['runtimePins'].get(path)!=expected:
                    raise Refused('runtime-source-closure')
            required={'build_fixture.py','control.py','oracle.py','native.py','live_io.py','ingress-policy.json'}
            if set(self.plan['source_hashes'])!=required:raise Refused('source-closure')
            self.plan=freeze_plan(self.plan)
            ingress,_=read_object(WORKER.parent/'ingress-policy.json')
            if self.plan['stub_cidrs']!=ingress['outboundCIDRs']:raise Refused('regional-ingress-binding')
        except Exception:
            self.close(); raise
        self.packet, self.packet_hash = packet, packet_hash
        self.decision_hash, self.ready_hash = decision_hash, ready_hash
        self.recovery = recovery
        self.authorized = True

    def close(self):
        for stream in getattr(self,'holds',[]): stream.close()
        self.holds = []


def safe_id(value):
    return type(value) is str and bool(re.fullmatch(r'[A-Za-z0-9_:.\[\]-]{1,160}',value))


def validate_delete_monitor(plan, url):
    """Nonsecret ARM monitor policy, independent of the initiating DELETE API.

    Only a response-selected, durably recorded URL may subsequently be polled.
    New provider routes/versions require a source-policy review, not guessing.
    """
    if (type(url) is not str or len(url)>16384 or re.search(r'[\x00-\x20\x7f%\\]',url)):
        raise Refused('delete-monitor-url')
    u=urlsplit(url)
    if u.scheme!='https' or u.netloc!='management.azure.com' or u.fragment:
        raise Refused('delete-monitor-origin')
    prefix='/subscriptions/'+re.escape(plan['subscription'])
    regional=prefix+r'/providers/Microsoft.Resources/locations/westus2/(operationresults|operationStatuses)/[A-Za-z0-9-]{1,128}'
    subscription=prefix+r'/operationresults/[A-Za-z0-9-]{1,128}'
    if not (re.fullmatch(regional,u.path,re.IGNORECASE) or re.fullmatch(subscription,u.path,re.IGNORECASE)):
        raise Refused('delete-monitor-scope')
    try:pairs=parse_qsl(u.query,keep_blank_values=True,strict_parsing=True)
    except ValueError:raise Refused('delete-monitor-query') from None
    q=dict(pairs)
    if (len({k.casefold() for k,v in pairs})!=len(pairs) or set(q)-{'api-version','monitor'}
            or q.get('api-version') not in {'2018-08-01','2020-10-01','2021-04-01','2022-09-01'}
            or ('monitor' in q and q['monitor']!='true')):
        raise Refused('delete-monitor-query')
    return url


def select_delete_monitor(plan, headers):
    # Presence, not truthiness: a malformed preferred header cannot fall back.
    if 'azure-asyncoperation' in headers:kind='async';url=headers['azure-asyncoperation']
    elif 'location' in headers:kind='location';url=headers['location']
    else:return {'kind':'none','url':None,'retryAfter':monitor_retry_after(headers)}
    return {'kind':kind,'url':validate_delete_monitor(plan,url),'retryAfter':monitor_retry_after(headers)}


def monitor_retry_after(headers):
    value=headers.get('retry-after')
    if value is None:return 1
    if type(value) is not str or not re.fullmatch(r'[0-9]{1,2}',value) or int(value)>60:
        raise Refused('delete-monitor-retry-after')
    return int(value)


def validate_route(authority, request):
    if type(request) is not dict or set(request) != {'method','url','body','class','provenance'}:
        raise Refused('closed-worker-request')
    method, url, kind = request['method'], request['url'], request['class']
    if type(url) is not str or len(url)>16384 or re.search(r'%(?![0-9A-Fa-f]{2})',url):
        raise Refused('worker-url')
    u = urlsplit(url)
    if u.scheme!='https' or u.port not in (None,443) or u.username or u.password or u.fragment:
        raise Refused('https-only')
    p=authority.plan
    group='/subscriptions/'+p['subscription']+'/resourceGroups/'+p['group']
    if kind == 'arm':
        if u.hostname!='management.azure.com' or method not in ('GET','PUT','POST','DELETE'):
            raise Refused('arm-origin-method')
        if request['provenance'].get('kind')=='delete-operation':
            if method!='GET' or request['body']!='':raise Refused('delete-monitor-get-only')
            validate_delete_monitor(p,url)
            return b''
        pairs=parse_qsl(u.query,keep_blank_values=True,strict_parsing=True)
        if len({k.lower() for k,v in pairs})!=len(pairs):raise Refused('duplicate-query')
        query=dict(pairs)
        if 'api-version' not in query or set(query)-{'api-version','$skiptoken','$skipToken'}:
            raise Refused('arm-query')
        if u.path == '/subscriptions/'+p['subscription']:
            if method!='GET' or query!={'api-version':'2022-12-01'}:raise Refused('target-read')
        elif u.path=='/subscriptions/'+p['subscription']+'/providers/Microsoft.Authorization/locks':
            if method!='GET' or query['api-version']!='2016-09-01':raise Refused('ancestor-lock-read')
        elif u.path.startswith(group+'/providers/Microsoft.Logic/workflows/m21-'):
            tail=u.path[len(group+'/providers/Microsoft.Logic/workflows/m21-'):]
            parts=tail.split('/')
            from control import ALIASES, RUN
            if parts[0] not in ALIASES or query['api-version']!='2019-05-01':raise Refused('workflow-route')
            route='/'.join(parts[1:])
            fixed={'':{'GET','PUT'},'enable':{'POST'},'disable':{'POST'},'runs':{'GET'},
                   'triggers/When_a_HTTP_request_is_received/listCallbackUrl':{'POST'}}
            if route in fixed:
                if method not in fixed[route]:raise Refused('workflow-method')
            elif len(parts)>=3 and parts[1]=='runs' and RUN.fullmatch(parts[2]):
                suffix=parts[3:]
                if method=='POST' and suffix!=['cancel']:raise Refused('run-post')
                if method not in ('GET','POST'):raise Refused('run-method')
                if suffix and suffix not in (['cancel'],['actions']):
                    if not (method=='GET' and len(suffix) in (2,3,4) and suffix[0]=='actions'
                            and re.fullmatch('[A-Za-z0-9_]{1,128}',suffix[1])
                            and (len(suffix)==2 or suffix[2] in ('repetitions','scopeRepetitions'))
                            and (len(suffix)<4 or re.fullmatch('[0-9]{6}',suffix[3]))):
                        raise Refused('action-route')
            else:raise Refused('workflow-scope')
        elif u.path == group or u.path in (group+'/resources',group+'/providers/Microsoft.Authorization/locks',group+'/providers/Microsoft.Authorization/roleAssignments'):
            versions={group:'2022-09-01',group+'/resources':'2021-04-01',group+'/providers/Microsoft.Authorization/locks':'2016-09-01',group+'/providers/Microsoft.Authorization/roleAssignments':'2022-04-01'}
            if query['api-version']!=versions[u.path] or (u.path!=group and method!='GET') or (u.path==group and method not in ('GET','PUT','DELETE')):
                raise Refused('group-route')
        else:raise Refused('arm-scope')
    elif kind in ('callback','content'):
        provenance=request['provenance']
        if type(provenance) is not dict or set(provenance)!={'kind','endpoint','alias','run','action'}:
            raise Refused('capability-provenance')
        from control import ALIASES
        if provenance['kind']!=kind or provenance['alias'] not in ALIASES:raise Refused('capability-alias')
        e=urlsplit(provenance['endpoint'])
        if (e.scheme!='https' or e.hostname!=u.hostname or not u.hostname.endswith('.logic.azure.com')
                or e.port not in (None,443) or e.username or e.password or e.query or e.fragment
                or not re.fullmatch('/workflows/[A-Za-z0-9-]{1,128}',e.path)):
            raise Refused('capability-origin')
        pairs=parse_qsl(u.query,keep_blank_values=True,strict_parsing=True)
        if len({k.lower() for k,v in pairs})!=len(pairs):raise Refused('capability-query')
        q=dict(pairs)
        if q.get('api-version')!='2016-10-01' or not q.get('sig') or set(q)-{'api-version','sp','sv','sig','se'}:
            raise Refused('capability-query')
        if kind=='callback':
            if method!='POST' or provenance['alias']=='response-stub' or q.get('sp')!='/triggers/When_a_HTTP_request_is_received/run' or u.path!=e.path+'/triggers/When_a_HTTP_request_is_received/paths/invoke':
                raise Refused('callback-route')
        else:
            run, action=provenance['run'],provenance['action']
            if not safe_id(run) or not re.fullmatch('[A-Za-z0-9_]{1,128}',action):raise Refused('content-context')
            prefix=e.path+'/runs/'+run+'/actions/'+action+'/'
            if (method!='GET' or not u.path.startswith(prefix)
                    or not re.fullmatch(r'(repetitions/[0-9]{6}/)?contents/Action(Inputs|Outputs)',u.path[len(prefix):])):
                raise Refused('content-route')
    else:raise Refused('request-class')
    raw=base64.b64decode(request['body'],validate=True)
    if len(raw)>1048576:raise Refused('request-body-bound')
    return raw


class Sink(io.TextIOBase):
    def write(self,value):return len(value)


def cached_arm_token(authority):
    # Imports and token renewal occur ONLY in the gated owned worker.
    from azure.cli.core._profile import Profile
    from azure.cli.core.auth.msal_credentials import UserCredential
    def no_interactive(*args,**kwargs):raise Refused('interactive-auth-refused')
    UserCredential._acquire_token_interactive=no_interactive
    import msal
    msal.PublicClientApplication.acquire_token_interactive=no_interactive
    msal.PublicClientApplication.acquire_token_by_device_flow=no_interactive
    msal.PublicClientApplication.initiate_device_flow=no_interactive
    profile=Profile()
    p=authority.packet; account=profile.get_subscription(authority.plan['subscription'])
    if (account.get('id')!=authority.plan['subscription'] or account.get('tenantId')!=p['tenant']
            or account.get('state')!='Enabled' or account.get('environmentName')!='AzureCloud'
            or account.get('user',{}).get('name','').lower()!=p['operator'].lower()
            or account.get('user',{}).get('type')!='user'):
        raise Refused('existing-context-mismatch')
    token,sub,tenant=profile.get_raw_token(resource='https://management.azure.com/',subscription=authority.plan['subscription'])
    if sub!=authority.plan['subscription'] or tenant!=p['tenant'] or token[0]!='Bearer':
        raise Refused('token-context-mismatch')
    validate_token_claims(token[1],authority)
    return token[1]


def validate_token_claims(token,authority):
    # Selection guard only; ARM verifies signature. Never persist/hash JWT data.
    try:
        part=token.split('.')[1]
        claims=strict_json(base64.urlsafe_b64decode(part+'='*((-len(part))%4)),65536)
        if (claims['tid']!=authority.packet['tenant'] or claims['oid']!=authority.packet['operatorObjectId']
                or claims['aud'] not in ('https://management.azure.com/','https://management.core.windows.net/')
                or type(claims['exp']) is not int or claims['exp']<time.time()+60
                or type(claims.get('nbf')) is not int or claims['nbf']>time.time()+60):raise ValueError()
    except Exception:raise Refused('selected-token-claims-refused') from None


def verify_dispatch(authority,frame):
    from control import Journal,Controller,ALIASES
    b=frame['bindings']
    if b!={'authority':[authority.packet_hash,authority.decision_hash,authority.ready_hash],
            'attempt':authority.plan['attempt'],'plan':digest(authority.plan)}:raise Refused('original-authority-binding')
    ctx=frame['context']
    if type(ctx) is not dict or set(ctx)!={'ledger','intent','operation','alias','run','phase'}:raise Refused('dispatch-context')
    events=Journal.inspect(ctx['ledger'])
    if events[0]['data']['mode']!='native-observation' or events[0]['data']['plan']!=b['plan'] or events[-1]['event']!='intent' or events[-1]['data']['id']!=ctx['intent'] or events[-1]['data']['phase']!=ctx['phase']:raise Refused('durable-intent-required')
    admission=[e['data'] for e in events if e['event']=='native-admission']
    if admission!=[{'packet':authority.packet_hash,'decision':authority.decision_hash,'ready':authority.ready_hash}]:raise Refused('admission-authority')
    op,alias,run,phase=ctx['operation'],ctx['alias'],ctx['run'],ctx['phase']
    identity=op+':'+(alias or 'group')+':'+(run or 'none')
    expected_identity=identity+(':'+str(events[-1]['seq']) if frame['request']['method']=='GET' else '')
    if ctx['intent']!=expected_identity:raise Refused('intent-operation-binding')
    if phase not in ('normal','recovery') or time.time()>=events[0]['data']['start']+(7200 if phase=='recovery' else 5400):raise Refused('immutable-worker-deadline')
    if phase=='recovery' and op not in {'group-read','inventory','locks','roles','run','actions','disable','cancel','delete','workflow-read','observation'}:raise Refused('recovery-no-new-spend')
    if op=='delete':
        gates=[e['data'] for e in events if e['event']=='native-recovery-gate']
        if phase!='recovery' or not gates or gates[-1]['disposition']!=authority.plan['disposition']:raise Refused('worker-disposal-gate')
    request=frame['request'];raw=validate_route(authority,request)
    catalog=object.__new__(Controller);catalog._plan=authority.plan
    known={(e['data']['alias'],e['data']['run']) for e in events if e['event'] in ('known-run','stub-run')}
    catalog._known_runs=known;catalog._capabilities={}
    observed={e['data']['alias']:e['data'] for e in events if e['event']=='workflow-observed'}
    if op in ('invoke','observation'):
        if op=='invoke':
            if request['class']!='callback' or request['method']!='POST' or alias not in ALIASES[:3] or raw!=canonical(authority.plan['inputs'][alias]):raise Refused('exact-invoke-body')
            acknowledged={e['data']['id'] for e in events if e['event']=='result' and e['data']['outcome']=='acknowledged'}
            if not ({'enable:'+a+':none' for a in ALIASES}|{'bind:lifecycle-create:none'}).issubset(acknowledged):raise Refused('prepared-fixture-required')
        elif request['method']!='GET' or raw:raise Refused('observation-get-only')
        if request['class'] in ('callback','content'):
            provenance=request['provenance']
            if provenance['alias']!=alias or alias not in observed or provenance['endpoint']!=observed[alias]['endpoint']:raise Refused('observed-endpoint-required')
            if request['class']=='content' and (alias,provenance['run']) not in known:raise Refused('known-content-run')
        elif request['class']=='arm':
            u=urlsplit(request['url'])
            if '/workflows/' in u.path:
                parts=u.path.split('/workflows/',1)[1].split('/')
                if alias not in ALIASES or parts[0]!='m21-'+alias:raise Refused('observation-alias')
                if len(parts)>2 and parts[1]=='runs' and (alias,parts[2]) not in known:raise Refused('observation-known-run')
            if request['provenance'].get('kind')=='delete-operation':
                operations=[e['data'] for e in events if e['event']=='delete-monitor']
                polls=[e['data'] for e in events if e['event']=='delete-monitor-poll']
                statuses=[e['data'] for e in events if e['event']=='delete-monitor-status']
                poll_events=[e for e in events if e['event']=='delete-monitor-poll']
                if (len(operations)!=1 or operations[0]['url']!=request['url'] or not polls
                        or polls[-1]['url']!=request['url'] or any(s['number']==polls[-1]['number'] for s in statuses)
                        or sum(e['event']=='intent' for e in events[poll_events[-1]['seq']+1:])!=1):
                    raise Refused('recorded-delete-operation-required')
    else:
        if op=='bind':
            if alias!='lifecycle-create' or 'response-stub' not in observed:raise Refused('fixed-bind')
            body=strict_json(raw);callback=body['properties']['parameters']['FixtureStubCallback']['value']
            ep=urlsplit(observed['response-stub']['endpoint']);u=urlsplit(callback)
            q=dict(parse_qsl(u.query,strict_parsing=True))
            if u.scheme!='https' or u.netloc!=ep.netloc or u.path!=ep.path+'/triggers/When_a_HTTP_request_is_received/paths/invoke' or set(q)!={'api-version','sp','sv','sig'} or q['api-version']!='2016-10-01' or q['sp']!='/triggers/When_a_HTTP_request_is_received/run' or not q['sig']:raise Refused('exact-bind-slot')
            body['properties']['parameters']['FixtureStubCallback']['value']=''
            method,url,expected=catalog.spec('deploy',alias,run)
            if canonical(body)!=expected or request['method']!=method or request['url']!=url:raise Refused('exact-bind-body')
        else:
            method,url,expected=catalog.spec(op,alias,run)
            if (request['method'],request['url'],raw)!=(method,url,expected):raise Refused('exact-catalog-request')
    return raw


def handle_frame(frame, profile_token=cached_arm_token, connection_factory=None, expected_parent=None):
    if type(frame) is not dict or set(frame)!={'paths','request','parentPid','bindings','context'} or frame['parentPid']!=(os.getppid() if expected_parent is None else expected_parent):
        raise Refused('owned-parent-required')
    authority=Authority(*frame['paths'])
    try:
        body=verify_dispatch(authority,frame)
        request=frame['request'];headers={}
        if request['class']=='arm':headers['Authorization']='Bearer '+profile_token(authority)
        if body:headers['Content-Type']='application/json'
        if connection_factory is None:
            from http.client import HTTPSConnection
            connection_factory=lambda host,port,seconds:HTTPSConnection(host,port,timeout=seconds)
        # Worker-level timeout is backed by the parent's absolute kill deadline.
        selected={}
        response=one_shot(connection_factory,request['method'],request['url'],headers,body,30,selected)
        return {'status':response[0],'body':base64.b64encode(response[1]).decode(), 'run':response[2],'headers':selected}
    finally:authority.close()


class OwnedTransport:
    offline=False
    def __init__(self,authority,popen=subprocess.Popen,job_factory=None):
        if type(authority) is not Authority or not authority.authorized:raise Refused('live-approval-required')
        self.authority,self.popen=authority,popen
        self.job_factory=job_factory or WindowsJob
        self.provenance={'kind':'fixed-catalog'}
        self.last_headers={}
    def send(self,method,url,body,seconds):
        if not 0<seconds<=30:raise Refused('request-deadline')
        start=time.monotonic();deadline=start+seconds
        request={'method':method,'url':url,'body':base64.b64encode(body).decode(),
                 'class':'arm' if urlsplit(url).hostname=='management.azure.com' else self.provenance.get('kind'),
                 'provenance':self.provenance}
        validate_route(self.authority,request)
        frame=canonical({'paths':self.authority.paths,'request':request,'parentPid':os.getpid(),
            'bindings':{'authority':[self.authority.packet_hash,self.authority.decision_hash,self.authority.ready_hash],
                'attempt':self.authority.plan['attempt'],'plan':digest(self.authority.plan)},'context':self.context})
        if len(frame)>MAX_FRAME:raise Refused('pipe-input-bound')
        a=self.authority.packet
        child=self.popen([a['workerPython'],'-I','-B',a['workerFile'],'--owned-worker'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        try:job=self.job_factory(child)
        except Exception:
            child.kill();child.wait(timeout=2)
            raise Refused('worker-ownership-failed-before-feed') from None
        results={};failure=threading.Event()
        def drain(stream,name,limit):
            data=bytearray()
            try:
                while True:
                    block=stream.read(min(8192,limit+1-len(data)))
                    if not block:break
                    data.extend(block)
                    if len(data)>limit:raise Refused('pipe-bound')
                results[name]=bytes(data)
            except Exception:failure.set()
        def feed():
            try:child.stdin.write(len(frame).to_bytes(4,'big')+frame);child.stdin.close()
            except Exception:failure.set()
        threads=[threading.Thread(target=drain,args=(child.stdout,'out',MAX_FRAME+4),daemon=True),
                 threading.Thread(target=drain,args=(child.stderr,'err',65536),daemon=True),
                 threading.Thread(target=feed,daemon=True)]
        for thread in threads:thread.start()
        try:
            while child.poll() is None:
                if failure.is_set() or time.monotonic()>=deadline:raise Refused('worker-unknown')
                time.sleep(min(.01,max(0,deadline-time.monotonic())))
            for thread in threads:
                thread.join(max(0,deadline-time.monotonic()))
            if any(t.is_alive() for t in threads) or failure.is_set() or time.monotonic()>=deadline or child.returncode!=0 or results.get('err'):
                raise Refused('worker-unknown')
            raw=results['out']
            if len(raw)<4 or int.from_bytes(raw[:4],'big')!=len(raw)-4:raise Refused('worker-frame')
            value=strict_json(raw[4:],MAX_FRAME)
            if set(value)!={'status','body','run','headers'} or type(value['status']) is not int or not 100<=value['status']<=599 or type(value['headers']) is not dict or set(value['headers'])-{'location','azure-asyncoperation','retry-after'}:raise Refused('worker-result')
            data=base64.b64decode(value['body'],validate=True)
            if len(data)>1048576:raise Refused('worker-body-bound')
            self.last_headers=value['headers']
            return value['status'],data,value['run']
        except Exception:
            job.terminate()
            try:child.wait(timeout=2)
            except Exception:raise Refused('worker-exit-unverified') from None
            raise Refused('worker-unknown-no-replay') from None
        finally:
            if not job.finish():
                raise Refused('owned-descendant-exit-unverified')
            for stream in (child.stdin,child.stdout,child.stderr):
                try:stream.close()
                except Exception:pass
            if time.monotonic()>=deadline:raise Refused('request-bound-exceeded-during-owned-exit')


def worker_main():
    # No imports of credential code or HTTP before frame and both gates validate.
    stream=sys.stdin.buffer;length=stream.read(4)
    if len(length)!=4:return 2
    n=int.from_bytes(length,'big')
    if n>MAX_FRAME:return 2
    raw=stream.read(n)
    if len(raw)!=n:return 2
    holds=[]
    try:
        frame=json.loads(raw)
        holds=bootstrap(frame)
        global Refused,canonical,digest,strict_json,freeze_plan,one_shot
        from control import Refused,canonical,digest,strict_json,freeze_plan,one_shot
        logging.disable(logging.CRITICAL)
        with contextlib.redirect_stdout(Sink()),contextlib.redirect_stderr(Sink()):
            result=handle_frame(strict_json(raw,MAX_FRAME))
        data=canonical(result)
        sys.stdout.buffer.write(len(data).to_bytes(4,'big')+data);sys.stdout.buffer.flush()
        return 0
    except BaseException:
        # No traceback, request, SDK error or token-bearing text can escape.
        return 2
    finally:
        for s in holds:s.close()


if __name__=='__main__':
    raise SystemExit(worker_main() if sys.argv[1:]==['--owned-worker'] else 2)
