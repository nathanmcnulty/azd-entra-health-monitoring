# Entra Health Monitoring

This `azd` project deploys two Logic App Consumption workflows:

- `la-entra-health-alerts`
  - receives Microsoft Graph change notifications for `/beta/reports/healthmonitoring/alerts`
  - validates the webhook handshake and acknowledges notifications quickly
  - reads the alert details with its managed identity
  - posts the alert into a Teams channel with the Microsoft Teams connector
  - sends a warning if a delivered notification shows the subscription expires in 7 days or less
- `la-graph-subscription-management`
  - runs on a daily recurrence
  - uses managed identity to create the subscription if missing
  - starts renewal and reauthorization attempts 10 days before expiration
  - sends renewal failure warnings daily starting 7 days before expiration

## What `azd up` handles

`azd up` runs `azd provision`, which handles these steps through project hooks:

1. Prompts for the resource group name, alert Logic App name, and Teams channel link when they are not already set.
2. Parses `TEAMS_CHANNEL_LINK` and stores the team, channel, and tenant IDs in the `azd` environment.
3. Provisions both Logic App Consumption workflows with system-assigned managed identities.
4. Provisions a Microsoft Teams connection resource.
5. After the Teams connection is authenticated, grants the alert workflow `HealthMonitoringAlert.Read.All`.
6. Grants the lifecycle workflow `HealthMonitoringAlertConfig.ReadWrite.All`.

## Authentication model

The deployed solution remains secret-free.

- The alert workflow uses managed identity only for reading alert details.
- The lifecycle workflow uses managed identity only for Graph subscription lifecycle operations.
- The Teams connector uses the user-authorized Logic Apps connection.
- Delegated Graph auth is retained only as a fallback troubleshooting path, not the primary renewal mechanism.

## Usage

1. Create an `azd` environment.

```powershell
azd env new <environment-name>
```

2. Run provisioning and answer the prompts.

```powershell
azd up
```

3. If `postprovision` prints a Teams connection consent URL, open it, complete the sign-in and consent flow, and then rerun the hook.

```powershell
azd hooks run postprovision
```

4. Optionally limit the subscription to one alert type.

```powershell
azd env set GRAPH_ALERT_TYPE "mfaSignInFailure"
```

## What the user provides

- Azure subscription through the normal `azd` selection experience
- Azure resource group name
- Alert Logic App name
- `TEAMS_CHANNEL_LINK`
- `GRAPH_ALERT_TYPE` (optional)

The project derives the `groupId`, `channelId`, `tenantId`, webhook URL, Logic App principal IDs, and resource IDs automatically.

## Status

You can inspect the current deployment state with:

```powershell
pwsh ./scripts/status.ps1
```

The script prints both Logic App names, the webhook URL, Teams connection status, and the latest lifecycle workflow run status.

## Notes

- No app registration or app secret is required for the deployed solution.
- The lifecycle workflow is named `la-graph-subscription-management` so it can be reused as a pattern for other Graph subscription-based solutions.
