# syntax=docker/dockerfile:1
FROM ruby:3.4-slim AS dependencies
WORKDIR /app
ENV BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test BUNDLE_DEPLOYMENT=1
COPY Gemfile Gemfile.lock ./
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    bundle install && rm -rf /usr/local/bundle/cache

FROM ruby:3.4-slim AS runtime
ARG APP_VERSION=development
ARG APP_REVISION=unknown
ARG APP_BUILD_TIME=unknown
ARG APP_SOURCE=https://github.com/c8m6/api-compatibility-layer
LABEL org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.created=$APP_BUILD_TIME \
      org.opencontainers.image.source=$APP_SOURCE \
      org.opencontainers.image.licenses=Apache-2.0
ENV BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test BUNDLE_DEPLOYMENT=1 ACL_CONFIG=/config/config.yaml
WORKDIR /app
RUN groupadd --gid 10001 acl && useradd --uid 10001 --gid acl --no-create-home acl
COPY --from=dependencies /usr/local/bundle /usr/local/bundle
COPY --chmod=644 Gemfile Gemfile.lock LICENSE NOTICE ./
COPY --chmod=755 lib ./lib
COPY --chmod=755 bin ./bin
USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM
CMD ["ruby", "bin/acl"]
