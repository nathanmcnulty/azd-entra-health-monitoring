"""Synthetic readback regressions; no credential or network access."""
import copy
from contextlib import ExitStack
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts/m21'))
from control import Refused,digest
from native import NativeController,parameter_types,lock_scope
from test_m21_readiness import plan,Transport,Clock


class SchemaIdentityTests(unittest.TestCase):
    def controller(self,d):
        return NativeController(plan(),Path(d)/'journal',Transport(),Clock())

    def test_parameter_enum_spellings_preserve_pinned_definition_and_digest(self):
        from build_fixture import candidate_plan
        p=candidate_plan({k:plan()[k] for k in ('attempt','kind','subscription','group','operator_cidr','stub_cidrs','disposition')})
        with tempfile.TemporaryDirectory() as d, ExitStack() as cleanup:
            c=NativeController(p,Path(d)/'journal',Transport(),Clock())
            cleanup.callback(c.close)
            for alias,body in p['bodies'].items():
                observed=copy.deepcopy(body)
                observed.update(id=c.workflow_url(alias).removeprefix('https://management.azure.com'),name='m21-'+alias)
                observed['properties'].update(provisioningState='Succeeded',accessEndpoint='https://example.invalid')
                definition=observed['properties']['definition']
                for declaration in definition['parameters'].values():
                    if declaration['type']=='securestring':declaration['type']='SecureString'
                    elif declaration['type']=='String':declaration['type']='string'
                before=copy.deepcopy(observed)
                c.validate_workflow(alias,observed,'Disabled')
                self.assertEqual(observed,before)
                self.assertEqual(digest(c._observed_configs[alias]['properties']['definition']),digest(body['properties']['definition']))
                for bad in ('SECURESTRING','secureString','String',None,[],{}):
                    if 'GraphSubscriptionClientState' not in definition['parameters']:continue
                    changed=copy.deepcopy(observed)
                    changed['properties']['definition']['parameters']['GraphSubscriptionClientState']['type']=bad
                    with self.subTest(alias=alias,bad=bad),self.assertRaises(Refused):c.validate_workflow(alias,changed,'Disabled')

    def test_no_normalization_of_schema_action_default_or_payload_types(self):
        expected={'parameters':{'p':{'type':'Object','defaultValue':{'type':'String'}}},
                  'actions':{'a':{'type':'Http','inputs':{'body':{'type':'String'},'schema':{'type':'object'}}}}}
        for path,value in ((('parameters','p','defaultValue','type'),'string'),
                           (('actions','a','type'),'http'),
                           (('actions','a','inputs','body','type'),'string'),
                           (('actions','a','inputs','schema','type'),'Object')):
            changed=copy.deepcopy(expected);node=changed
            for part in path[:-1]:node=node[part]
            node[path[-1]]=value
            self.assertNotEqual(parameter_types(changed,expected),expected)

    def test_lock_names_are_scope_local_and_duplicate_full_ids_refuse_across_pages(self):
        with tempfile.TemporaryDirectory() as d, ExitStack() as cleanup:
            c=self.controller(d);sub='/subscriptions/'+c.plan['subscription']
            cleanup.callback(c.close)
            url='https://management.azure.com'+sub+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01'
            def row(scope):return {'id':scope+'/providers/Microsoft.Authorization/locks/guard','name':'guard',
                                   'type':'Microsoft.Authorization/locks','properties':{'level':'ReadOnly'}}
            first=row(sub+'/resourceGroups/other');second=row(sub+'/resourceGroups/another')
            def pages(last):
                values=iter([{'value':[first],'nextLink':url+'&page=2'},{'value':[last]}])
                c.observe=lambda *a,**k:next(values)
            pages(second);self.assertEqual(len(c.collection(url)),2)
            duplicate=copy.deepcopy(first);duplicate['id']=duplicate['id'].upper()
            pages(duplicate)
            with self.assertRaisesRegex(Refused,'duplicate-collection-identity'):c.collection(url)
            for mutate in (lambda r:r.update(name='wrong'),lambda r:r.update(type='Other'),
                           lambda r:r.update(id='/subscriptions/foreign/providers/Microsoft.Authorization/locks/guard'),
                           lambda r:r.update(properties={'level':'Unknown'})):
                bad=copy.deepcopy(second);mutate(bad);pages(bad)
                with self.assertRaises(Refused):c.collection(url)
            for scope in (sub,c.group_url.removeprefix('https://management.azure.com'),
                          c.workflow_url('receiver-duplicate').removeprefix('https://management.azure.com')):
                self.assertEqual(lock_scope(row(scope),c.plan['subscription']),scope.casefold())
            # Other collection identity policies remain unchanged.
            c.observe=lambda *a,**k:{'value':[{'id':'a','name':'same'},{'id':'b','name':'same'}]}
            with self.assertRaisesRegex(Refused,'duplicate-collection-identity'):c.collection(c.group_url+'/resources?api-version=2021-04-01')


if __name__=='__main__':unittest.main()
