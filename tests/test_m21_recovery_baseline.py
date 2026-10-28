"""Synthetic nonempty RBAC recovery coverage; never authenticates or uses Azure.

The protected observation's shape is represented with invented identities and a
synthetic condition. This proves the controller comparison/stop behavior, not a
provider default or visibility of Azure descendants in an actual response.
"""
import copy
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_m21_native import GateFiles,Provider,FakeProcess,FakeJob,Clock,urlsplit_path
from control import Refused
from live_io import OwnedTransport
from native import NativeController
from m21_role_fixture import synthetic_inherited_roles


class RecoveryCell:
    def __init__(self,root):
        self.g=GateFiles(root)
        self.rows=synthetic_inherited_roles(self.g.plan['subscription'],self.g.packet['tenant'])
        self.g.set_baseline(self.rows)
        self.authority=self.g.authority();self.provider=Provider()
        self.c=NativeController(self.g.plan,Path(root)/'ledger',OwnedTransport(self.authority,
            popen=lambda argv,**kw:FakeProcess(argv,self.provider,**kw),job_factory=FakeJob),Clock())
        self.deleted=False;self.role_sweeps=0;self.before_role_sweep=None
        self.group=self.c.group_url;self.group_path=urlsplit_path(self.group+'?api-version=2022-09-01')
        self.scope=self.group.removeprefix('https://management.azure.com')
        self.role_url=self.group+'/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01'
        self.role_path=urlsplit_path(self.role_url)
        self.page2_url=self.role_url+'&$skipToken=fixture-page-2';self.page2_path=urlsplit_path(self.page2_url)
        self.provider.routes[self.group_path]=(201,{'id':self.scope,'location':'westus2','tags':{'attempt':self.g.plan['attempt']}})
        self.c.call('group-create',allowed=(201,))
        self.provider.routes[self.group_path]=(200,{'id':self.scope,'location':'westus2','tags':{'attempt':self.g.plan['attempt']}})
        sid=self.g.plan['subscription']
        self.provider.routes['/subscriptions/'+sid+'?api-version=2022-12-01']=(200,{'subscriptionId':sid,'tenantId':self.g.packet['tenant'],'state':'Enabled'})
        self.provider.routes['/subscriptions/'+sid+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01']=(200,{'value':[]})
        resources=[]
        for alias in self.c.plan['bodies']:
            url=self.c.workflow_url(alias);rid=url.removeprefix('https://management.azure.com')
            resources.append({'id':rid,'type':'Microsoft.Logic/workflows'})
            value=copy.deepcopy(self.c.plan['bodies'][alias]);value.update({'id':rid,'name':'m21-'+alias})
            value['properties'].update({'provisioningState':'Succeeded','accessEndpoint':'https://prod-00.westus2.logic.azure.com/workflows/id-'+alias})
            self.provider.routes[urlsplit_path(url+'?api-version=2019-05-01')]=(200,value)
            self.provider.routes[urlsplit_path(url+'/disable?api-version=2019-05-01')]=(200,{})
            self.provider.routes[urlsplit_path(url+'/runs?api-version=2019-05-01')]=(200,{'value':[]})
        self.provider.routes[urlsplit_path(self.group+'/resources?api-version=2021-04-01')]=(200,{'value':resources})
        self.set_roles(self.rows)
        self.provider.on_request=self.on_request

    def set_roles(self,rows,paged=True):
        values=copy.deepcopy(rows)
        self.provider.routes[self.role_path]=(200,{'value':values[:11],'nextLink':self.page2_url} if paged else {'value':values})
        self.provider.routes[self.page2_path]=(200,{'value':values[11:]})

    def on_request(self,method,path,body):
        if method=='GET' and path==self.role_path:
            self.role_sweeps+=1
            if self.before_role_sweep:self.before_role_sweep(self.role_sweeps)
        if method=='DELETE':
            self.deleted=True;self.provider.routes[self.group_path]=(202,{})
        if method=='GET' and self.deleted:
            absent={'error':{'code':'ResourceGroupNotFound','message':"Resource group '"+self.g.plan['group']+"' could not be found."}}
            if path==self.group_path:self.provider.routes[path]=(404,absent)
            for alias in self.c.plan['bodies']:
                if path==urlsplit_path(self.c.workflow_url(alias)+'?api-version=2019-05-01'):self.provider.routes[path]=(404,absent)

    def role_requests(self):return [(m,p) for m,h,p,headers in self.provider.sent if '/roleAssignments?' in p]

    def close(self):self.c.close();self.authority.close()


@contextmanager
def recovery_cell():
    with tempfile.TemporaryDirectory() as root:
        cell=RecoveryCell(root)
        try:yield cell
        finally:cell.close()


class RecoveryBaselineTests(unittest.TestCase):
    def assert_preserved(self,cell):
        self.assertFalse(cell.deleted)
        self.assertFalse(any(m=='DELETE' for m,h,p,headers in cell.provider.sent))
        self.assertFalse(any(e['event']=='native-recovery-gate' or
            (e['event']=='intent' and e['data']['id'].startswith('delete:')) for e in cell.c.journal.events))
        self.assertTrue(cell.role_requests())
        self.assertTrue(all(m=='GET' and '$filter' not in p for m,p in cell.role_requests()))

    def test_twenty_two_inherited_assignments_two_pages_two_snapshots(self):
        with recovery_cell() as cell:
            self.assertEqual(len(cell.rows),22)
            self.assertEqual([sum(r['properties']['scope']==s for r in cell.rows) for s in
                ('/','/providers/Microsoft.Management/managementGroups/'+cell.g.packet['tenant'],'/subscriptions/'+cell.g.plan['subscription'])],[4,5,13])
            self.assertEqual(sum(r['properties']['condition'] is not None for r in cell.rows),1)
            result=cell.c.recover()
            self.assertTrue(result['disposalObserved']);self.assertTrue(result['absenceObserved'])
            self.assertEqual(cell.role_sweeps,2);self.assertEqual(len(cell.role_requests()),4)
            self.assertTrue(all(m=='GET' and '$filter' not in p for m,p in cell.role_requests()))
            self.assertEqual(sum(m=='DELETE' for m,h,p,headers in cell.provider.sent),1)
            self.assertEqual(cell.c.counts['recovery'],len(cell.provider.sent)-1)

    def test_order_and_case_equivalent_inherited_identity(self):
        with recovery_cell() as cell:
            rows=copy.deepcopy(cell.rows)
            for r in rows:
                r['id']=r['id'].upper()
                for key in ('scope','principalId','roleDefinitionId'):r['properties'][key]=r['properties'][key].upper()
            cell.set_roles(list(reversed(rows)),paged=False)
            self.assertTrue(cell.c.recover()['disposalObserved'])
            self.assertEqual(len(cell.role_requests()),2)

    def test_security_relevant_drift_and_missing_baseline_refuse(self):
        for field,value in (('principalId','40000000-0000-0000-0000-000000000001'),
                ('roleDefinitionId','/providers/Microsoft.Authorization/roleDefinitions/40000000-0000-0000-0000-000000000002'),
                ('condition','unexpected-condition'),('conditionVersion',None),
                ('delegatedManagedIdentityResourceId','/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/foreign/providers/Microsoft.ManagedIdentity/userAssignedIdentities/foreign'),
                ('scope','/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/foreign'),('remove',None)):
            with self.subTest(field=field),recovery_cell() as cell:
                rows=copy.deepcopy(cell.rows)
                if field=='remove':rows.pop()
                else:rows[-1]['properties'][field]=value
                cell.set_roles(rows)
                with self.assertRaisesRegex(Refused,'role-baseline-changed'):cell.c.recover()
                self.assert_preserved(cell)

    def test_direct_and_descendant_assignments_on_later_page_refuse(self):
        for descendant in (False,True):
            with self.subTest(descendant=descendant),recovery_cell() as cell:
                extra=copy.deepcopy(cell.rows[-1]);scope=cell.scope+('/providers/Microsoft.Logic/workflows/m21-response-stub' if descendant else '')
                name='50000000-0000-0000-0000-000000000001'
                extra.update({'id':scope+'/providers/Microsoft.Authorization/roleAssignments/'+name,'name':name})
                extra['properties']['scope']=scope;cell.set_roles(cell.rows+[extra])
                with self.assertRaisesRegex(Refused,'role-baseline-changed'):cell.c.recover()
                self.assert_preserved(cell)
                self.assertTrue(any(p==cell.page2_path for m,p in cell.role_requests()))

    def test_failed_continuation_preserves_cell(self):
        with recovery_cell() as cell:
            cell.provider.routes[cell.page2_path]=(503,{'error':{'code':'SyntheticUnavailable'}})
            with self.assertRaisesRegex(Refused,'required-provider-status'):cell.c.recover()
            self.assert_preserved(cell)

    def test_invalid_continuations_never_qualify(self):
        for kind in ('false','cycle','off-scope','filter-narrowing'):
            with self.subTest(kind=kind),recovery_cell() as cell:
                if kind=='false':cell.provider.routes[cell.page2_path]=(200,{'value':cell.rows[11:],'nextLink':False})
                elif kind=='cycle':cell.provider.routes[cell.page2_path]=(200,{'value':[],'nextLink':cell.role_url})
                elif kind=='off-scope':cell.provider.routes[cell.page2_path]=(200,{'value':cell.rows[11:],'nextLink':'https://example.invalid/foreign'})
                else:cell.provider.routes[cell.page2_path]=(200,{'value':cell.rows[11:],'nextLink':cell.role_url+'&$filter=atScope()'})
                with self.assertRaises(Refused):cell.c.recover()
                self.assert_preserved(cell)
                self.assertFalse(any(host!='management.azure.com' for m,host,p,headers in cell.provider.sent))

    def test_duplicate_case_assignment_refuses(self):
        with recovery_cell() as cell:
            duplicate=copy.deepcopy(cell.rows[0]);duplicate['id']=duplicate['id'].upper()
            cell.set_roles(cell.rows+[duplicate])
            with self.assertRaisesRegex(Refused,'duplicate-collection-identity'):cell.c.recover()
            self.assert_preserved(cell)

    def test_second_snapshot_role_drift_refuses_delete(self):
        with recovery_cell() as cell:
            def change(sweep):
                if sweep==2:
                    rows=copy.deepcopy(cell.rows);rows[-1]['properties']['condition']='changed-after-first-snapshot';cell.set_roles(rows)
            cell.before_role_sweep=change
            with self.assertRaisesRegex(Refused,'role-baseline-changed'):cell.c.recover()
            self.assertEqual(cell.role_sweeps,2);self.assert_preserved(cell)

    def test_separate_process_reopens_original_ledger_without_new_authority_or_dispatch(self):
        with recovery_cell() as cell:
            original_counts=cell.c.counts;original_start=cell.c._start
            cell.c._capabilities['held-fixture']='SYNTHETIC_HELD_CAPABILITY'
            cell.c.close()  # Release writer; retain parent/controller/authority.
            code="""
import json,sys,os
sys.path.insert(0,sys.argv[1])
from live_io import Authority,OwnedTransport
from native import NativeController
def forbidden(*args,**kwargs):raise AssertionError('dispatch forbidden in ledger-only proof')
a=Authority(*sys.argv[3:6],recovery=True)
c=NativeController(a.plan,sys.argv[2],OwnedTransport(a,popen=forbidden),recovery=True)
try:print(json.dumps({'pid':os.getpid(),'start':c._start,'counts':c.counts,'frozen':c._frozen,'admitted':c._has_admission,'events':len(c.journal.events)}))
finally:c.close();a.close()
"""
            before=(cell.c.journal.root/'events.jsonl').read_bytes()
            child=subprocess.run([sys.executable,'-I','-B','-c',code,
                str(Path(__file__).resolve().parents[1]/'scripts/m21'),str(cell.c.journal.root),*cell.g.paths],
                capture_output=True,timeout=5,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            self.assertEqual(child.returncode,0,'ledger-only independent child failed')
            self.assertEqual(child.stderr,b'')
            observed=json.loads(child.stdout)
            self.assertNotEqual(observed['pid'],os.getpid());self.assertEqual(observed['counts'],original_counts)
            self.assertEqual(observed['start'],original_start);self.assertTrue(observed['frozen']);self.assertTrue(observed['admitted'])
            self.assertEqual((cell.c.journal.root/'events.jsonl').read_bytes(),before)
            self.assertEqual(cell.c._capabilities['held-fixture'],'SYNTHETIC_HELD_CAPABILITY')
            self.assertEqual(len(cell.provider.sent),1)  # Original fake creation only.


if __name__=='__main__':unittest.main()
