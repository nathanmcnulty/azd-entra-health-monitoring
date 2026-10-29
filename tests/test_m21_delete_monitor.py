"""Synthetic HTTP/process fixtures only: no credentials or Azure requests."""
import sys
from pathlib import Path
import unittest
from time import sleep as actual_sleep
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts/m21'))
from control import Refused, Journal
from live_io import select_delete_monitor, validate_delete_monitor, monitor_retry_after, OwnedTransport
from native import NativeController, delete_monitor_state
from test_m21_recovery_baseline import recovery_cell
from test_m21_native import FakeProcess, FakeJob, urlsplit_path


def monitor(cell, api='2018-08-01', suffix='', operation='synthetic-operation', regional=False):
    root='https://management.azure.com/subscriptions/'+cell.g.plan['subscription']
    path='/providers/Microsoft.Resources/locations/westus2/operationStatuses/' if regional else '/operationresults/'
    return root+path+operation+'?api-version='+api+suffix


def install(cell, headers, responses):
    before=cell.provider.on_request
    urls={urlsplit_path(url):list(rows) for url,rows in responses.items()}
    def request(method,path,body):
        before(method,path,body)
        if method=='DELETE':cell.provider.routes[path]=(202,{},list(headers.items()))
        if method=='GET' and path in urls:
            queue=urls[path]
            if queue:cell.provider.routes[path]=queue.pop(0)
    cell.provider.on_request=request


def reopen(cell):
    root=cell.c.journal.root
    cell.c.close()
    cell.c=NativeController(cell.authority.plan,root,OwnedTransport(cell.authority,
        popen=lambda argv,**kw:FakeProcess(argv,cell.provider,**kw),job_factory=FakeJob),recovery=True)


