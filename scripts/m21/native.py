"""Narrow four-workflow integration. No public execution entrypoint.

Only an independently approved Authority may construct a native Controller.
Responses/capabilities are transient; only the closed nonsecret projection and
fixed operation receipts may be saved. No expected-value fallback is permitted.
"""
from datetime import datetime
import copy
import re
import time
from urllib.parse import urlsplit
from control import Controller, Refused, ALIASES, RUN, canonical, strict_json, digest
from oracle import check_oracle, context_bindings

TERMINAL={'Succeeded','Failed','Cancelled','TimedOut','Aborted'}


def rid(value):
    if type(value) is not str:raise Refused('resource-id-required')
    return value.casefold()


def parameter_types(definition,expected):
    """Canonicalize only documented workflow parameter declaration enums.

    Payloads, JSON schemas, action types and parameter values stay byte-sensitive.
    Unknown spellings are left intact so structural comparison refuses them.
    """
    result=copy.deepcopy(definition)
    if type(result) is dict and type(result.get('parameters')) is dict:
        types=('String','SecureString','Int','Float','Bool','Array','Object','SecureObject')
        spellings={v:v.lower() for v in types}
        spellings.update({v.lower():v.lower() for v in types})
        for name,declaration in result['parameters'].items():
            if type(declaration) is dict and type(declaration.get('type')) is str:
                target=expected.get('parameters',{}).get(name,{})
                target=target.get('type') if type(target) is dict else None
                if declaration['type'] in spellings and type(target) is str and target in spellings and spellings[declaration['type']]==spellings[target]:
                    declaration['type']=target
    return result


def lock_scope(row,subscription):
    """Validate a subscription lock row before classifying its parent scope."""
    if type(row) is not dict or type(row.get('name')) is not str or not row['name']:
        raise Refused('lock-schema')
    lid=rid(row.get('id'));sub='/subscriptions/'+subscription.casefold()
    match=re.fullmatch(r'(.+)/providers/microsoft.authorization/locks/([^/]+)',lid)
    if (match is None or match[2]!=row['name'].casefold()
            or rid(row.get('type'))!='microsoft.authorization/locks'):
        raise Refused('lock-schema')
    scope=match[1]
    if scope!=sub and not re.fullmatch(re.escape(sub)+r'/resourcegroups/[^/]+(?:/providers/[^/]+(?:/[^/]+/[^/]+)+)*',scope):
        raise Refused('unclassifiable-lock-scope')
    p=row.get('properties')
    if type(p) is not dict or p.get('level') not in ('CanNotDelete','ReadOnly') or type(p.get('notes','')) is not str:
        raise Refused('lock-schema')
    return scope


def qualified_absence(value,group,alias=None):
    try:code=value['error']['code'];message=value['error']['message']
    except (KeyError,TypeError):raise Refused('unqualified-not-found') from None
    codes={'ResourceGroupNotFound'} if alias is None else {'ResourceGroupNotFound','ResourceNotFound','WorkflowNotFound'}
    def exact_name(name):
        return re.search(r'(?<![A-Za-z0-9_.()\-])'+re.escape(name)+r'(?![A-Za-z0-9_.()\-])',message,re.IGNORECASE) is not None
    if code not in codes or type(message) is not str or not exact_name(group):raise Refused('unqualified-not-found')
    if code!='ResourceGroupNotFound' and not exact_name('m21-'+alias):raise Refused('workflow-not-found-binding')


def stamp(value):
    if type(value) is not str:raise Refused('provider-time-required')
    try:
        d=datetime.fromisoformat(value.replace('Z','+00:00'))
        if d.utcoffset() is None:raise ValueError()
        return d.timestamp()
    except (ValueError,OverflowError):raise Refused('provider-time-required') from None


