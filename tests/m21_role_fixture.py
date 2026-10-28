"""Invented RBAC identities; shape only, never private role/condition values."""


def synthetic_inherited_roles(subscription,tenant):
    """4root +5tenant-root +13subscription; one conditional assignment."""
    scopes=['/']*4+['/providers/Microsoft.Management/managementGroups/'+tenant]*5+['/subscriptions/'+subscription]*13
    rows=[]
    for i,scope in enumerate(scopes):
        name='10000000-0000-0000-0000-'+format(i+1,'012x')
        rows.append({'id':scope.rstrip('/')+'/providers/Microsoft.Authorization/roleAssignments/'+name,
            'name':name,'type':'Microsoft.Authorization/roleAssignments','properties':{
                'scope':scope,'principalId':'20000000-0000-0000-0000-'+format(i+1,'012x'),
                'principalType':('User','Group','ServicePrincipal')[i%3],
                'roleDefinitionId':'/providers/Microsoft.Authorization/roleDefinitions/30000000-0000-0000-0000-'+format(i+1,'012x'),
                'condition':"@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:ContainerName] StringEqualsIgnoreCase 'synthetic-fixture'" if i==21 else None,
                'conditionVersion':'2.0' if i==21 else None,'delegatedManagedIdentityResourceId':None,
                'createdOn':'2026-01-01T00:00:00Z','description':'Synthetic fixture; not a real role assignment'}})
    return rows
