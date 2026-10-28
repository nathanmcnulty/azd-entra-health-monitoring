"""Only fixed fake HTTP connections. No credential/provider operation permitted."""
import copy
import importlib.util
import io
import json
import math
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts/m21"))
from control import Controller, Journal, Refused, canonical, digest, live_main, one_shot
from build_fixture import make_fixture, write_candidate, candidate_plan, oracle_bindings
from oracle import check_oracle, context_bindings


class Clock:
    def __init__(self): self.now = 1000.0
    def __call__(self): return self.now


class Response:
    status = 200
    headers = []
    def __init__(self, body=b'{}'): self.body = io.BytesIO(body)
    def read(self, limit): return self.body.read(limit)
    def getheaders(self): return self.headers


class Connection:
    def __init__(self, transport): self.t = transport
    def request(self, method, path, body, headers):
        self.t.sent.append((method, path, body))
        if self.t.fault: raise OSError('SYNTHETIC_SECRET_MUST_NOT_ESCAPE')
    def getresponse(self): return self.t.response
    def close(self): self.t.closed += 1


class Transport:
    offline = True
    def __init__(self):
        self.sent = []; self.closed = 0; self.fault = False; self.response = Response()
    def send(self, method, url, body, seconds):
        return one_shot(lambda *_: Connection(self), method, url, {}, body, seconds)


def plan(kind='normal'):
    return candidate_plan({'attempt': ('a' if kind == 'normal' else 'b') * 32, 'kind': kind,
        'subscription': '11111111-1111-1111-1111-111111111111',
        'group': 'rg-azd-health-m21-' + kind + '-' + 'a' * 12,
        'operator_cidr': '192.0.2.1/32', 'stub_cidrs': ['198.51.100.0/24'], 'disposition': 'disposition-draft-only'})


def oracle_record():
    p=plan()
    expected = {'attempt': 'a' * 32, 'bindings': context_bindings(p), 'plan':p,
        'parentWorkflow': 'm21-lifecycle-create', 'parentRun': 'parent-1', 'stubWorkflow': 'm21-response-stub'}
    intents = [{'attempt': expected['attempt'], 'case': 'lifecycle-create',
        'request': expected['attempt'] + '-' + kind, 'parentWorkflow': expected['parentWorkflow'],
        'parentRun': 'parent-1', 'parentAction': action} for kind, action in
        (('list', 'List_subscriptions'), ('create', 'Create_subscription'))]
    parent = {'workflow': expected['parentWorkflow'], 'run': 'parent-1', 'intents': intents,
        'providerStatus': 'Succeeded', 'actions': [{'name': 'List_subscriptions', 'status': 'Succeeded', 'start': 1, 'end': 4},
        {'name': 'Create_subscription', 'status': 'Succeeded', 'start': 5, 'end': 8}]}
    stubs = []
    for i, (kind, status, body) in enumerate((('list', 200, {'value': []}), ('create', 201, {'id': 'fixture-created-subscription'}))):
        run = 'stub-' + kind
        stubs.append({'workflow': 'm21-response-stub', 'run': run, 'status': 'Succeeded',
            'event': {**intents[i], 'stubRun': run, 'responseStatus': status, 'responseBody': body},
            'response': {'action': 'Respond_' + kind, 'status': 'Succeeded', 'statusCode': status, 'body': body},
            'start': 2 + 4 * i, 'end': 3 + 4 * i})
    receivers=[]
    for i,case in enumerate(('receiver-duplicate','receiver-mismatch')):
        receivers.append({'case':case,'workflow':'m21-'+case,'run':'provider-'+case,'status':'Succeeded','iterationCount':1,
            'selectedValid':[True,True] if i==0 else [False], 'alertIds':['fixture-alert-01','fixture-alert-01'] if i==0 else ['fixture-alert-02'],
            'checkNotificationResult':i==0, 'deliveryStatuses':['Succeeded'] if i==0 else ['Skipped'],
            'deliveryOutputs':[{'fixtureDelivery':'synthetic','sourceAction':'Post_message_in_a_chat_or_channel'}] if i==0 else []})
    return {'bindings': copy.deepcopy(expected['bindings']), 'parent': parent, 'stubs': stubs, 'receivers':receivers,
        'complete': {**intents[1], 'branch': 'empty-list-create', 'status': 'Succeeded'}}, copy.deepcopy(expected)


