.PHONY: up down logs test test-server test-core test-integration test-agent test-local test-ssh test-ssh-live check fmt test-contrast

up:
	docker compose up --build -d --wait

down:
	docker compose down

logs:
	docker compose logs -f server

test: test-server test-core test-ssh

test-server:
	cd server && go test -race ./...

test-core:
	cd packages/WitermCore && swift test

test-ssh:
	swift test --package-path packages/WitermSSH -j 4

test-ssh-live:
	python3 tools/ssh-fixture/run.py

test-agent:
	swift test --package-path apps/mac-agent

test-local: test-core test-agent
	swift build --package-path apps/mac-agent
	swift run --package-path tools/local-agent-smoke LocalAgentSmoke "$$(swift build --package-path apps/mac-agent --show-bin-path)/witerm-agent"

test-integration:
	docker compose -f compose.yaml -f compose.test.yaml --profile tools run --rm server-test

check:
	cd server && go vet ./...
	cd server && test -z "$$(gofmt -l .)"

fmt:
	cd server && gofmt -w .


# Authored UI color pairs only; arbitrary terminal application RGB is separate.
test-contrast:
	python3 scripts/check-terminal-contrast.py
