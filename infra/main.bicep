param environmentName string
param location string = resourceGroup().location
param logicAppName string

param targetTeamId string
param targetChannelId string
param targetChannelDisplayName string = ''

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))
var graphSubscriptionClientState = guid(subscription().id, resourceGroup().id, environmentName, logicAppName, 'graph-subscription-client-state')
var tags = {
  'entra-health-env': environmentName
}
var teamsConnectionName = 'teams-${resourceToken}'
var workflowDefinition = json(loadTextContent('workflow-definition.json'))
var lifecycleWorkflowDefinition = json(loadTextContent('lifecycle-workflow-definition.json'))
var managedApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
var lifecycleWorkflowName = 'la-graph-subscription-management'

resource teamsConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: teamsConnectionName
  location: location
  kind: 'V1'
  tags: tags
  properties: {
    displayName: 'Microsoft Teams'
    customParameterValues: {}
    api: {
      id: managedApiId
    }
  }
}

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    state: 'Enabled'
    definition: workflowDefinition
    parameters: {
      TargetTeamId: {
        value: targetTeamId
      }
      TargetChannelId: {
        value: targetChannelId
      }
      TargetChannelDisplayName: {
        value: targetChannelDisplayName
      }
      GraphSubscriptionClientState: {
        value: graphSubscriptionClientState
      }
      '$connections': {
        value: {
          teams: {
            connectionId: teamsConnection.id
            connectionName: teamsConnection.name
            id: managedApiId
          }
        }
      }
    }
  }
}

resource lifecycleWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: lifecycleWorkflowName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    state: 'Enabled'
    definition: lifecycleWorkflowDefinition
    parameters: {
      NotificationUrl: {
        value: listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', logicApp.name, 'When_a_HTTP_request_is_received'), '2016-06-01').value
      }
      GraphSubscriptionClientState: {
        value: graphSubscriptionClientState
      }
    }
  }
}

output LOGIC_APP_NAME string = logicApp.name
output LOGIC_APP_RESOURCE_ID string = logicApp.id
output LOGIC_APP_PRINCIPAL_ID string = logicApp.identity.principalId
output LIFECYCLE_LOGIC_APP_NAME string = lifecycleWorkflow.name
output LIFECYCLE_LOGIC_APP_RESOURCE_ID string = lifecycleWorkflow.id
output LIFECYCLE_LOGIC_APP_PRINCIPAL_ID string = lifecycleWorkflow.identity.principalId
output TEAMS_CONNECTION_NAME string = teamsConnection.name
output TEAMS_CONNECTION_RESOURCE_ID string = teamsConnection.id
