.PHONY: check
.PHONY: help up down start stop restart logs logs-vllm logs-litellm status ps test test-rag benchmark teardown clean-all bootstrap-admin

# Default target
help:
	@echo "SnapHop Local AI Stack Management"
	@echo "=================================="
	@echo "make up             - Start the stack in background and ensure admin account exists"
	@echo "make down           - Stop the stack (docker compose down)"
	@echo "make restart        - Restart all containers"
	@echo "make status         - Show container and GPU status"
	@echo "make logs           - Tail logs for all containers"
	@echo "make logs-vllm      - Tail vLLM container logs"
	@echo "make logs-litellm   - Tail LiteLLM proxy logs"
	@echo "make test           - Run test inference queries via LiteLLM"
	@echo "make test-rag       - Run PostgreSQL 18 pgvector RAG test suite"
	@echo "make benchmark      - Run vLLM benchmark suite (e.g. make benchmark PROMPTS=20)"
	@echo "make bootstrap-admin- Provision/verify admin account (make bootstrap-admin EMAIL=... PASSWORD=...)"
	@echo "make teardown       - Stop stack and remove containers"
	@echo "make clean-all      - WARNING: Stop stack and delete database volumes (litellm & rag)"

# Check for .env file before starting
check-env:
	@if [ ! -f .env ]; then \
		echo "Creating .env from .env.example..."; \
		cp .env.example .env; \
		if [ -n "$$HF_TOKEN" ]; then \
			sed -i "s|HF_TOKEN=your_huggingface_token_here|HF_TOKEN=$$HF_TOKEN|" .env; \
		fi \
	fi

up: check-env
	docker compose up -d
	@./scripts/bootstrap_admin.sh

bootstrap-admin:
	@./scripts/bootstrap_admin.sh $(EMAIL) $(PASSWORD)

start: up

down:
	docker compose down

stop: down

restart:
	docker compose restart

status:
	@echo "=== Container Status ==="
	@docker compose ps
	@echo ""
	@echo "=== GPU Status ==="
	@nvidia-smi

ps: status

logs:
	docker compose logs -f

logs-vllm:
	docker compose logs -f vllm

logs-litellm:
	docker compose logs -f litellm

test:
	./scripts/test_inference.sh

test-rag:
	./scripts/test_rag.sh

benchmark:
	./scripts/benchmark.sh $(or $(PROMPTS),10) $(or $(INPUT_LEN),512) $(or $(OUTPUT_LEN),128)

teardown:
	docker compose down --remove-orphans

clean-all:
	@echo "WARNING: This will destroy the database volumes containing all LiteLLM data and RAG vector data."
	@read -p "Are you sure? [y/N] " ans && [ "$$ans" = "y" ] || exit 1
	docker compose down -v --remove-orphans

# Static checks; no running services or GPU required.
check:
	@./scripts/check.sh
