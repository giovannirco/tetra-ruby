# syntax=docker/dockerfile:1
# Compile native gems (puma, nio4r) in a build stage; ship without a compiler.
FROM ruby:3.4-alpine AS build
RUN apk add --no-cache build-base
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 && rm -rf vendor/bundle/ruby/*/cache

FROM ruby:3.4-alpine
LABEL org.opencontainers.image.source="https://github.com/giovannirco/tetra-ruby" \
      org.opencontainers.image.description="Tetra arithmetic API (Ruby)" \
      org.opencontainers.image.licenses="MIT"
RUN adduser -D -H -u 10001 tetra
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=development:test
COPY --from=build /app/vendor ./vendor
COPY Gemfile Gemfile.lock ./
COPY lib ./lib
COPY bin ./bin
COPY web ./web
ARG VERSION=
ARG COMMIT=unknown
ARG BUILD_DATE=
ENV VERSION=${VERSION} COMMIT=${COMMIT} BUILD_DATE=${BUILD_DATE} RUBYOPT=-W0
USER tetra
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 CMD ["bundle", "exec", "bin/healthcheck"]
CMD ["bundle", "exec", "bin/tetra"]
