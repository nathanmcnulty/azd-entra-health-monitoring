# Architecture

## Components and data flow

| Component | Responsibility | Identity | Data |
| --- | --- | --- | --- |
| Alert Logic App | Receive Graph change notifications, read details, post Teams messages | System-assigned managed identity | Health-alert payloads and subscription metadata |
| Lifecycle Logic App | Run daily, create or renew the Graph subscription, relay warnings | System-assigned managed identity | Subscription state and renewal status |
| Teams connection | Deliver alert messages to the selected channel | User-authorized connector identity | Channel destination and connection status |

The alert workflow exposes an HTTP callback URL for Graph notifications and acknowledges the validation handshake quickly. The lifecycle workflow sends renewal warnings to that endpoint. Both workflows are Azure Logic App Consumption resources in the selected resource group.

## Trust boundaries

Microsoft Graph health monitoring is a `/beta` API boundary. Azure managed identities perform runtime Graph operations; the operator's delegated token is used only during provisioning to grant the two application roles and obtain Teams consent metadata. No client secret is provisioned.

## Lifecycle

Pre-provision parses and tenant-checks the Teams link. Bicep creates the workflows, identities, and connection. Post-provision obtains the callback URL, waits for Teams authorization, grants the Graph roles idempotently, and prints a deployment summary.
