# Common tasks. `make help` lists them. Tests run in Docker (ruby:3.4), so no
# local Ruby is needed; with Ruby 3.3+ installed, `bundle exec rspec` works too.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
IMAGE   ?= tetra-ruby:local
RUBY     = docker run --rm -v "$(CURDIR)":/app -v tetra-ruby-bundle:/usr/local/bundle -w /app -e COVERAGE \
           ruby:3.4-alpine sh -c 'apk add -q build-base >/dev/null && bundle install --quiet && $(1)'

.DEFAULT_GOAL := help
.PHONY: help run test cover lint image up down logs smoke clean vendor-three

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## Run locally on :8000 (needs Ruby 3.3+ and bundle install)
	DRAIN_DELAY_SECONDS=0 LOG_LEVEL=debug bundle exec bin/tetra

test: ## RSpec in Docker, with coverage (fails under 90% of lines)
	$(call RUBY,bundle exec rspec)

cover: test ## Same as test; the HTML report is coverage/index.html

lint: ## RuboCop in Docker
	$(call RUBY,bundle exec rubocop)

image: ## Build the container image ($(IMAGE))
	docker build --build-arg VERSION=$(VERSION) --build-arg COMMIT=$(COMMIT) --build-arg BUILD_DATE=$(DATE) -t $(IMAGE) .

up: ## Start the app, Prometheus and Grafana with Docker Compose
	VERSION=$(VERSION) COMMIT=$(COMMIT) docker compose up -d --build --wait app prometheus grafana
	@echo "app http://localhost:$${APP_PORT:-8000}  prometheus http://localhost:$${PROMETHEUS_PORT:-9090}  grafana http://localhost:$${GRAFANA_PORT:-3000}"

down: ## Stop the Compose stack
	docker compose --profile test down --remove-orphans

logs: ## Follow the app logs
	docker compose logs -f app

smoke: ## Contract test against the Compose stack
	docker compose --profile test run --rm smoke

vendor-three: ## Re-vendor three.js into web/vendor
	./scripts/vendor-three.sh

clean: ## Remove coverage output
	rm -rf coverage
