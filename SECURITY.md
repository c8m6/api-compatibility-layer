# Security policy

## Reporting a vulnerability

Use GitHub private vulnerability reporting for suspected vulnerabilities once
the repository is public and private reporting is enabled. Until then, contact
the repository maintainer privately.

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
