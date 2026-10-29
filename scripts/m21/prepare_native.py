"""Local-only preparation from protected prior observations. No credential use."""
import hashlib
import re
from pathlib import Path
from control import canonical,strict_json,digest
from build_fixture import candidate_plan,source_hashes


def read_receipt(path):
    raw=Path(path).read_bytes()
    if len(raw)>1048576:raise ValueError('Bounded local input required')
    return strict_json(raw),hashlib.sha256(raw).hexdigest()


def read(path):return read_receipt(path)[0]


def role_scope(value,subscription,tenant):
    """Closed ARM scope grammar; None denotes a supported inherited scope."""
    sub='/subscriptions/'+subscription
    if value=='/' or (type(value) is str and value.casefold()==sub.casefold()):return None
    # Prior subscription atScope() receipt establishes this exact tenant-root
    # management-group ancestor; arbitrary management-group ancestry is refused.
    if type(value) is str and value.casefold()==('/providers/Microsoft.Management/managementGroups/'+tenant).casefold():return None
    if type(value) is not str:raise ValueError('Malformed role scope')
    parts=value.split('/')
    if (len(parts)<5 or parts[0]!='' or parts[1].casefold()!='subscriptions'
            or parts[2].casefold()!=subscription.casefold() or parts[3].casefold()!='resourcegroups'
            or not re.fullmatch('[A-Za-z0-9_().-]{1,90}',parts[4]) or parts[4].endswith('.')
            or any(p in ('','.', '..') or not re.fullmatch('[A-Za-z0-9_().-]+',p) for p in parts[1:])):
        raise ValueError('Malformed role scope')
    tail=parts[5:];i=0
    while i<len(tail):
        if tail[i].casefold()!='providers' or len(tail)-i<4 or '.' not in tail[i+1]:raise ValueError('Malformed role descendant')
        i+=2;pairs=0
        while i<len(tail) and tail[i].casefold()!='providers':
            if i+1>=len(tail) or tail[i+1].casefold()=='providers':raise ValueError('Malformed role descendant')
            i+=2;pairs+=1
        if not pairs:raise ValueError('Malformed role descendant')
    return parts[4].casefold()


def prepare(context_path,actor_path,roles_path,cli_root,output,*,synthetic_fixture=False):
    context,context_hash=read_receipt(context_path)
    actor_record,actor_hash=read_receipt(actor_path);actor=actor_record['target']
    roles,roles_hash=read_receipt(roles_path)
    if (actor['subscriptionId']!=context['subscription'] or actor['tenantId']!=context['tenant']
            or actor['expectedUser']!=context['operator']):raise ValueError('Prior actor context mismatch')
    if roles.get('nextLink') not in (None,'') or type(roles.get('value')) is not list:raise ValueError('Complete prior role baseline required')
    scope='/subscriptions/'+context['subscription']
    baseline=[];outside=[]
    groups=[('rg-azd-health-m21-'+kind+'-'+context[kind+'Attempt'][:12]).casefold() for kind in ('normal','late')]
    for row in roles['value']:
        s=row['properties']['scope']
        group=role_scope(s,context['subscription'],context['tenant'])
        if group is None:baseline.append(row)
        elif group not in groups:outside.append(row['id'])
        else:raise ValueError('Unfamiliar or proposed-cell role scope')
    cli=Path(cli_root).resolve();source=Path(__file__).resolve().parent
    required=['azure/cli/core/_profile.pyc','azure/cli/core/auth/identity.pyc',
        'azure/cli/core/auth/msal_credentials.pyc','msal/application.pyc','msal/token_cache.pyc',
        'msal_extensions/__init__.pyc','azure/core/__init__.pyc','requests/__init__.pyc','urllib3/__init__.pyc']
    if not synthetic_fixture and any(not (cli/'Lib/site-packages'/n).is_file() for n in required):raise ValueError('Selected installed SDK file missing')
    files={source/n for n in source_hashes()}
    files.add(Path(__file__).resolve())
    for name in ('python.exe','python314.dll','python314.zip','python314._pth'):files.add(cli/name)
    # Selected installed implementation closure, NOT every transitive SDK/native
    # module. The remaining trusted installation boundary is stated in the packet.
    for name in ('azure/cli/core','msal','msal_extensions','azure/core','requests','urllib3'):
        folder=cli/'Lib/site-packages'/name
        files.update(p for p in folder.rglob('*') if p.is_file() and p.suffix in ('.py','.pyc','.pyd','.dll'))
    if len(files)<10 or any(not p.is_file() for p in files):raise ValueError('Pinned installed runtime unavailable')
    pins={str(p.resolve()):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
    policy=read(source/'ingress-policy.json')
    out=Path(output);out.mkdir(exist_ok=False)
    for kind in ('normal','late'):
        attempt=context[kind+'Attempt'];group='rg-azd-health-m21-'+kind+'-'+attempt[:12]
        plan=candidate_plan({'attempt':attempt,'kind':kind,'subscription':context['subscription'],'group':group,
            'operator_cidr':context['operator_cidr'],'stub_cidrs':policy['outboundCIDRs'],
            'disposition':digest({'kind':kind,'group':group,'attempt':attempt,'boundary':'four exact workflows; draft only'})})
        packet={'schema':'m21-live-decision@1','plan':plan,'tenant':context['tenant'],'operator':context['operator'],
            'operatorObjectId':actor['operatorObjectId'],'inheritedRoleBaseline':baseline,'runtimePins':pins,
            'workerPython':str(cli/'python.exe'),'workerFile':str(source/'live_io.py'),
            'ingressComplete':context['operator_cidr'] is not None and not synthetic_fixture,'incrementalEnvelopeUSD':3,
            'recoveryOperator':'Nathan','kind':kind}
        raw=canonical(packet)
        if len(raw)>1048576:raise ValueError('Decision packet exceeds worker bound')
        (out/(kind+'-proposal.json')).write_bytes(raw)
    (out/'preparation.json').write_bytes(canonical({'executionAuthorized':False,'nativeQualified':False,
        'inheritedRoleObservationSha256':roles_hash,'actorObservationSha256':actor_hash,'contextSha256':context_hash,
        'syntheticFixture':synthetic_fixture,
        'observedRoles':len(roles['value']),'inheritedRoles':len(baseline),'outsideProposedCells':outside,
        'selectedRuntimePins':len(pins),'transitiveClosureProven':False,'operatorIngressResolved':context['operator_cidr'] is not None,
        'approvalFilesCreated':False,'readinessFilesCreated':False}))
    return out


if __name__=='__main__':
    import sys
    prepare(*sys.argv[1:])
