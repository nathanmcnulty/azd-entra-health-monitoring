# Deployment-agent working agreements

- Use the exact supported quickstart: `azd init -t nathanmcnulty/azd-entra-health-monitoring && azd up`.
- Never use, initiate, or recommend device-code authentication.
- Keep tenant and subscription discovery separate from deployment writes; confirm the selected scope before changes.
- Do not bypass Microsoft Graph admin consent, Teams browser consent, or tenant validation.
- Never print or persist access tokens, consent-link contents, callback URLs, or credentials.
- Treat cleanup as Azure-resource cleanup only; verify ownership before any separate tenant-side Graph subscription action.

See [agent-assisted deployment](docs/agent-assisted-deployment.md) for the administrator-facing workflow.