class DeleteMonitorTests(unittest.TestCase):
    def test_async_precedence_retains_full_query_and_direct_completion(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            url=monitor(cell,suffix='&monitor=true',regional=True)
            # The ignored Location is distinct; it must never be requested.
            other=monitor(cell,api='2022-09-01',operation='different-result')
            install(cell,{'azure-asyncoperation':url,'location':other,'retry-after':'0'},
                    {url:[(200,{'status':'InProgress'},[('Retry-After','0')]),(200,{'status':'Succeeded'})]})
            result=cell.c.recover()
            self.assertTrue(result['verifiedDisposal']);self.assertTrue(result['deleteOperationSucceeded'])
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)
            saved=[e['data'] for e in cell.c.journal.events if e['event']=='delete-monitor']
            self.assertEqual(saved,[{'kind':'async','url':url,'retryAfter':0}])
            sent=[p for m,h,p,headers in cell.provider.sent if m=='GET']
            self.assertNotIn(urlsplit_path(other),sent)
            self.assertEqual(sent.count(urlsplit_path(url)),2)
            Journal.inspect(cell.c.journal.root/'events.jsonl')

    def test_location_empty_204_and_http_200_complete_after_pending(self):
        for status,body in ((204,None),(200,{})):
            with self.subTest(status=status),recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
                url=monitor(cell)
                install(cell,{'location':url,'retry-after':'0'},
                        {url:[(202,None,[('Retry-After','0')]),(status,body)]})
                result=cell.c.recover()
                self.assertTrue(result['verifiedDisposal']);self.assertTrue(result['deleteOperationSucceeded'])
                self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_invalid_preferred_header_never_falls_back_or_replays_delete(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            good=monitor(cell)
            install(cell,{'azure-asyncoperation':'https://foreign.invalid/secret','location':good}, {})
            with self.assertRaisesRegex(Refused,'delete-monitor-origin'):cell.c.recover()
            self.assertFalse(any('secret' in str(e) for e in cell.c.journal.events))
            reopen(cell)
            result=cell.c.recover()
            self.assertFalse(result['verifiedDisposal']);self.assertTrue(result['operationEvidenceIncomplete'])
            self.assertFalse(any(p==urlsplit_path(good) for m,h,p,headers in cell.provider.sent))
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_recovery_resumes_saved_url_after_interruption_no_delete_replay(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            url=monitor(cell,suffix='&monitor=true')
            install(cell,{'location':url,'retry-after':'0'},{url:[(204,None)]})
            with patch.object(cell.c,'reconcile_delete',side_effect=Refused('synthetic-interruption')):
                with self.assertRaisesRegex(Refused,'synthetic-interruption'):cell.c.recover()
            reopen(cell)
            result=cell.c.recover()
            self.assertTrue(result['verifiedDisposal'])
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)
            self.assertTrue(any(p==urlsplit_path(url) for m,h,p,headers in cell.provider.sent))

    def test_failure_is_durable_and_recovery_never_repolls(self):
        for state in ('Failed','Canceled'):
            with self.subTest(state=state),recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
                url=monitor(cell)
                install(cell,{'azure-asyncoperation':url,'retry-after':'0'},{url:[(200,{'status':state})]})
                with self.assertRaisesRegex(Refused,'delete-failed'):cell.c.recover()
                before=len(cell.provider.sent)
                reopen(cell)
                with self.assertRaisesRegex(Refused,'delete-failed'):cell.c.recover()
                # The fresh subscription context GET is allowed, no monitor GET.
                self.assertEqual(len(cell.provider.sent),before+1)
                self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_polls_shared_across_recovery_and_limited_to_twelve(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            url=monitor(cell)
            install(cell,{'azure-asyncoperation':url,'retry-after':'0'},
                    {url:[(200,{'status':'InProgress'},[('Retry-After','0')])]*12})
            with self.assertRaisesRegex(Refused,'delete-completion-unproven'):cell.c.recover()
            reopen(cell)
            with self.assertRaisesRegex(Refused,'delete-completion-unproven'):cell.c.recover()
            self.assertEqual(sum(p==urlsplit_path(url) for m,h,p,headers in cell.provider.sent),12)
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_saved_success_is_reused_without_repoll(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            url=monitor(cell)
            install(cell,{'location':url,'retry-after':'0'},{url:[(204,None)]})
            cell.c.recover();reopen(cell)
            self.assertTrue(cell.c.recover()['verifiedDisposal'])
            self.assertEqual(sum(p==urlsplit_path(url) for m,h,p,headers in cell.provider.sent),1)
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_route_policy_rejects_foreign_secret_and_unapproved_queries(self):
        with recovery_cell() as cell:
            url=monitor(cell)
            for bad in (url.replace('https:','http:'),url.replace('management.azure.com','foreign.invalid'),
                        url.replace(cell.g.plan['subscription'],'99999999-9999-9999-9999-999999999999'),
                        url+'&sig=secret',url+'&api-version=2022-09-01',url.replace('2018-08-01','2099-01-01'),
                        url+'#fragment',url.replace('management.azure.com','user@management.azure.com'),
                        url.replace('operationresults','resourceGroups'),url+'&monitor=false',url+'&%6donitor=true'):
                with self.subTest(url=bad),self.assertRaises(Refused):validate_delete_monitor(cell.g.plan,bad)
            for api in ('2018-08-01','2020-10-01','2021-04-01','2022-09-01'):
                self.assertEqual(validate_delete_monitor(cell.g.plan,monitor(cell,api=api)),monitor(cell,api=api))

    def test_protocol_distinguishes_acceptance_failure_and_empty_responses(self):
        self.assertEqual(delete_monitor_state('location',202,None),'Pending')
        self.assertEqual(delete_monitor_state('location',204,None),'Succeeded')
        self.assertEqual(delete_monitor_state('location',200,{}),'Succeeded')
        self.assertEqual(delete_monitor_state('async',200,{'status':'Succeeded'}),'Succeeded')
        for kind,status,value in (('async',204,None),('async',200,{}),
                                  ('async',200,{'properties':{'provisioningState':'Succeeded'}}),
                                  ('async',200,{'properties':{'provisioningState':'Failed'}}),
                                  ('async',200,{'properties':{'provisioningState':'Running'}}),
                                  ('location',202,{'status':'Succeeded'}),
                                  ('location',204,{}),('location',200,{'error':{}}),('location',200,[])):
            with self.subTest(kind=kind,status=status),self.assertRaises(Refused):delete_monitor_state(kind,status,value)

    def test_retry_after_is_bounded_and_used_before_poll(self):
        for bad in ('61','999','-1','1.0','Wed, 28 Oct 2026 18:00:00 GMT',1):
            with self.assertRaises(Refused):monitor_retry_after({'retry-after':bad})
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep) as sleep:
            url=monitor(cell)
            install(cell,{'location':url,'retry-after':'2'},{url:[(204,None)]})
            cell.c.recover();sleep.assert_any_call(2)

    def test_no_header_202_is_not_verified_and_synchronous_204_is(self):
        for status in (202,204):
            with self.subTest(status=status),recovery_cell() as cell:
                before=cell.provider.on_request
                def request(method,path,body):
                    before(method,path,body)
                    if method=='DELETE':cell.provider.routes[path]=(status,{})
                cell.provider.on_request=request
                result=cell.c.recover()
                self.assertEqual(result['verifiedDisposal'],status==204)
                self.assertEqual(result['operationEvidenceIncomplete'],status==202)

    def test_unknown_delete_later_absence_remains_unverified(self):
        with recovery_cell() as cell:
            before=cell.provider.on_request
            def request(method,path,body):
                before(method,path,body)
                if method=='DELETE':raise Refused('synthetic-response-lost')
            cell.provider.on_request=request
            result=cell.c.recover()
            self.assertTrue(result['unknownDeleteOutcome']);self.assertFalse(result['verifiedDisposal'])
            reopen(cell)
            self.assertFalse(cell.c.recover()['verifiedDisposal'])
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_monitor_wait_cannot_cross_original_recovery_deadline(self):
        with recovery_cell() as cell:
            url=monitor(cell)
            install(cell,{'location':url,'retry-after':'2'},{})
            with patch.object(cell.c,'reconcile_delete',side_effect=Refused('synthetic-interruption')):
                with self.assertRaises(Refused):cell.c.recover()
            cell.c.clock=lambda:cell.c._start+7199
            before=len(cell.provider.sent)
            with self.assertRaisesRegex(Refused,'delete-monitor-wait-deadline'):cell.c.reconcile_delete()
            self.assertEqual(len(cell.provider.sent),before)

    def test_terminal_failure_survives_irrelevant_malformed_retry_after(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            url=monitor(cell)
            install(cell,{'azure-asyncoperation':url,'retry-after':'0'},
                    {url:[(200,{'status':'Failed','error':{'code':'SyntheticFailure'}},[('Retry-After','invalid')])]})
            with self.assertRaisesRegex(Refused,'delete-failed'):cell.c.recover()
            reopen(cell)
            with self.assertRaisesRegex(Refused,'delete-failed'):cell.c.recover()
            self.assertEqual(sum(p==urlsplit_path(url) for m,h,p,headers in cell.provider.sent),1)

    def test_interrupted_poll_waits_maximum_delay_without_refunding_slot(self):
        def fast_sleep(seconds):actual_sleep(seconds if seconds<1 else 0)
        for interrupted_number in (1,2):
            with self.subTest(poll=interrupted_number),recovery_cell() as cell,patch('native.time.sleep',side_effect=fast_sleep) as sleep:
                url=monitor(cell)
                earlier=[(200,{'status':'InProgress'},[('Retry-After','0')])]*(interrupted_number-1)
                install(cell,{'azure-asyncoperation':url,'retry-after':'0'},
                        {url:earlier+[(200,{'status':'InProgress'},[('Retry-After','60')]),(200,{'status':'Succeeded'})]})
                original=cell.c.append
                def interrupted(event,data):
                    if event=='delete-monitor-status' and data['number']==interrupted_number:
                        raise Refused('synthetic-response-not-journaled')
                    return original(event,data)
                with patch.object(cell.c,'append',side_effect=interrupted):
                    with self.assertRaisesRegex(Refused,'synthetic-response-not-journaled'):cell.c.recover()
                # The conservative delay must still fit the same original clock.
                clock=cell.c.clock;cell.c.clock=lambda:cell.c._start+7190
                before=len(cell.provider.sent)
                with self.assertRaisesRegex(Refused,'delete-monitor-wait-deadline'):cell.c.reconcile_delete()
                self.assertEqual(len(cell.provider.sent),before)
                cell.c.clock=clock
                reopen(cell)
                self.assertTrue(cell.c.recover()['verifiedDisposal'])
                sleep.assert_any_call(60)
                slots=[e['data']['number'] for e in cell.c.journal.events if e['event']=='delete-monitor-poll']
                self.assertEqual(slots,list(range(1,interrupted_number+2)))
                self.assertEqual(sum(p==urlsplit_path(url) for m,h,p,headers in cell.provider.sent),interrupted_number+1)
                self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)

    def test_query_substitution_rejected_by_worker_before_auth(self):
        with recovery_cell() as cell,patch('native.time.sleep',wraps=actual_sleep):
            url=monitor(cell)
            install(cell,{'location':url,'retry-after':'0'},{url:[(204,None)]})
            def mutate(frame):
                if frame['request']['provenance'].get('kind')=='delete-operation':
                    frame['request']['url']=url+'&monitor=true'
                return frame
            cell.provider.mutate_frame=mutate
            with self.assertRaises(Refused):cell.c.recover()
            self.assertFalse(any(p==urlsplit_path(url+'&monitor=true') for m,h,p,headers in cell.provider.sent))
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)


if __name__=='__main__':unittest.main(verbosity=2)
