// Offline-reviewed candidate only. No controller can deploy this template.
// Default false creates no workflow resources. All four stay Disabled even when materialized.
targetScope = 'resourceGroup'

param materialize bool = false
param location string = resourceGroup().location

@secure()
param fixtureStubCallback string = ''

resource duplicate 'Microsoft.Logic/workflows@2019-05-01' = if (materialize) {
  name: 'm20-receiver-duplicate'
  location: location
  properties: {
    state: 'Disabled'
    definition: loadJsonContent('../validation/m20-generated/cases/receiver-duplicate-batch/definition.json')
    parameters: {
      GraphSubscriptionClientState: { value: 'fixture-client-state' }
      TargetChannelDisplayName: { value: 'Fixture Channel' }
    }
  }
}

resource mismatch 'Microsoft.Logic/workflows@2019-05-01' = if (materialize) {
  name: 'm20-receiver-mismatch'
  location: location
  properties: {
    state: 'Disabled'
    definition: loadJsonContent('../validation/m20-generated/cases/receiver-mismatched-state/definition.json')
    parameters: {
      GraphSubscriptionClientState: { value: 'fixture-client-state' }
      TargetChannelDisplayName: { value: 'Fixture Channel' }
    }
  }
}

resource lifecycle 'Microsoft.Logic/workflows@2019-05-01' = if (materialize) {
  name: 'm20-lifecycle-create'
  location: location
  properties: {
    state: 'Disabled'
    definition: loadJsonContent('../validation/m20-generated/cases/lifecycle-create/definition.json')
    parameters: {
      GraphSubscriptionClientState: { value: 'fixture-client-state' }
      FixtureStubCallback: { value: fixtureStubCallback }
    }
  }
}

resource stub 'Microsoft.Logic/workflows@2019-05-01' = if (materialize) {
  name: 'm20-response-stub'
  location: location
  properties: {
    state: 'Disabled'
    definition: loadJsonContent('../validation/m20-generated/cases/lifecycle-create/response-stub-definition.json')
    parameters: {}
  }
}