def delete_monitor_state(kind, status, value):
    """Interpret the selected protocol; HTTP 202 never proves completion."""
    if kind not in ('async','location') or status not in (200,202,204):raise Refused('delete-monitor-response')
    if value is not None and type(value) is not dict:raise Refused('delete-monitor-body')
    state=value.get('status') if value is not None else None
    if kind=='location' and state is None and value is not None and type(value.get('properties')) is dict:
        state=value['properties'].get('provisioningState')
    if state in ('Failed','Canceled'):return state
    if value and 'error' in value:raise Refused('delete-monitor-error-body')
    if state=='Succeeded':
        if status!=200:raise Refused('delete-monitor-status-conflict')
        return 'Succeeded'
    if state is not None:
        if state not in ('Accepted','Running','InProgress'):raise Refused('delete-monitor-state')
        if status==204:raise Refused('delete-monitor-status-conflict')
        return 'Pending'
    if kind=='async':raise Refused('delete-monitor-state-required')
    if status==204 and value is not None:raise Refused('delete-monitor-204-body')
    return 'Pending' if status==202 else 'Succeeded'


class NativeController(Controller):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        self._observed_configs={}
    def spec(self,operation,alias=None,run=None):
        if operation=='observation':
            if self._extra is None:raise Refused('fixed-observation-required')
            return 'GET',self._extra,b''
        return super().spec(operation,alias,run)

    @property
    def group_url(self):
        return 'https://management.azure.com/subscriptions/'+self.plan['subscription']+'/resourceGroups/'+self.plan['group']

    def workflow_url(self,alias):
        if alias not in ALIASES:raise Refused('workflow-scope')
        return self.group_url+'/providers/Microsoft.Logic/workflows/m21-'+alias

    def call(self,operation,alias=None,run=None,phase='normal',allowed=(200,)):
        self.dispatch(operation,alias,run,phase)
        status,raw,_=self._response;self._response=None
        if status not in allowed:raise Refused('required-provider-status')
        return strict_json(raw) if raw else None

    def observe(self,url,alias=None,run=None,phase='normal',provenance=None,allowed=(200,)):
        # Caller constructs selectors from fixed workflow/action grammar. Worker
        # revalidates the scope before acquiring any token.
        self._extra=url
        previous=self.transport.provenance if self._native else None
        if self._native:self.transport.provenance=provenance or {'kind':'fixed-catalog'}
        try:return self.call('observation',alias,run,phase,allowed)
        finally:
            self._extra=None
            if self._native:self.transport.provenance=previous

    def collection(self,url,alias=None,run=None,phase='normal'):
        root=urlsplit(url);seen=set();result=[]
        locks=root.path.casefold()==('/subscriptions/'+self.plan['subscription']+'/providers/microsoft.authorization/locks').casefold()
        for _ in range(5):
            if url in seen:raise Refused('pagination-cycle')
            seen.add(url);page=self.observe(url,alias,run,phase)
            if type(page) is not dict or type(page.get('value')) is not list:raise Refused('incomplete-collection')
            result.extend(page['value'])
            if len(result)>100:raise Refused('collection-bound')
            for key in ('id','name'):
                if locks and key=='name':continue # Lock names are local to their full parent scope.
                values=[v[key] for v in result if type(v) is dict and key in v]
                if key=='id':values=[rid(v) for v in values]
                if len(values)!=len(set(values)):raise Refused('duplicate-collection-identity')
            if any(type(v) is not dict for v in result):raise Refused('collection-record-schema')
            if locks:
                for row in result:lock_scope(row,self.plan['subscription'])
            nxt=page.get('nextLink')
            if nxt is None or (type(nxt) is str and nxt==''):return result
            if type(nxt) is not str:raise Refused('pagination-type')
            u=urlsplit(nxt)
            if u.scheme!=root.scheme or u.netloc!=root.netloc or u.path!=root.path:raise Refused('pagination-scope')
            url=nxt
        raise Refused('pagination-bound')

    def run_record(self,alias,run,phase='normal'):
        if (alias,run) not in self.known_runs:raise Refused('unknown-run')
        value=self.call('run',alias,run,phase)
        if value.get('id')!=self.workflow_url(alias).removeprefix('https://management.azure.com')+'/runs/'+run or value.get('name')!=run:raise Refused('provider-run-identity')
        return value

    def wait_run(self,alias,run,phase='normal'):
        for _ in range(12):
            value=self.run_record(alias,run,phase)
            if value['properties'].get('status') in TERMINAL:return value
            self._observe_clock(self._start+(7200 if phase=='recovery' else 5400));time.sleep(1)
        raise Refused('run-not-terminal')

    def action(self,alias,run,name,repetition=None,phase='normal'):
        if (alias,run) not in self.known_runs or not re.fullmatch('[A-Za-z0-9_]{1,128}',name):raise Refused('action-selector')
        tail='/actions/'+name
        if repetition is not None:
            if not re.fullmatch('[0-9]{6}',repetition):raise Refused('repetition-selector')
            tail+='/repetitions/'+repetition
        url=self.workflow_url(alias)+'/runs/'+run+tail
        value=self.observe(url+'?api-version=2019-05-01',alias,run,phase)
        if value.get('id')!=url.removeprefix('https://management.azure.com') or value.get('name')!=(repetition or name):raise Refused('provider-action-identity')
        return value

    def content(self,alias,run,name,record,which='outputs',phase='normal'):
        if which not in ('inputs','outputs') or (alias,run) not in self.known_runs:raise Refused('content-selector')
        try:uri=record['properties'][which+'Link']['uri']
        except (KeyError,TypeError):raise Refused('redacted-or-missing-action-content') from None
        prefix=self.workflow_url(alias).removeprefix('https://management.azure.com')+'/runs/'+run+'/actions/'+name
        rid=record.get('id','')
        suffix=rid[len(prefix):] if rid.startswith(prefix) else 'INVALID'
        if suffix and not re.fullmatch('/repetitions/[0-9]{6}',suffix):raise Refused('content-record-binding')
        if urlsplit(uri).path!=urlsplit(self._endpoints[alias]).path+'/runs/'+run+'/actions/'+name+suffix+'/contents/Action'+which.title():raise Refused('content-link-binding')
        provenance={'kind':'content','endpoint':self._endpoints[alias],'alias':alias,'run':run,'action':name}
        # URI is never journaled or hashed. Worker allows only the exact runtime
        # endpoint, run, action, optional repetition and ActionInputs/Outputs.
        return self.observe(uri,alias,run,phase,provenance)

    def output(self,alias,run,name,repetition=None,phase='normal'):
        record=self.action(alias,run,name,repetition,phase)
        if record['properties'].get('status')!='Succeeded':raise Refused('required-action-not-succeeded')
        return self.content(alias,run,name,record,phase=phase)

    def project(self):
        """Derive the oracle exclusively from actual provider-returned records."""
        parent=next((r for a,r in self.known_runs if a=='lifecycle-create'),None)
        if not parent:raise Refused('parent-provider-run-required')
        pr=self.wait_run('lifecycle-create',parent)
        intents=[self.output('lifecycle-create',parent,'Observe_'+k+'_intent') for k in ('list','create')]
        actions=[]
        for name in ('List_subscriptions','Create_subscription'):
            p=self.action('lifecycle-create',parent,name)['properties']
            actions.append({'name':name,'status':p['status'],'start':stamp(p['startTime']),'end':stamp(p['endTime'])})
        rows=self.collection(self.workflow_url('response-stub')+'/runs?api-version=2019-05-01','response-stub')
        if len(rows)!=2:raise Refused('exactly-two-provider-stub-runs')
        stubs=[]
        for row in rows:
            run=row.get('name')
            if type(run) is not str or not RUN.fullmatch(run) or row.get('id')!=self.workflow_url('response-stub').removeprefix('https://management.azure.com')+'/runs/'+run:raise Refused('stub-provider-identity')
            if ('response-stub',run) not in self.known_runs:
                self.append('stub-run',{'alias':'response-stub','run':run,'parent':parent});self._known_runs.add(('response-stub',run))
            sr=self.wait_run('response-stub',run)
            found=[]
            for kind in ('list','create'):
                record=self.action('response-stub',run,'Observe_'+kind)
                if record['properties'].get('status')=='Succeeded':found.append((kind,self.content('response-stub',run,'Observe_'+kind,record)))
            if len(found)!=1:raise Refused('one-observed-stub-case')
            kind,event=found[0]
            response=self.action('response-stub',run,'Respond_'+kind)
            body=self.content('response-stub',run,'Respond_'+kind,response,'inputs')
            p=sr['properties']
            stubs.append({'workflow':'m21-response-stub','run':run,'status':p['status'],'event':event,
                'response':{'action':'Respond_'+kind,'status':response['properties']['status'],'statusCode':body['statusCode'],'body':body['body']},
                'start':stamp(p['startTime']),'end':stamp(response['properties']['endTime'])})
        stubs.sort(key=lambda s:s['event']['parentAction']!='List_subscriptions')
        receivers=[]
        for alias in ALIASES[:2]:
            run=next((r for a,r in self.known_runs if a==alias),None)
            if not run:raise Refused('receiver-provider-run-required')
            rr=self.wait_run(alias,run)
            selected=self.output(alias,run,'Select_notifications')
            if type(selected) is not dict or set(selected)!={'body'} or type(selected['body']) is not list:raise Refused('select-output-schema')
            selected=selected['body']
            iterations=self.collection(self.workflow_url(alias)+'/runs/'+run+'/actions/For_each_notification/scopeRepetitions?api-version=2019-05-01',alias,run)
            if len(iterations)!=1:raise Refused('receiver-exact-iteration-required')
            repetition=iterations[0]['name']
            check=self.output(alias,run,'Check_notification',repetition)
            delivery=self.action(alias,run,'Post_message_in_a_chat_or_channel',repetition)
            status=delivery['properties']['status']
            outputs=[self.content(alias,run,'Post_message_in_a_chat_or_channel',delivery)] if status=='Succeeded' else []
            receivers.append({'case':alias,'workflow':'m21-'+alias,'run':run,'status':rr['properties']['status'],
                'iterationCount':len(iterations),'selectedValid':[x['valid'] for x in selected],
                'alertIds':[x['alertId'] for x in selected],'deliveryStatuses':[status],
                'deliveryOutputs':outputs,'checkNotificationResult':check['expressionResult']})
        complete=self.output('lifecycle-create',parent,'Observe_create_branch_complete')
        complete={**complete,'status':self.action('lifecycle-create',parent,'Observe_create_branch_complete')['properties']['status']}
        if set(self._observed_configs)!=set(ALIASES):raise Refused('observed-configurations-required')
        bindings=context_bindings(self.plan)
        bindings['configuration']=digest(self._observed_configs)
        bindings['artifacts']['definitions']={a:digest(v['properties']['definition']) for a,v in self._observed_configs.items()}
        projection={'bindings':bindings,'parent':{'workflow':'m21-lifecycle-create','run':parent,'intents':intents,
            'actions':actions,'providerStatus':pr['properties']['status']},'stubs':stubs,'receivers':receivers,'complete':complete}
        result=check_oracle(projection,{'bindings':context_bindings(self.plan),'plan':self.plan,'attempt':self.plan['attempt'],
            'parentWorkflow':'m21-lifecycle-create','stubWorkflow':'m21-response-stub','parentRun':parent})
        return {'projection':projection,'correlationsValid':result['correlationsValid'],'functionObserved':True,
            'nativeQualified':False,'ownershipContinuityProven':False,'evidenceMode':'provider-observed-through-bounded-worker' if self._native else 'injected-provider-records'}

    def start(self):
        target=self.observe('https://management.azure.com/subscriptions/'+self.plan['subscription']+'?api-version=2022-12-01')
        if not self._native:raise Refused('native-start-requires-actual-authority')
        if target.get('subscriptionId')!=self.plan['subscription'] or target.get('tenantId')!=self.transport.authority.packet['tenant'] or target.get('state')!='Enabled':raise Refused('fresh-target-mismatch')
        qualified_absence(self.call('group-read',allowed=(404,)),self.plan['group'])
        self.call('group-create',allowed=(201,))
        for alias in ALIASES:
            self.call('deploy',alias,allowed=(200,201,202))
            value=self.call('workflow-read',alias)
            self.validate_workflow(alias,value,'Disabled',bound=False)
            self.call('callback-read',alias)
        self.call('bind','lifecycle-create',allowed=(200,201,202))
        value=self.call('workflow-read','lifecycle-create');self.validate_workflow('lifecycle-create',value,'Disabled',bound=True)
        for alias in ALIASES:
            self.call('enable',alias,allowed=(200,202))
            self.validate_workflow(alias,self.call('workflow-read',alias),'Enabled',bound=alias=='lifecycle-create')
        for alias in ALIASES[:3]:self.call('invoke',alias,allowed=(200,201,202))
        # Parent/stub visibility is checked in bounded polling, never replaying a trigger.
        return self.project()

    def validate_workflow(self,alias,value,state,bound=True):
        p=value['properties'];expected=self.plan['bodies'][alias]['properties']
        if (rid(value.get('id'))!=rid(self.workflow_url(alias).removeprefix('https://management.azure.com')) or value.get('name')!='m21-'+alias
                or value.get('location','').lower()!='westus2' or value.get('identity') not in (None,{'type':'None'})
                or p.get('state')!=state or p.get('provisioningState')!='Succeeded'
                or parameter_types(p.get('definition'),expected['definition'])!=expected['definition'] or p.get('accessControl',{}).get('triggers')!=expected['accessControl']['triggers']):raise Refused('workflow-readback-mismatch')
        actual=p.get('parameters',{})
        for name,record in expected['parameters'].items():
            # Secure parameters may be provider-redacted: their exact write was
            # source-bound; correlation proves use, readback does not prove value.
            if name in ('GraphSubscriptionClientState','FixtureStubCallback'):continue
            if actual.get(name)!=record:raise Refused('workflow-parameter-mismatch')
        # Normalize ONLY the explicitly redacted synthetic secure slots and
        # approved enabled/disabled transition; all other inputs came from GET.
        normalized={'location':value['location'].lower(),'properties':{'state':'Disabled',
            'definition':parameter_types(p['definition'],expected['definition']),'parameters':{k:(v if k in ('GraphSubscriptionClientState','FixtureStubCallback') else actual[k]) for k,v in expected['parameters'].items()},
            'accessControl':{'triggers':p['accessControl']['triggers']}}}
        self._observed_configs[alias]=normalized
        self.append('workflow-observed',{'alias':alias,'endpoint':p['accessEndpoint'],
            'definition':digest(p['definition']),'configuration':digest(normalized)})

    def write_state(self,operation,alias=None,run=None):
        identity=operation+':'+(alias or 'group')+':'+(run or 'none')
        if identity not in self._intents:return 'unspent'
        results=[e['data'] for e in self.journal.events if e['event']=='result' and e['data']['id']==identity]
        return results[-1]['outcome'] if results else 'unknown'

    def once_recovery(self,operation,alias=None,run=None):
        state=self.write_state(operation,alias,run)
        if state=='unspent':
            try:self.call(operation,alias,run,'recovery',(200,202,204))
            except Refused:
                if self.write_state(operation,alias,run)=='unspent':raise
        # All consumed writes, including refused and unknown ones, are observed
        # without replay. Caller's exact GET predicate decides whether to proceed.

    def recover(self):
        """No new spending/readiness; retain original admission and counters."""
        if not self._native:raise Refused('native-recovery-requires-authority')
        target=self.observe('https://management.azure.com/subscriptions/'+self.plan['subscription']+'?api-version=2022-12-01',phase='recovery')
        if target.get('subscriptionId')!=self.plan['subscription'] or target.get('tenantId')!=self.transport.authority.packet['tenant'] or target.get('state')!='Enabled':raise Refused('fresh-recovery-target')
        if 'group-create:group:none' not in self._completed:raise Refused('uncertain-create-preserve')
        if self.write_state('delete')!='unspent':return self.reconcile_delete()
        # An uncertain invocation has no cancellable identity and blocks deletion.
        invoked={i.split(':')[1] for i in self._intents if i.startswith('invoke:')}
        if invoked!={a for a,r in self.known_runs if a!='response-stub'}:raise Refused('unknown-invocation-preserve')
        for alias in ALIASES:
            self.once_recovery('disable',alias)
            value=self.call('workflow-read',alias,phase='recovery');self.validate_workflow(alias,value,'Disabled')
        for alias,run in self.known_runs:
            record=self.run_record(alias,run,'recovery')
            if record['properties'].get('status') not in TERMINAL:self.once_recovery('cancel',alias,run)
            self.wait_run(alias,run,'recovery')
        baseline=None
        for _ in range(2):
            group=self.call('group-read',phase='recovery')
            if (rid(group.get('id'))!=rid(self.group_url.removeprefix('https://management.azure.com'))
                    or group.get('location','').lower()!='westus2' or group.get('tags')!={'attempt':self.plan['attempt']}):raise Refused('group-disposition-boundary')
            resources=self.collection(self.group_url+'/resources?api-version=2021-04-01',phase='recovery')
            expected={rid(self.workflow_url(a).removeprefix('https://management.azure.com')) for a in ALIASES}
            if type(resources) is not list or len(resources)!=4 or {rid(r.get('id')) for r in resources}!=expected or any(rid(r.get('type'))!='microsoft.logic/workflows' for r in resources):raise Refused('unknown-resources-preserve')
            if any(r.get('tags') not in (None,{}) for r in resources):raise Refused('unexpected-workflow-tags')
            locks=self.collection('https://management.azure.com/subscriptions/'+self.plan['subscription']+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01',phase='recovery')
            relevant=[]
            scope=self.group_url.removeprefix('https://management.azure.com')
            for lock in locks:
                parent=lock_scope(lock,self.plan['subscription']);lower=scope.casefold()
                if parent==lower.rsplit('/resourcegroups/',1)[0] or parent==lower or parent.startswith(lower+'/'):relevant.append(lock)
            if relevant:raise Refused('relevant-lock-preserve')
            roles=self.collection(self.group_url+'/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01',phase='recovery')
            def role_projection(rows):
                return sorted(({'id':rid(r['id']),'scope':rid(r['properties']['scope']),
                    'principal':rid(r['properties']['principalId']),'role':rid(r['properties']['roleDefinitionId']),
                    'condition':r['properties'].get('condition'),'conditionVersion':r['properties'].get('conditionVersion'),
                    'delegated':r['properties'].get('delegatedManagedIdentityResourceId')} for r in rows),key=lambda r:r['id'])
            if role_projection(roles)!=role_projection(self.transport.authority.packet['inheritedRoleBaseline']):raise Refused('role-baseline-changed')
            snapshots=[]
            for alias in ALIASES:
                value=self.call('workflow-read',alias,phase='recovery');self.validate_workflow(alias,value,'Disabled')
                runs=self.collection(self.workflow_url(alias)+'/runs?api-version=2019-05-01',alias,phase='recovery')
                expected_runs={r for a,r in self.known_runs if a==alias}
                if (len(runs)!=len(expected_runs) or {r.get('name') for r in runs}!=expected_runs
                        or any(rid(r.get('id'))!=rid(self.workflow_url(alias).removeprefix('https://management.azure.com')+'/runs/'+r['name']) or r['properties'].get('status') not in TERMINAL for r in runs)):raise Refused('unknown-or-active-runs-preserve')
                snapshots.append({'alias':alias,'configuration':self._observed_configs[alias],
                    'runs':[{'id':r['id'],'status':r['properties']['status']} for r in sorted(runs,key=lambda r:r['id'])]})
            snap=digest({'group':{'id':group['id'],'location':group['location'],'tags':group['tags']},
                'resources':sorted(({'id':r['id'],'type':r['type']} for r in resources),key=lambda r:r['id']),
                'roles':role_projection(roles),'locks':relevant,'workflows':snapshots})
            if baseline is not None and baseline!=snap:raise Refused('inventory-changed')
            baseline=snap
        # This is explicit disposable-boundary human disposition, NOT proof of
        # Azure incarnation continuity. Unknown resources/roles/locks still refuse.
        self.append('native-recovery-gate',{'disposition':self.plan['disposition'],'inventory':baseline});self._recovery_gate=True
        try:self.call('delete',phase='recovery',allowed=(200,202,204))
        except Refused:
            # A durable DELETE intent is sufficient for bounded GET-only
            # reconciliation, never for another DELETE or an ownership claim.
            if self.write_state('delete')=='unspent':raise
            return self.reconcile_delete()
        # Preserve a response envelope before URL parsing; invalid or lost header
        # provenance cannot turn into a synchronous-completion inference later.
        status=[e['data']['status'] for e in self.journal.events if e['event']=='result' and e['data']['id']=='delete:group:none'][-1]
        headers=self.transport.last_headers
        self.append('delete-monitor-response',{'status':status,'headersPresent':any(k in headers for k in ('azure-asyncoperation','location'))})
        from live_io import select_delete_monitor
        self.append('delete-monitor',select_delete_monitor(self.plan,headers))
        return self.reconcile_delete()

    def reconcile_delete(self):
        """Resume only a saved monitor with original budget, never another DELETE."""
        monitors=[e['data'] for e in self.journal.events if e['event']=='delete-monitor']
        responses=[e['data'] for e in self.journal.events if e['event']=='delete-monitor-response']
        if not monitors:
            # Legacy path-only records and post-intent crashes lack monitor
            # provenance. Observe absence, retaining the incomplete result.
            return self.observe_deleted(operation_evidence_incomplete=True)
        monitor=monitors[0]
        if monitor['kind']=='none':
            synchronous=len(responses)==1 and responses[0]['status'] in (200,204) and not responses[0]['headersPresent']
            return self.observe_deleted(operation_evidence_incomplete=not synchronous,completion_proven=synchronous)
        from live_io import validate_delete_monitor,monitor_retry_after
        url=validate_delete_monitor(self.plan,monitor['url'])
        statuses=[e['data'] for e in self.journal.events if e['event']=='delete-monitor-status']
        if any(s['state'] in ('Failed','Canceled') for s in statuses):raise Refused('delete-failed')
        if statuses and statuses[-1]['state']=='Succeeded':return self.observe_deleted(operation_succeeded=True,completion_proven=True)
        polls=[e['data'] for e in self.journal.events if e['event']=='delete-monitor-poll']
        wait=statuses[-1]['retryAfter'] if statuses else monitor['retryAfter']
        # A crash may lose a received response's Retry-After. Keep the consumed
        # poll slot and wait the maximum accepted delay before another GET.
        if polls and (not statuses or polls[-1]['number']>statuses[-1]['number']):wait=60
        for number in range(len(polls)+1,13):
            now=self.clock()
            if now<self._last or now+wait>=self._start+7200:raise Refused('delete-monitor-wait-deadline')
            time.sleep(wait)
            self.append('delete-monitor-poll',{'url':url,'number':number})
            value=self.observe(url,phase='recovery',provenance={'kind':'delete-operation'},allowed=(200,202,204))
            status=[e['data']['status'] for e in self.journal.events if e['event']=='result'][-1]
            state=delete_monitor_state(monitor['kind'],status,value)
            # Terminal results never wait again. Preserve a known failure even
            # when its irrelevant Retry-After value is malformed.
            wait=0 if state!='Pending' else monitor_retry_after(self.transport.last_headers)
            self.append('delete-monitor-status',{'number':number,'state':state,'retryAfter':wait})
            if state in ('Failed','Canceled'):raise Refused('delete-failed')
            if state=='Succeeded':return self.observe_deleted(operation_succeeded=True,completion_proven=True)
        raise Refused('delete-completion-unproven')

    def observe_deleted(self,operation_succeeded=False,operation_evidence_incomplete=False,completion_proven=False):
        # At most twelve same-target GET rounds; a 404 is absence observation,
        # never proof which incarnation was deleted or a reason to replay DELETE.
        for _ in range(12):
            self.dispatch('group-read',phase='recovery')
            status,raw,_=self._response;self._response=None
            if status==404:
                qualified_absence(strict_json(raw),self.plan['group'])
                for alias in ALIASES:qualified_absence(self.call('workflow-read',alias,phase='recovery',allowed=(404,)),self.plan['group'],alias)
                state=self.write_state('delete')
                return {'disposalObserved':state=='acknowledged','absenceObserved':True,
                    'deleteOperationSucceeded':operation_succeeded,'unknownDeleteOutcome':state!='acknowledged',
                    'operationEvidenceIncomplete':operation_evidence_incomplete,
                    'verifiedDisposal':state=='acknowledged' and completion_proven and not operation_evidence_incomplete,
                    'nativeQualified':False,'ownershipContinuityProven':False}
            if status!=200:raise Refused('delete-observation-incomplete')
            time.sleep(1)
        raise Refused('delete-absence-unproven')


def main():
    # The adopted goal expressly keeps live paths disabled. Source is prepared
    # for independent review; a later exact authorization must activate a runner.
    raise Refused('live-path-disabled-before-auth')


if __name__=='__main__':main()
