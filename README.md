# Entra Health Monitoring

This `azd` project deploys a secret-free Microsoft Entra Health notification pipeline with two Logic App Consumption workflows:

- `la-entra-health-alerts`
  - receives Microsoft Graph change notifications for `/beta/reports/healthmonitoring/alerts`
  - validates the webhook handshake and acknowledges notifications quickly
  - reads alert details with its managed identity
  - posts alerts to a Teams channel
  - posts a warning when a delivered notification shows the subscription expires in 7 days or less
- `la-graph-subscription-management`
  - runs daily
  - uses managed identity to create the subscription if missing
  - reauthorizes and renews 10 days before expiration
  - relays renewal failure warnings to the alert workflow starting 7 days before expiration

## Architecture

```mermaid
flowchart LR
    G[Microsoft Graph<br/>Entra Health alerts] --> S[Graph subscription]
    S --> A[Alert Logic App<br/>la-entra-health-alerts]
    A --> D[Get alert details<br/>Managed identity]
    D --> T[Teams channel]
    L[Lifecycle warnings] --> A
```

```mermaid
flowchart LR
    R[Daily recurrence] --> L[Lifecycle Logic App<br/>la-graph-subscription-management]
    L --> Q[List subscriptions<br/>Managed identity]
    Q --> C{Match found?}
    C -- No --> N[Create subscription]
    C -- Yes --> E{Expiring within 10 days?}
    E -- Yes --> Z[Reauthorize and renew]
    E -- No --> X[Exit]
    Z --> T[Relay warning to alert workflow<br/>within 7 days]
```

## What `azd up` does

`azd up` runs `azd provision`, which uses project hooks to:

1. Prompt for the resource group name, alert Logic App name, and Teams channel link when they are not already set.
2. Show recommended defaults inline in the prompts so you can press Enter to accept them or provide your own values.
3. Parse `TEAMS_CHANNEL_LINK` and store the team, channel, and tenant IDs in the `azd` environment before infrastructure parameters are resolved.
4. Provision both Logic App Consumption workflows with system-assigned managed identities.
5. Provision a Microsoft Teams connection resource.
6. After the Teams connection is authenticated, grant the alert workflow `HealthMonitoringAlert.Read.All`.
7. Grant the lifecycle workflow `HealthMonitoringAlertConfig.ReadWrite.All`.

## Authentication

- The deployed solution is secret-free.
- The alert workflow uses managed identity for Microsoft Graph alert reads.
- The lifecycle workflow uses managed identity for Graph subscription lifecycle operations.
- The lifecycle workflow does not post to Teams directly. It relays warning messages to the alert workflow webhook.
- The Teams connector uses the user-authorized Logic Apps connection.
- The signed-in operator's delegated Graph token is used only during provisioning to grant Graph app roles to the workflows' managed identities.

## Inputs

The user provides:

- Azure subscription through the normal `azd` selection experience
- Azure resource group name
- Alert Logic App name
- `TEAMS_CHANNEL_LINK`

The project derives the team ID, channel ID, tenant ID, webhook URL, Logic App principal IDs, and resource IDs automatically.

## Usage

1. Create an environment.

```powershell
azd env new <environment-name>
```

2. Provision the solution.

```powershell
azd up
```

When prompted for `TEAMS_CHANNEL_LINK`, in Microsoft Teams right-click the target channel, select Copy link, and paste that link into the terminal.

3. If `postprovision` prints a Teams consent URL, open it, complete the sign-in flow, and rerun the hook.

```powershell
azd hooks run postprovision
```

4. Check deployment status.

```powershell
pwsh ./scripts/status.ps1
```

## Status Output

`status.ps1` prints:

- alert Logic App name
- lifecycle Logic App name
- resource group
- webhook URL
- Teams connection status
- latest lifecycle workflow run status and start time

## Notes

- No app registration or app secret is required for the deployed solution.
- `la-graph-subscription-management` is intended to be the supported owner for this app's Graph subscription lifecycle.
