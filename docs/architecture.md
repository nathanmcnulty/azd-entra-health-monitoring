# Architecture

## Components and data flow

| Component | Responsibility | Identity | Data |
| --- | --- | --- | --- |
| Alert Logic App | Receive Graph change notifications, check the secret clientState, read details, post Teams messages | System-assigned managed identity | Health-alert payloads and subscription metadata |
| Lifecycle Logic App | Run daily, create or renew the Graph subscription, relay warnings | System-assigned managed identity | Subscription state and renewal status |
| Key Vault | Persist a random Graph notification clientState across deployments | Selected provisioning operator has secret get/set access | One 256-bit secret |
| Teams connection | Deliver alert messages to the selected channel | User-authorized connector identity | Channel destination and connection status |

The alert workflow exposes an HTTP callback URL for Graph notifications and acknowledges the validation handshake quickly. The lifecycle workflow sends renewal warnings to that endpoint. Both workflows are Azure Logic App Consumption resources in the selected resource group.

## Trust boundaries

Microsoft Graph health monitoring is a `/beta` API boundary. Azure managed identities perform runtime Graph operations; the operator's delegated token is used during provisioning to inspect and grant the two application roles and obtain Teams consent metadata. The Graph app-role consent/assignment authority is a separate **Global Administrator or Privileged Role Administrator** responsibility. No client secret is provisioned.

## Lifecycle

Pre-provision parses and tenant-checks the Teams link, verifies the selected Azure scope, and creates or reuses the Key Vault secret. Bicep injects it as a secure workflow parameter while creating the workflows, identities, and connection, and passes the alert workflow callback URL directly to the lifecycle workflow. Post-provision waits for Teams authorization, grants the Graph roles idempotently, and prints a deployment summary without the callback URL or clientState.
