# Identity and authentication

## Azure operator

The operator uses the normal `azd` and Azure CLI browser or operating-system sign-in flow. The selected Azure subscription and tenant must be the intended deployment scope. The operator needs permission to select or create the resource group and a Graph context that can inspect and assign the workload roles during postprovision.

## Microsoft Graph consent authority

The two workload roles below are Microsoft Graph application permissions. Tenant-wide consent or assignment of these Graph app roles must be completed by a **Global Administrator or Privileged Role Administrator**. This is separate from Azure resource deployment and Teams connection consent. The current postprovision hook performs the assignment with the deploying operator's delegated Graph token, so a deployment operator without the required Graph context may leave Azure resources and a Teams connection present while postprovision fails.

## Workload identities

Each Logic App has a system-assigned managed identity:

| Identity | Microsoft Graph application role | Purpose |
| --- | --- | --- |
| Alert workflow | `HealthMonitoringAlert.Read.All` | Read health-alert details after receiving notifications |
| Lifecycle workflow | `HealthMonitoringAlertConfig.ReadWrite.All` | Create, inspect, reauthorize, and renew health-alert subscriptions |

These roles are granted during `postprovision` using the operator's delegated Graph token after the Graph consent boundary is satisfied. The template does not create an app registration or store a client secret.

## Teams consent

The Teams API connection is created in Azure, then a browser consent link is printed when authorization is required. Complete it with the user or service account that should appear as the sender of Teams messages. The deployment waits for the connection to report ready; type `skip` only when deliberately postponing consent, then rerun `azd hooks run postprovision`.

## Security boundaries

The health-monitoring endpoint uses Microsoft Graph `/beta` resources. Validate the beta API behavior and the tenant's licensing/availability before production use. Keep the Teams channel link and deployment outputs private; never copy tokens or consent-link contents into logs or issues. `azd down` removes the Azure identities and therefore does not automatically remove a Graph subscription created by the lifecycle workflow.
