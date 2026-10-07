# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/c8m6/api-compatibility-layer/security/advisories/new)
when it is available and enabled for this repository. A GitHub account is
required. Open the repository's **Security** tab and select
**Report a vulnerability**.

If that option is unavailable, including while the repository is private, open
an issue asking only for a private security contact. Do not include vulnerability
details, affected sensitive endpoints, exploit instructions or attachments in
that issue. Wait until a private channel has been agreed before sharing details.
No email address or alternative private channel is published here.

Do not disclose exploitable, undisclosed vulnerabilities in public issues or
pull requests. Use synthetic data in reproductions and never include production
credentials, tokens, internal endpoints, or other secrets.

## Versions

Release tags are the authoritative application version source. No long-term
support or security-backport policy is currently promised.

## Scope

API Compatibility Layer translates HTTP requests according to declarative
configuration. Treat mapping configuration as trusted input. A passing automated
security scan does not prove that no vulnerabilities remain.