def fake_projection_from_actual_requests(sent, p):
    """Fixed fake WDL subset, not Azure/WDL execution or provider evidence."""
    bodies={};inputs={}
    for method,path,raw in sent:
        for alias in p['bodies']:
            if method=='PUT' and '/workflows/m21-'+alias+'?' in path:
                bodies[alias]=json.loads(raw)
            if method=='POST' and '/workflows/id-'+alias+'/triggers/' in path:
                inputs[alias]=json.loads(raw)
    r,e=oracle_record()
    r['bindings']=context_bindings(p)
    r['bindings']['artifacts']={'profile':oracle_bindings()['profile'],
                   'definitions':{a:digest(b['properties']['definition']) for a,b in bodies.items()},'inputs':digest(inputs)}
    config=copy.deepcopy(bodies)
    config['lifecycle-create']['properties']['parameters']['FixtureStubCallback']['value']=''
    r['bindings']['configuration']=digest(config)
    lifecycle=bodies['lifecycle-create']['properties'];attempt=lifecycle['parameters']['FixtureAttemptId']['value']
    e['attempt']=attempt
    e['parentRun']='provider-lifecycle-create';r['parent']['run']=e['parentRun']
    def evaluate(value,claims=None,stub_run=None):
        if isinstance(value,dict):return {k:evaluate(v,claims,stub_run) for k,v in value.items()}
        if value=="@parameters('FixtureAttemptId')":return attempt
        if value=="@workflow().name":return 'm21-lifecycle-create'
        if value=="@workflow().run.name":return stub_run or e['parentRun']
        if value=="@concat(parameters('FixtureAttemptId'), '-list')":return attempt+'-list'
        if value=="@concat(parameters('FixtureAttemptId'), '-create')":return attempt+'-create'
        if isinstance(value,str) and value.startswith("@triggerBody()?['"):
            return claims[value[len("@triggerBody()?['"):-2]]
        if isinstance(value,str) and value.startswith('@'):raise AssertionError('Unsupported fixed model expression')
        return value
    actions=lifecycle['definition']['actions']
    intents=[evaluate(actions['Observe_list_intent']['inputs']),
             evaluate(actions['Check_existing_subscription']['actions']['Observe_create_intent']['inputs'])]
    r['parent']['intents']=intents
    for i,kind in enumerate(('list','create')):
        selected=bodies['response-stub']['properties']['definition']['actions']['Validate_fixture_request']['actions']['Select_fixture_response']['cases'][kind]['actions']
        event=evaluate(selected['Observe_'+kind]['inputs'],intents[i],'stub-'+kind)
        r['stubs'][i]['event']=event
        r['stubs'][i]['response']['statusCode']=selected['Respond_'+kind]['inputs']['statusCode']
        r['stubs'][i]['response']['body']=event['responseBody']
    r['complete']={**evaluate(actions['Check_existing_subscription']['actions']['Observe_create_branch_complete']['inputs']), 'status':'Succeeded'}
    for i,alias in enumerate(('receiver-duplicate','receiver-mismatch')):
        values=inputs[alias]['value']
        valid=[v['clientState']=='fixture-client-state' and v['changeType']=='created' and bool(v['resourceData']['id']) for v in values]
        ids=[v['resourceData']['id'] for v in values]
        iterations=len(set(zip(valid,ids)))
        r['receivers'][i]['selectedValid']=valid;r['receivers'][i]['alertIds']=ids
        r['receivers'][i]['iterationCount']=iterations;r['receivers'][i]['checkNotificationResult']=any(valid)
    return r,e


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.clock = Clock(); self.t = Transport()
        self.p = plan(); self.c = Controller(self.p, pathlib.Path(self.tmp.name)/'attempt', self.t, self.clock)
        self.addCleanup(self.tmp.cleanup); self.addCleanup(lambda: self.c.close())
    def admit(self):
        self.c.test_approve(digest(self.p)); self.c.test_ready(self.p['attempt'], "I'm ready"); self.c.admit_test()
    def test_live_default_refuses_before_files_or_auth(self):
        with self.assertRaisesRegex(Refused, 'live-path-disabled'): Controller(self.p, 'unused')
        with self.assertRaisesRegex(Refused, 'live-path-disabled'): live_main(Execute=True)
        self.assertEqual(self.t.sent, [])
    def test_readiness_does_not_imply_approval(self):
        self.c.test_ready(self.p['attempt'], "I'm ready")
        with self.assertRaises(Refused): self.c.admit_test()
    def test_approval_does_not_imply_readiness(self):
        self.c.test_approve(digest(self.p))
        with self.assertRaises(Refused): self.c.admit_test()
    def test_ready_cannot_transfer_to_late_attempt(self):
        with self.assertRaises(Refused): self.c.test_ready('b'*32, "I'm ready")
    def test_target_scope_and_api_are_generated_not_user_urls(self):
        self.admit(); self.c.dispatch('group-create')
        self.assertIn('/resourceGroups/'+self.p['group']+'?api-version=2022-09-01', self.t.sent[0][1])
        with self.assertRaises(Refused): self.c.dispatch('deploy', 'stranger')
    def test_changed_input_definition_or_understated_workload_is_refused(self):
        for field in ('inputs','bodies','workloads','source_hashes'):
            bad=copy.deepcopy(self.p)
            if field=='inputs':bad[field]['lifecycle-create']={'case':'different'}
            elif field=='bodies':bad[field]['lifecycle-create']['properties']['state']='Enabled'
            elif field=='workloads':bad[field]['lifecycle-create']={'triggers':0,'actions':0,'bytes':0}
            else:bad[field]['control.py']='wrong'
            with self.subTest(field=field),self.assertRaises(Refused):Controller(bad,pathlib.Path(self.tmp.name)/field,self.t,self.clock)
    def test_returned_plan_is_detached(self):
        view=self.c.plan;view['group']='rg-stranger'
        self.assertEqual(self.c.plan['group'],self.p['group'])
    def test_poll_calls_consume_normal_budget(self):
        self.admit()
        for _ in range(300): self.c.dispatch('group-read')
        with self.assertRaisesRegex(Refused, 'dispatch-budget'): self.c.dispatch('group-read')
        self.assertEqual(len(self.t.sent), 300)
    def test_unknown_write_consumed_and_never_replayed(self):
        self.admit(); self.t.fault = True
        with self.assertRaisesRegex(Refused, 'request-unknown'): self.c.dispatch('group-create')
        self.assertEqual(self.c.counts['normal'], 1)
        self.t.fault = False
        with self.assertRaises(Refused): self.c.dispatch('group-create')
        self.assertNotIn('SYNTHETIC_SECRET', (self.c.journal.root/'events.jsonl').read_text())
    def test_recovery_reserve_independent_of_cost_freshness(self):
        self.admit(); self.c.pause_material_change()
        result = self.c.dispatch('group-read', phase='recovery', cost_fresh=False)
        self.assertFalse(result['nativeQualified']); self.assertEqual(self.c.counts['recovery'], 1)
        with self.assertRaises(Refused): self.c.dispatch('deploy', 'receiver-duplicate', phase='recovery')
    def test_delete_requires_exact_disposition_and_quiescence(self):
        self.admit(); self.c.dispatch('group-create')
        with self.assertRaises(Refused): self.c.dispatch('delete', phase='recovery')
        facts = {'disposition': self.p['disposition'], 'quiescent': True, 'unknownResources': False,
                 'unfamiliarLocks': False, 'unfamiliarRoles': False, 'inventoryRepeatedAndComplete': True}
        for key in ('quiescent', 'unknownResources', 'unfamiliarLocks', 'unfamiliarRoles'):
            bad=copy.deepcopy(facts); bad[key] = not facts[key]
            with self.assertRaises(Refused): self.c.test_recovery_snapshot(bad)
        self.c.test_recovery_snapshot(facts)
        self.assertFalse(self.c.dispatch('delete', phase='recovery')['nativeQualified'])
    def test_unknown_run_cannot_be_cancelled(self):
        self.admit()
        with self.assertRaisesRegex(Refused, 'unknown-run'): self.c.dispatch('cancel', 'lifecycle-create', 'invented', phase='recovery')
    def test_clock_rollback_or_expiry_refuses(self):
        self.admit(); self.clock.now -= 1
        with self.assertRaises(Refused): self.c.dispatch('group-read')
        self.clock.now = 1000 + 7200
        with self.assertRaises(Refused): self.c.dispatch('group-read', phase='recovery')
    def test_journal_failure_prevents_dispatch(self):
        self.admit()
        with patch.object(self.c.journal, 'append', side_effect=OSError('private')):
            with self.assertRaisesRegex(Refused, 'journal-failed'): self.c.dispatch('group-create')
        self.assertEqual(self.t.sent, [])
        with self.assertRaisesRegex(Refused, 'poisoned'): self.c.dispatch('group-read')
    def test_deadline_rechecked_after_durable_intent(self):
        self.admit(); original=self.c.journal.append
        def append(event, data):
            original(event,data)
            if event=='intent': self.clock.now=6400
        with patch.object(self.c.journal,'append',side_effect=append):
            with self.assertRaisesRegex(Refused,'deadline-after-journal'): self.c.dispatch('group-create')
        self.assertEqual(self.t.sent,[]);self.assertEqual(self.c.counts['normal'],1)
    def test_nan_or_rollback_during_journal_refuses_before_transport(self):
        for value in (float('nan'),999.0):
            with tempfile.TemporaryDirectory() as d:
                clock=Clock();t=Transport();c=Controller(plan(),pathlib.Path(d)/'a',t,clock)
                try:
                    c.test_approve(digest(c.plan));c.test_ready(c.plan['attempt'],"I'm ready");c.admit_test()
                    original=c.journal.append
                    def append(event,data):
                        original(event,data)
                        if event=='intent':clock.now=value
                    with patch.object(c.journal,'append',side_effect=append),self.assertRaises(Refused):c.dispatch('group-create')
                    self.assertEqual(t.sent,[])
                finally:c.close()
    def test_nonfinite_response_time_is_unknown_not_success(self):
        self.admit();original=self.t.send
        def send(*args):
            result=original(*args);self.clock.now=float('nan');return result
        with patch.object(self.t,'send',side_effect=send),self.assertRaisesRegex(Refused,'request-unknown'):
            self.c.dispatch('group-create')
        self.assertEqual(self.c.counts['normal'],1)
    def test_full_fixed_fixture_path_reserves_nested_workload_before_invoke(self):
        self.admit();self.c.dispatch('group-create')
        for alias in self.p['bodies']:
            self.t.response=Response();self.c.dispatch('deploy',alias)
            endpoint='https://fixed.westus2.logic.azure.com/workflows/id-'+alias
            self.t.response=Response(canonical({'properties':{'accessEndpoint':endpoint}}))
            self.c.dispatch('workflow-read',alias)
            value=endpoint+'/triggers/When_a_HTTP_request_is_received/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2FWhen_a_HTTP_request_is_received%2Frun&sv=1.0&sig=TEST_SECRET_CAPABILITY'
            self.t.response=Response(canonical({'value':value}));self.c.dispatch('callback-read',alias)
        self.t.response=Response();self.c.dispatch('bind','lifecycle-create')
        for alias in self.p['bodies']:
            self.t.response=Response();self.c.dispatch('enable',alias)
        for alias in self.p['inputs']:
            self.t.response=Response();self.t.response.headers=[('x-ms-workflow-run-id','provider-'+alias)]
            self.c.dispatch('invoke',alias)
        projection,expected=fake_projection_from_actual_requests(self.t.sent,self.p)
        self.assertTrue(check_oracle(projection,expected)['correlationsValid'])
        if os.environ.get('M21_EVIDENCE_DIR'):
            evidence={'mode':'fixed-offline-fake','nativeQualified':False,'providerCalls':0,
                'planSha256':digest(self.p),'operationEvents':copy.deepcopy(self.c.journal.events),
                'oracleProjection':projection,'oracleResult':check_oracle(projection,expected)}
            raw=canonical(evidence)
            self.assertNotIn(b'TEST_SECRET_CAPABILITY',raw)
            path=pathlib.Path(os.environ['M21_EVIDENCE_DIR'])/'fixed-fake-composition.json'
            with path.open('xb') as stream:stream.write(raw)
        projection['receivers'][1]['deliveryStatuses']=['Succeeded']
        with self.assertRaises(Refused):check_oracle(projection,expected)
        self.assertEqual(self.c.workload['triggers'],sum(x['triggers'] for x in self.p['workloads'].values()))
        self.assertEqual(len(self.c.known_runs),3)
        self.assertNotIn('TEST_SECRET_CAPABILITY',(self.c.journal.root/'events.jsonl').read_text())
        with self.assertRaisesRegex(Refused,'write-never-replayed'):self.c.dispatch('invoke','lifecycle-create')
    def test_material_change_requires_new_visible_ready_gate(self):
        self.c.test_approve(digest(self.p));self.c.test_ready(self.p['attempt'],"I'm ready")
        self.c.pause_material_change()
        with self.assertRaises(Refused):self.c.admit_test()
    def test_exclusive_local_writer(self):
        with self.assertRaises(Refused): Controller(self.p, self.c.journal.root, self.t, self.clock, recovery=True)
    def test_restart_preserves_tokens_and_refuses_normal_work(self):
        self.admit(); self.c.dispatch('group-create'); self.c.close()
        self.c = Controller(self.p, pathlib.Path(self.tmp.name)/'attempt', self.t, self.clock, recovery=True)
        self.assertEqual(self.c.counts['normal'], 1)
        with self.assertRaises(Refused): self.c.dispatch('group-create')
        self.c.dispatch('group-read', phase='recovery')
        self.assertEqual(self.c.counts['recovery'], 1)
    def test_torn_or_tampered_journal_is_not_resumed(self):
        self.admit(); path=self.c.journal.root/'events.jsonl'; self.c.close()
        raw=path.read_bytes(); path.write_bytes(raw[:-1])
        with self.assertRaises(Refused): Controller(self.p, path.parent, self.t, self.clock, recovery=True)
        path.write_bytes(raw.replace(b'"synthetic":true', b'"synthetic":false', 1))
        with self.assertRaises(Refused): Journal.inspect(path)
    def test_valid_hash_cannot_legitimize_negative_workload_or_orphan_result(self):
        self.admit();self.c.dispatch('group-read');path=self.c.journal.root/'events.jsonl'
        events=copy.deepcopy(self.c.journal.events)
        for mutation in ('negative','orphan','false-admission'):
            bad=copy.deepcopy(events)
            if mutation=='negative':next(e for e in bad if e['event']=='intent')['data']['workload']['actions']=-1
            elif mutation=='orphan':next(e for e in bad if e['event']=='result')['data']['id']='invented'
            else:next(e for e in bad if e['event']=='admitted')['data']['synthetic']=False
            previous='0'*64
            for event in bad:
                event['previous']=previous;event['hash']=digest({k:v for k,v in event.items() if k!='hash'});previous=event['hash']
            other=path.parent/(mutation+'.jsonl');other.write_bytes(b''.join(canonical(e)+b'\n' for e in bad))
            with self.subTest(mutation=mutation),self.assertRaises(Refused):Journal.inspect(other)


