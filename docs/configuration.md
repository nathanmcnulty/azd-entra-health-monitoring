# Configuration

The pre-provision hook prompts for these values and stores them in the current `azd` environment:

| Value | Default | Purpose |
| --- | --- | --- |
| `LOGIC_APP_NAME` | `la-entra-health-alerts` | Name of the alert workflow |
| `TEAMS_CHANNEL_LINK` | none | Teams channel link used to derive the target team and channel |

The link must be a supported Teams channel URL containing `groupId` and `tenantId`. Its tenant must match the selected Azure tenant.

The template derives `TARGET_TEAM_ID`, `TARGET_CHANNEL_ID`, `TARGET_CHANNEL_DISPLAY_NAME`, `TARGET_TENANT_ID`, `TEAMS_CONNECTION_NAME`, and the Logic App principal IDs. Azure passes the generated callback URL directly to the lifecycle workflow; treat it as a bearer credential and keep it out of terminal output and deployment reports.

The lifecycle workflow name is fixed as `la-graph-subscription-management`. The deployment location follows the selected resource group unless `AZURE_LOCATION` is already supplied by `azd`.
