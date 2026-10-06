# AGENTS.md

## Project intent

API Compatibility Layer is a generic, declaratively configured HTTP API
compatibility and translation service.

The core must remain independent of Puppet, Empeira, DNS, IPAM products, Mockly,
and any vendor-specific API. Product-specific compatibility belongs entirely in
runtime configuration.

## Scope discipline

The core responsibility is:

1. match an incoming HTTP request;
2. extract configured values from path/query/header/body;
3. construct and send a configured backend HTTP request;
4. transform the backend response into the configured client response.

Do not add product-specific operations or names to the core to satisfy one
consumer. Prefer the smallest generic primitive that allows the behavior to be
expressed declaratively.

Mapping configuration is trusted input. Request data is untrusted input.

## Development

Use Ruby 3.4 and Bundler. Follow the established repository lint, test, security,
and container-validation commands. Keep runtime dependencies minimal.

Use Conventional Commits. Keep unrelated changes out of a commit and pull
request. Update README and examples when configuration behavior changes.

Release tags are the authoritative version source. Release container images are
built, tested, scanned, and only then published to Docker Hub. Container images
must carry OCI source, version, revision, creation-time, and Apache-2.0 license
metadata.

Never include real production API URLs, credentials, domains, network ranges,
vendor documentation, or private configuration in tests, examples, fixtures, or
documentation. Use synthetic data exclusively.
