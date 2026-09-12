# Agent-assisted deployment

An agent may inspect prerequisites, explain the two managed-identity Graph roles, validate the Teams link format, and review deployment output. The administrator selects the tenant, subscription, resource group, and Teams sender identity.

Before any deployment write, confirm the selected tenant and subscription and explain that `azd up` creates two Logic Apps, managed identities, a Teams connection, and Graph application-role assignments. Have a **Global Administrator or Privileged Role Administrator** complete or pre-stage Microsoft Graph app-role consent, while the feature operator completes Azure and Teams browser consent. Never provide tokens, credentials, callback URLs, or consent-link contents to an agent.

An instruction to deploy does not authorize bypassing Graph consent, switching tenants, weakening authentication, or deleting a Graph subscription. If consent or tenant validation fails, stop and report the blocker. Review the post-deployment summary and authoritative portal state before declaring the setup complete.
