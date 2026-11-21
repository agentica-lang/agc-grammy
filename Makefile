AGENTICA ?= agentica

.PHONY: check fmt fmt-check lint test ci example

check:
	$(AGENTICA) check src examples tests

fmt:
	$(AGENTICA) fmt src examples tests

fmt-check:
	$(AGENTICA) fmt --check src examples tests

lint:
	$(AGENTICA) lint src examples tests

test:
	$(AGENTICA) test tests

ci: check fmt-check lint test

example:
	$(AGENTICA) examples/python/main.agc examples/python/sample.py
