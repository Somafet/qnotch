# Security

The released Windows app accepts input from other programs on your computer: a local HTTP endpoint (`127.0.0.1:47821`, token required), a named pipe and a command line verb. See [docs/notifications.md](docs/notifications.md). It also stores a GitHub token in Windows Credential Manager. A macOS app is not released yet; document its permissions, credentials, and transports before it ships.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through [GitHub's vulnerability reporting](https://github.com/Somafet/qnotch/security/advisories/new) with steps to reproduce. You should get a reply within a week.

Only the latest stable release of each available platform gets fixes. GitHub's global latest release is reserved for Windows updater compatibility; use the platform's own release channel to identify the supported version. See [release policy](docs/releases.md).
