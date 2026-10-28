"""Pure local plan/catalog construction. No Controller/auth/transport startup."""
import json
import sys
import re
import uuid
from pathlib import Path
from control import Controller, ALIASES, canonical, digest, freeze_plan, strict_json
from build_fixture import candidate_plan


def prepare(context_path, output):
    with Path(context_path).open('rb') as stream:
        raw=stream.read(131073)
    if len(raw)>131072:raise ValueError('Private context size bound')
    context = strict_json(raw)
    required={'subscription','tenant','operator','normalAttempt','lateAttempt','operator_cidr','stub_cidrs'}
    if type(context) is not dict or set(context) != required or context['normalAttempt']==context['lateAttempt']:
        raise ValueError('Closed distinct private context required')
    for name in ('subscription','tenant','operator','normalAttempt','lateAttempt'):
        if type(context[name]) is not str:raise ValueError('Scalar context required')
    for name in ('subscription','tenant'):
        if str(uuid.UUID(context[name])) != context[name]:raise ValueError('Canonical UUID required')
    for name in ('normalAttempt','lateAttempt'):
        if not re.fullmatch('[a-f0-9]{32}',context[name]):raise ValueError('Exact attempt required')
    if len(context['operator'])>320 or not re.fullmatch(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+',context['operator']):
        raise ValueError('Bounded operator UPN required')
    if context['stub_cidrs'] is not None and (type(context['stub_cidrs']) is not list or not context['stub_cidrs'] or any(type(v) is not str for v in context['stub_cidrs'])):
        raise ValueError('Nonempty nested ingress or explicit unresolved null required')
    if context['operator_cidr'] is not None and type(context['operator_cidr']) is not str:
        raise ValueError('Operator ingress type')
    output=Path(output);output.mkdir(exist_ok=False)
    for kind in ('normal','late'):
        attempt=context[kind+'Attempt']
        group='rg-azd-health-m21-'+kind+'-'+attempt[:12]
        disposition=digest({'kind':kind,'group':group,'attempt':attempt,'boundary':'four exact workflows; draft only'})
        p=freeze_plan(candidate_plan({'attempt':attempt,'kind':kind,'group':group,
            'subscription':context['subscription'],'operator_cidr':context['operator_cidr'],
            'stub_cidrs':context['stub_cidrs'],'disposition':disposition}))
        # spec() is a pure catalog method; bypass constructor intentionally.
        # No writer, transport, clock, auth, HTTP connection or capability exists.
        catalog=object.__new__(Controller);catalog._plan=p;catalog._capabilities={};catalog._known_runs=set()
        requests=[]
        def add(operation,alias=None,phase='normal'):
            method,url,body=catalog.spec(operation,alias)
            requests.append({'ordinal':len(requests)+1,'operation':operation,'alias':alias,'phase':phase,
                'method':method,'url':url,'body':json.loads(body) if body else None,
                'responsePolicy':'fixed receipt only; raw capabilities/secret bodies never journalled','nativeQualified':False})
        add('group-read');add('group-create')
        for operation in ('inventory','locks','roles'):add(operation)
        for alias in ALIASES:
            add('deploy',alias);add('workflow-read',alias);add('callback-read',alias)
        lifecycle=catalog.spec('deploy','lifecycle-create')[1]
        requests.append({'ordinal':len(requests)+1,'operation':'bind','alias':'lifecycle-create','phase':'normal',
            'method':'PUT','url':lifecycle,'bodyRule':'exact generated body; only empty FixtureStubCallback.value replaced by verified stub capability in memory',
            'rawRetention':False,'secretHashAllowed':False})
        for alias in ALIASES:add('enable',alias)
        for alias in ALIASES[:3]:
            requests.append({'ordinal':len(requests)+1,'operation':'invoke','alias':alias,'phase':'normal','method':'POST',
                'targetRule':'only exact capability accepted from same workflow trigger read and matching runtime accessEndpoint',
                'body':p['inputs'][alias],'reservation':p['workloads'][alias],'retry':False})
        boundary=len(requests)+1
        requests.append({'ordinal':boundary,'operation':'observe-oracle-and-known-runs',
            'paths':'GET exact known workflow/runs/{provider-returned-run}/actions, then exact approved observation content; reject missing/redacted/extra data',
            'authority':'separate future approval for any content-link capabilities; no URLs/secret hashes persisted'})
        for alias in ALIASES:add('disable',alias,'recovery')
        requests.append({'ordinal':len(requests)+1,'operation':'known-run-recovery','phase':'recovery',
            'rule':'GET only ledger-bound runs; cancel POST only exact nonterminal run name; no invented run; no replay; polling/status is charged'})
        for operation in ('inventory','locks','roles'):add(operation,phase='recovery')
        add('delete',phase='recovery');add('group-read',phase='recovery')
        packet={'status':'offline-reviewed-candidate-live-blocked','executionAuthorized':False,'nativeQualified':False,
            'plan':p,'planSha256':digest(p),'tenant':context['tenant'],'operator':context['operator'],
            'requests':requests,'lateBoundary':('after oracle/known-run evidence, immediately before first disable' if kind=='late' else None),
            'readiness':{'state':'waiting-for-Nathan-ready','planningOnly':True,'attempt':attempt,'phrase':"I'm ready",'received':False,
                'window':'separate chosen start through immutable +120min; no start time allocated yet','expiresAutomatically':False,
                'liveApprovalPresent':False,'materialChangeRequiresVisiblePause':True},
            'runtimeBindings':'known runs/content link URIs can only be bound after exact provider responses; no new target selectors',
            'missingIngressFacts':context['operator_cidr'] is None or context['stub_cidrs'] is None}
        (output/(kind+'-private.json')).write_bytes(canonical(packet))
    return output


if __name__=='__main__': prepare(sys.argv[1],sys.argv[2])
