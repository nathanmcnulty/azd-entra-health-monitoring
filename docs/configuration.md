# Configuration

The pre-provision hook prompts for these values and stores them in the current `azd` environment:

| Value | Default | Purpose |
| --- | --- | --- |
| `LOGIC_APP_NAME` | `la-entra-health-alerts` | Name of the alert workflow |
| `TEAMS_CHANNEL_LINK` | none | Teams channel link used to derive the target team and channel |

The link must be a supported Teams channel URL containing `groupId` and `tenantId`. Its tenant must match the selected Azure tenant.

The template derives `TARGET_TEAM_ID`, `TARGET_CHANNEL_ID`, `TARGET_CHANNEL_DISPLAY_NAME`, `TARGET_TENANT_ID`, `TEAMS_CONNECTION_NAME`, and the Logic App principal IDs. Preprovision creates a 256-bit random `graph-subscription-client-state` secret in an environment-bound Key Vault and stores only its `akvs://` reference as `GRAPH_SUBSCRIPTION_CLIENT_STATE` in the current `azd` environment. [Azure Developer CLI resolves that reference](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/environment-secrets) into a secure Bicep parameter during provisioning. Repeated provisioning reuses the same secret value. Do not replace the reference with a plaintext value or rotate the secret while an existing Graph subscription is active.

The selected Azure CLI account must match `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID` in AzureCloud and have resource-group/Key Vault creation and Key Vault access-policy rights, plus secret `get` and `set` access. Use the same selected operator for `azd`, or separately grant its identity secret `get` so `azd` can resolve the Key Vault reference. The hook may create the selected resource group before Bicep provisioning so it can create the vault. If `AZURE_LOCATION` is unset, an existing resource group's location is used. A different or inaccessible vault/secret fails closed. Azure passes the generated callback URL directly to the lifecycle workflow; treat it as a bearer credential and keep it out of terminal output and deployment reports.

The lifecycle workflow name is fixed as `la-graph-subscription-management`. The deployment location follows the selected resource group unless `AZURE_LOCATION` is already supplied by `azd`.