class WireTests(unittest.TestCase):
    def test_wire_deadline_rechecked_between_stages(self):
        t=Transport()
        with patch('control.time.monotonic',side_effect=[0,0,0,31]):
            with self.assertRaises(Refused):t.send('GET','https://management.azure.com/fixed',b'',1)
    def test_no_redirect_retry_or_secret_exception(self):
        t=Transport(); t.response.status=302
        self.assertEqual(t.send('GET', 'https://management.azure.com/fixed', b'', 1)[0],302)
        self.assertEqual(len(t.sent),1); self.assertEqual(t.closed,1)
        t.fault=True
        with self.assertRaisesRegex(Refused, '^transport-unknown$'): t.send('GET','https://management.azure.com/fixed',b'',1)
        self.assertEqual(len(t.sent),2)
    def test_streamed_body_bound(self):
        t=Transport();t.response=Response(b'x'*1048577)
        with self.assertRaises(Refused): t.send('GET','https://management.azure.com/fixed',b'',1)
        self.assertEqual(t.closed,1)
    def test_duplicate_provider_run_headers_fail(self):
        t=Transport();t.response=Response();t.response.headers=[('x-ms-workflow-run-id','a'),('x-ms-workflow-run-id','b')]
        with self.assertRaises(Refused): t.send('GET','https://management.azure.com/fixed',b'',1)


