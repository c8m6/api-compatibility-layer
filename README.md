# API Compatibility Layer

[![CI](https://github.com/c8m6/api-compatibility-layer/actions/workflows/ci.yml/badge.svg)](https://github.com/c8m6/api-compatibility-layer/actions/workflows/ci.yml)
[![CodeQL](https://github.com/c8m6/api-compatibility-layer/actions/workflows/codeql.yml/badge.svg)](https://github.com/c8m6/api-compatibility-layer/actions/workflows/codeql.yml)
[![Release](https://img.shields.io/github/v/release/c8m6/api-compatibility-layer?include_prereleases&label=release)](https://github.com/c8m6/api-compatibility-layer/releases)
[![Docker Hub](https://img.shields.io/docker/v/c8m6/api-compatibility-layer?sort=semver&label=docker)](https://hub.docker.com/r/c8m6/api-compatibility-layer)
[![License](https://img.shields.io/github/license/c8m6/api-compatibility-layer)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-3.4-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)

A declarative compatibility layer for translating HTTP APIs.

A small Ruby 3.4 HTTP service turns one JSON API into another through trusted YAML
configuration. The engine has no knowledge of products, vendors or production
API paths. It has no database, persistence, UI, background jobs or telemetry.

## Architecture

```text
incoming HTTP request → method/path match → configured extraction
  → backend request construction → HTTP request → response transformation
  → client response
```

A route can also return a static response without calling a backend. WEBrick
serves HTTP; `net-http` sends backend requests. JSON, YAML, URI handling and
signals use Ruby's standard libraries. There is no framework, template evaluator,
scripting language or plugin system. Each matched request calls at most one backend.

## Quick start

Install Ruby 3.4 and Bundler, then:

```sh
bundle install
cp config/example.yaml config/config.yaml
bundle exec ruby bin/acl
curl http://localhost:8080/health
```

The health route returns `{"status":"ok"}` without any backend. The example
backend uses a reserved `.example.test` hostname and is deliberately unreachable;
replace its origin with your own test backend to exercise forwarding.

`ACL_CONFIG` selects a YAML file. The local default is `config/config.yaml`
(relative to the working directory); the container default is `/config/config.yaml`.
Configuration is loaded once before binding the socket. Missing files, malformed
YAML, duplicate keys, multiple documents, unknown options, invalid methods,
references or mappings abort startup with a diagnostic and exit code 1. Changes
require restarting the service. Runtime configuration is excluded from Git and
from the image.

## Configuration model

Top-level keys are `version: 1`, optional `listen`, optional `backends`, and a
non-empty `routes` array. The listen defaults are `0.0.0.0:8080`. Backend names
and extracted variable names use `[a-z][a-z0-9_]*`.

Each backend has a static `base_url`: an HTTP(S) origin, optionally ending in `/`.
Credentials, query strings, fragments and path prefixes are disallowed. Put the
complete backend path in the route. Only route values can be templated; object
keys, backend origins, backend names and HTTP methods are static.

This is the complete runnable [synthetic example](config/example.yaml):

```yaml
version: 1
listen:
  address: 0.0.0.0
  port: 8080
backends:
  inventory:
    base_url: http://inventory.example.test:9000
routes:
  - method: GET
    path: /health
    response:
      body: {status: ok}
  - method: GET
    path: /legacy/items
    backend:
      name: inventory
      method: GET
      path: /v2/resources
  - method: POST
    path: /legacy/items/:id
    extract:
      id: {from: path, key: id}
      region: {from: query, key: region}
      token: {from: header, key: Authorization}
      label: {from: body, pointer: /label}
      enabled: {from: body, pointer: /enabled}
    backend:
      name: inventory
      method: PUT
      path: /v2/resources/{{values.id}}
      query:
        location: '{{values.region}}'
      headers:
        Authorization: '{{values.token}}'
        X-Client: compatibility-example
      body:
        name: '{{values.label}}'
        active: '{{values.enabled}}'
    response:
      status: '{{backend.status}}'
      body:
        item: '{{backend.body:/resource/id}}'
        label: '{{backend.body:/resource/name}}'
  - method: DELETE
    path: /legacy/placeholder
    response:
      status: 204
      empty: true
```

For the example POST route, send a JSON body such as
`{"label":"Synthetic","enabled":false}`, a `region=north` query parameter and
an `Authorization: Bearer synthetic-token` header. The backend receives a PUT to
`/v2/resources/<id>?location=north`, the explicitly mapped headers and
`{"name":"Synthetic","active":false}`. A backend response such as
`{"resource":{"id":17,"name":"Synthetic"}}` becomes
`{"item":17,"label":"Synthetic"}`, with the backend's HTTP status.

### Route matching

Supported incoming and backend methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`.
Routes match method and path exactly, in declaration order; the first match wins.
Query parameters do not affect matching. Paths are case-sensitive and trailing
slashes matter. Literal path segments use ASCII letters, digits, `.`, `_`, `~`
`-` and literal `:` within a segment, such as `/items:lookup`. A segment starting
with `:` is reserved for a complete `:name` parameter, such as `/items/:id`.
`/items:lookup/:id` combines both forms; `/items/:id:suffix` is invalid. Only whole
parameter segments are normalized for duplicate detection, so `/items:a` and
`/items:b` are distinct. Parameter names cannot
repeat within a path. Identical method/path patterns (even with differently named
parameters) are rejected. Put specific routes before overlapping parameter routes.

Matching uses the raw, encoded request path. Captured parameters are percent-decoded
once, after matching; `+` in a path stays `+`. Encoded slashes therefore remain in
one captured segment. There are no glob patterns, user-defined regular expressions,
automatic HEAD/OPTIONS mappings or fallback routes. An unmatched request is 404.

### Extraction

`extract` maps variable names to one of:

| Source | Rule | Meaning |
| --- | --- | --- |
| Query | `{from: query, key: region}` | URL-decoded query value; duplicate keys use the last value |
| Header | `{from: header, key: Authorization}` | Case-insensitive header name; repeated fields are joined with `, ` |
| Path | `{from: path, key: id}` | A named route segment, decoded once |
| JSON | `{from: body, pointer: /items/0/id}` | A JSON Pointer into the request body |

Extractions are required: missing keys or unresolved pointers return 422 before
calling a backend. JSON `false` and `null` are values, not missing keys. An empty
request body has the JSON value `null`; a non-empty body must be JSON regardless
of its Content-Type. Invalid JSON returns 400 on matched routes.

JSON Pointer follows RFC 6901: `""` selects the whole document, `/name` selects
an object member, `/items/0` selects an array element, `~1` means `/`, and `~0`
means `~`. Array indices are zero-based decimal integers with no leading zeroes;
negative indices and `-` are unsupported. Dots are literal object-key characters.
There are no optional extractions, defaults, filters or wildcard selections.

### Templates and request transformation

The supported template references are:

| Reference | Available in | Value |
| --- | --- | --- |
| `{{values.name}}` | Backend path/query/headers/body and response body | Extracted value |
| `{{backend.status}}` | Response status/body | Backend status as an integer |
| `{{backend.body:/pointer}}` | Response body | Selected backend JSON value |
| `{{backend.body:}}` | Response body | Entire backend JSON document |
| `{{item:/pointer}}` / `{{item:}}` | Only `response.select.project` | A selected element value / entire selected element |

There is no whitespace inside a reference. Quote YAML strings containing templates.
A template that occupies the entire JSON value preserves its type, including
objects, arrays, booleans and null. A template embedded in a longer string accepts
only strings, numbers or booleans, converted to text. Null and structured values
cannot be embedded in strings, headers, query values or paths. JSON bodies are
constructed as Ruby data and serialized as JSON, never assembled by string parsing.

Path substitutions are always percent-encoded, including slashes, dots, question
marks and fragment characters. Query keys and scalar values use form URL encoding.
These operations prevent a request value from changing the configured origin or
adding path/query structure. Static backend paths must begin with one `/` and
contain no query, fragment, whitespace or backslash. Put query values in `query`.
Nested query structures and repeated outgoing query keys are unsupported.

Templates are processed once. A request value containing template delimiters,
Ruby, ERB or shell syntax remains data. There are no function calls, arithmetic,
conditions, loops, includes, environment interpolation or escaping operators.
Malformed delimiters and unknown references are startup errors. Literal `{{` and
`}}` in configured templated strings, and JSON Pointer keys containing those
delimiters, are not supported.

Backend headers are opt-in. No incoming headers (including Authorization) are
automatically forwarded or rejected. A mapping can read, ignore, replace or
forward a header. Header values reject control characters. Transport/framing
headers such as Host, Content-Length, Transfer-Encoding, Connection, Expect and
proxy authentication headers cannot be configured. The HTTP client owns them.
JSON bodies default to `Content-Type: application/json`; explicit content types
are permitted. No client cookies or backend response headers are forwarded.

### Response transformation and static responses

A backend route without `response` returns the backend HTTP status and parsed
JSON body; an empty backend body stays empty. A backend HTTP 4xx/5xx is an ordinary
response that mappings may transform. Redirects are returned as statuses without
following Location or forwarding it.

`response.status` is a fixed integer from 200 through 599, or exactly
`'{{backend.status}}'`. It defaults to the backend status (or 200 for a static
route). `response.body` is a JSON value with optional references. It can select
one backend value, rebuild an object or array, or supply a completely static body.
Omit `backend` entirely to avoid any outbound call:

```yaml
- method: GET
  path: /ready
  response:
    status: 200
    body: {ready: true}
```

Use `empty: true` for zero body bytes. `body`, `empty` and `select` are mutually exclusive. A configured
204, 205 or 304 requires `empty: true`; forwarded statuses of 204, 205 or 304 also
suppress the body. `body: null` returns JSON `null`, which is different from empty.
Non-empty responses use `application/json`. A static or empty response can ignore
an invalid/non-JSON backend body. Beyond the bounded selection below, there is no
array iteration. There is no status-dependent branching, pagination aggregation,
custom response-header mapping, streaming or
binary response transformation in this MVP. Requirements beyond these primitives
need a documented generic design before implementation.

### First-match selection and projection

Use `response.select` to select at most one array element and transform it:

```yaml
response:
  select:
    from: '{{backend.body:/items}}'
    where:
      /name: '{{values.name}}'
      /category: primary
    project:
      result: '{{item:/value}}'
```

`select` requires exactly `from`, `where` and `project`:

- `from` is a literal JSON array or one complete `{{backend.body:...}}` reference.
  A backend reference requires a configured backend. A literal array is data:
  even strings containing template delimiters are never expanded there.
- `where` is a non-empty mapping from valid JSON Pointers, relative to each
  element, to static JSON scalars (including null) or whole `{{values.name}}`
  references. Embedded string templates, backend references and item references
  are rejected here. Conditions are combined with AND, using JSON value equality
  without string/number/boolean conversion. JSON numbers `1` and `1.0` compare
  equal; `"1"` and `1` do not. Extracted arrays/objects compare structurally.
- A missing filter pointer means that element does not match; it is distinct
  from a present JSON null. The empty pointer selects the entire element,
  including scalar or array elements.
- The first matching element in source order wins. Only then is `project`
  rendered, using the existing JSON template rules and the additional `item`
  reference. The response body is always `[projected_value]`; even a projected
  array is one element, not flattened. Without a match the body is exactly `[]`
  and projection is not evaluated.

A dynamically resolved source that is not an array, a missing source pointer,
invalid backend JSON or a missing projection pointer returns
`502 response_mapping_failed`. Projection failures never fall through to a later
match. Syntax, references, source forms and JSON literals are checked at startup;
actual backend values are checked at runtime. The normal response status rules,
bodyless statuses and output size limit still apply. Backend errors are not
implicitly converted into successful empty results.

Static selection needs no backend, for example:

```yaml
- method: GET
  path: /catalog:lookup
  extract:
    name: {from: query, key: name}
  response:
    select:
      from:
        - {name: sample, value: available}
      where:
        /name: '{{values.name}}'
      project:
        state: '{{item:/value}}'
```

This is a bounded first-match primitive, with no OR, NOT, general conditions,
sorting, aggregation, multiple matches, configurable regex, query language,
functions or scripting. References are evaluated once; request and selected
values remain data. There are no string transformations or address calculations.

### Complete synthetic compatibility example

[config/integration-example.yaml](config/integration-example.yaml) demonstrates
all eight operations below against a synthetic collection API. Its backend origin
is a reserved example hostname and must be replaced with a test backend to run it.

| Operation | Mapping |
| --- | --- |
| `GET /zone_auth?fqdn=example.test` | Select from configured domain names; unknown names return `[]` |
| `GET /record:host?name=lb.example.test` | Static `[]` |
| `GET /record:a?name=lb.example.test` | Select backend element by both name and type, project its value |
| `GET /record:cname?name=alias.example.test` | Same selection primitive, different configured type and output key |
| `GET /ipv4address?network=192.0.2.0&status=UNUSED` | Static `[{"ip_address":"192.0.2.10"}]`, independent of query values |
| `POST /record:a` | Existing body extraction and backend JSON mapping, with a deterministic ID template |
| `POST /record:ptr` | Static 204 without a backend call |
| `POST /record:cname` | Existing body extraction and backend JSON mapping |

The synthetic backend contract is `GET /v1/entries` returning a complete array
of objects with `name`, `type` and `value`, and `POST /v1/entries` accepting those
fields plus a string `id`. IDs such as `A:{{values.name}}` are configured templates;
the engine does not generate or interpret them. Production ID constraints and
pagination require a compatible backend contract. The static test address makes
no claim about network membership or availability. All these operation names and
field meanings exist exclusively in configuration and tests, not in the core.
The RSpec expression test also creates entries over real local HTTP and reads
them back through the configured lookup mappings.

## Error behavior and operation

Application errors return JSON such as `{"error":"request_mapping_failed"}`:

| Status | Error | Cause |
| --- | --- | --- |
| 400 | `invalid_json` / `invalid_request` | Invalid client JSON or malformed decoded request data |
| 404 | `route_not_found` | No matching method/path |
| 413 | `payload_too_large` | Incoming body exceeds 1 MiB |
| 422 | `request_mapping_failed` | Missing extraction, wrong value type, invalid header or request mapping |
| 502 | `backend_error` | Network/TLS/protocol failure or oversized backend response |
| 502 | `response_mapping_failed` | Invalid backend JSON, unresolved response pointer or oversized mapped output |
| 504 | `backend_timeout` | Backend deadline exceeded |
| 500 | `internal_error` | Unexpected internal failure |

Malformed HTTP rejected by WEBrick before routing uses its HTTP error response.
Mapped backend request bodies, backend responses and client response bodies are
limited to 1 MiB each. The backend connect timeout is 3 seconds; individual read
and write timeouts are 5 seconds, with a 10-second overall backend deadline and
no retries. The server allows 32 simultaneous clients and a 15-second request I/O
timeout. These are fixed MVP limits, not new configuration options.

SIGTERM and SIGINT stop accepting requests and let active handlers finish. JSON
request logs go to stdout and include only the event and status. Startup errors
and fatal server diagnostics go to stderr. Request paths, query values, headers,
bodies, tokens and backend error details are not included in application logs.

## Container

```sh
docker build -t api-compatibility-layer:development .
docker run --rm --name acl -p 8080:8080 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$PWD/config/config.yaml,dst=/config/config.yaml,readonly" \
  api-compatibility-layer:development
```

Make the mounted configuration readable by UID/GID `10001:10001`; keep credentials
out of source control. To choose another path, set `-e ACL_CONFIG=/config/other.yaml`
and mount that file. No example or runtime configuration is copied into the image.
The Ruby 3.4 slim runtime contains production gems only and no added build tools.
The service runs as UID/GID 10001, with Ruby as PID 1.

Build args `APP_VERSION`, `APP_REVISION`, `APP_BUILD_TIME` (UTC ISO 8601) and
`APP_SOURCE` populate the corresponding OCI labels. The license label is always
`Apache-2.0`. Defaults describe a development build; release tags are the version
source. Optional BuildKit secret `proxy_ca` supplies a CA bundle during dependency
installation for environments with an HTTPS proxy; it is not copied into layers.

## Security

Configuration is trusted and determines all destinations and mappings. Restrict
who can edit or mount it. Request data is untrusted. YAML uses safe loading with
no object tags or aliases; templates never execute Ruby. Backend TLS certificate
verification is enabled. Backend origins are fixed; redirects are not followed,
and environment HTTP proxies are intentionally not used for backend calls.

Authentication and authorization are outside this service. If access control or
client-facing TLS is needed, deploy it behind a suitable gateway. Restrict inbound
access, backend egress and request rates there as appropriate. Read-only container
mounts and non-root execution do not replace that deployment policy. Mapping a
client's Authorization header to a backend is an explicit operator decision.

See [SECURITY.md](SECURITY.md) for private reporting and supported-version policy.
RSpec, RuboCop, bundler-audit, Ruby CodeQL and Trivy provide complementary checks;
a green scan is not a security guarantee. Brakeman is not used.

## Development and validation

```sh
bundle install
bundle exec rspec
bundle exec rubocop --force-exclusion
bundle exec bundler-audit check --update
docker build -t api-compatibility-layer:validation .
script/validate-image api-compatibility-layer:validation
mkdir -p tmp/security
trivy image --scanners vuln --format json --output tmp/security/trivy.json \
  api-compatibility-layer:validation
script/trivy-gate tmp/security/trivy.json
```

The image validation requires Docker; it runs synthetic HTTP translation and all
five methods inside the built image, checks non-root execution and OCI metadata,
and exercises both shutdown signals with a read-only filesystem. The Trivy gate
requires Trivy and `jq`: it saves all severities and SARIF, then fails for fixable
HIGH/CRITICAL vulnerabilities. Unfixed findings remain visible in reports. No
external backend or production data is needed by the tests. Optional `actionlint`
validates workflow syntax. Follow [CONTRIBUTING.md](CONTRIBUTING.md) and use
Conventional Commits.

## GitHub, releases and Docker Hub

PRs and pushes to `main` run RSpec, RuboCop and bundler-audit on Ruby 3.4 with
Bundler caching; obsolete runs are cancelled. The separate CodeQL workflow runs
on `main` pushes and manual dispatch, with Ruby and `build-mode: none`. Private
repositories need the applicable GitHub Code Security entitlement to run CodeQL;
workflow configuration does not enable or purchase that service.

The container workflow runs on published GitHub releases and manual dispatch.
It checks out the release tag/current ref, tests the code, audits gems, builds
with release metadata, validates the exact image, scans it and enforces the
fixable HIGH/CRITICAL gate before Docker Hub login and push. Security reports are
retained as artifacts for 14 days, including on a failing gate. A manual run
validates only; it never publishes images or changes release notes.

Configure these repository settings before a first publication:

| Name | GitHub setting |
| --- | --- |
| `DOCKERHUB_USERNAME` | Repository variable |
| `DOCKERHUB_IMAGE` | Repository variable, `namespace/repository` |
| `DOCKERHUB_TOKEN` | Repository secret, with push permission for that image |

Published images receive the exact GitHub release tag. There is no automatic
`latest` tag and no rebuild between scanning and pushing. Use Conventional Commit
history and tags such as `v0.1.0` (a valid Docker tag). After successful publication,
`git-cliff` and [cliff.toml](cliff.toml) generate notes for that release from feature,
fix, performance and refactoring commits and update the existing GitHub release.
The workflows never create a GitHub release themselves. GitHub Actions and scanner
versions follow the small, security-oriented release structure used by the
maintainer's reference project. Dependabot proposes gem, base-image and action updates.

## License

Apache License 2.0; see the complete [LICENSE](LICENSE) and retained [NOTICE](NOTICE).
