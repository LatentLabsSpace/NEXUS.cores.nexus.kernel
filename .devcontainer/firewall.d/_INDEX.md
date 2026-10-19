<!-- auto-index -->
# INDEX

> Firewall drop-in configuration directory — conf files enumerate allowed outbound domains, loaded by init-firewall.sh at container start

## Folders
| Name | Description |
|------|-------------|
| `_optional/` | Universal optional firewall allowlists — selected per module by FIREWALL_KERNEL_MODULES (default: all); a DNS resolution failure only logs a warning and continues |
| `_required/` | Universal hard-required firewall allowlists — hard-fail on a DNS miss when selected; selected via FIREWALL_KERNEL_MODULES (default: all); a DNS resolution failure here aborts the container boot |
