// Offline candidate only; the public controller has no live entrypoint.
targetScope = 'resourceGroup'
param materialize bool = false
param attemptId string
@minLength(1)
param operatorCidrs array
@minLength(1)
param nestedStubCidrs array
@secure()
param fixtureStubCallback string = ''

var aliases = [
  'receiver-duplicate'
  'receiver-mismatch'
  'lifecycle-create'
  'response-stub'
]
var definitions = [
  loadJsonContent('../validation/m21-generated/receiver-duplicate.json')
  loadJsonContent('../validation/m21-generated/receiver-mismatch.json')
  loadJsonContent('../validation/m21-generated/lifecycle-create.json')
  loadJsonContent('../validation/m21-generated/response-stub.json')
]
var parameters = [
  {
    GraphSubscriptionClientState: { value: 'fixture-client-state' }
    TargetChannelDisplayName: { value: 'Fixture Channel' }
  }
  {
    GraphSubscriptionClientState: { value: 'fixture-client-state' }
    TargetChannelDisplayName: { value: 'Fixture Channel' }
  }
  {
    GraphSubscriptionClientState: { value: 'fixture-client-state' }
    FixtureStubCallback: { value: fixtureStubCallback }
    FixtureAttemptId: { value: attemptId }
  }
  { FixtureAttemptId: { value: attemptId } }
]
resource fixtures 'Microsoft.Logic/workflows@2019-05-01' = [for (alias, i) in aliases: if (materialize) {
  name: 'm21-${alias}'
  location: resourceGroup().location
  properties: {
    state: 'Disabled'
    definition: definitions[i]
    parameters: parameters[i]
    accessControl: {
      triggers: {
        allowedCallerIpAddresses: [for cidr in (i == 3 ? nestedStubCidrs : operatorCidrs): { addressRange: cidr }]
      }
    }
  }
}]
