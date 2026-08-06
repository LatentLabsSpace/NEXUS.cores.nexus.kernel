<!-- auto-index -->
# INDEX

> Firewall drop-in configuration directory — conf files enumerate allowed outbound domains, loaded by init-firewall.sh at container start

## Folders
| Name | Description |
|------|-------------|
| `_required/` | Universal hard-required allowlists — always loaded; a DNS miss aborts the boot |
| `_optional/` | Universal optional allowlists — always loaded; a DNS miss warns and continues |