class OracleTests(unittest.TestCase):
    def test_correlated_nonsecret_projection_still_not_native_authority(self):
        r,e=oracle_record();self.assertFalse(check_oracle(r,e)['nativeQualified'])
    def test_extra_missing_duplicate_swapped_redacted_and_wrong_semantics_refuse(self):
        r,e=oracle_record()
        mutations=[lambda x:x['stubs'].append(copy.deepcopy(x['stubs'][0])),
                   lambda x:x['stubs'].pop(),lambda x:x['stubs'][1].update(run='stub-list'),
                   lambda x:x['stubs'][0]['event'].update(parentRun='other'),
                   lambda x:x['stubs'][0].update(response='redacted'),
                   lambda x:x['stubs'][0]['response'].update(body={'value':[{'id':'wrong'}]}),
                   lambda x:x['bindings'].update(configuration='drift'),lambda x:x['complete'].update(branch='existing-subscription')]
        for mutate in mutations:
            bad=copy.deepcopy(r); mutate(bad)
            with self.subTest(record=mutate),self.assertRaises((Refused,TypeError)):check_oracle(bad,e)
    def test_stubs_outside_parent_window_fail(self):
        r,e=oracle_record();r['stubs'][0]['end']=10
        with self.assertRaises(Refused):check_oracle(r,e)
    def test_receiver_behavior_and_nonfinite_time_are_not_success_fallbacks(self):
        r,e=oracle_record()
        for mutation in ('delivery','duplicate','nan','bool'):
            bad=copy.deepcopy(r)
            if mutation=='delivery':bad['receivers'][1]['deliveryStatuses']=['Succeeded']
            elif mutation=='duplicate':bad['receivers'][0]['iterationCount']=2
            elif mutation=='nan':bad['stubs'][0]['start']=float('nan')
            else:bad['stubs'][0]['start']=True
            with self.subTest(mutation=mutation),self.assertRaises(Refused):check_oracle(bad,e)


class ArtifactTests(unittest.TestCase):
    def test_stub_derives_response_without_caller_fixture_reply(self):
        defs,_,p=make_fixture();raw=canonical(defs['response-stub'])
        self.assertNotIn(b'fixtureReply',raw);self.assertIn(b'fixture-created-subscription',raw)
        self.assertEqual(p['accounting']['lifecycleActions'],18);self.assertEqual(p['accounting']['actions'],41)
    def test_reservations_include_all_branch_nodes_and_nested_http(self):
        _,_,p=make_fixture();r=p['accounting']['conservativeReservations']
        self.assertGreaterEqual(r['lifecycle-create']['actions'],18)
        self.assertLessEqual(sum(x['actions'] for x in r.values()),128)
        self.assertLessEqual(sum(x['triggers'] for x in r.values()),20)
    def test_artifacts_are_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as d:
            a=write_candidate(pathlib.Path(d)/'a');b=write_candidate(pathlib.Path(d)/'b')
            self.assertEqual(a,b)


if __name__=='__main__': unittest.main(verbosity=2)
