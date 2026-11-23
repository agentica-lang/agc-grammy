AGENTICA ?= agentica
export AGENTICA

.PHONY: check fmt fmt-check lint test ci example

check:
	$(AGENTICA) check src examples tests agc-py

fmt:
	$(AGENTICA) fmt src examples tests agc-py

fmt-check:
	$(AGENTICA) fmt --check src examples tests agc-py

lint:
	$(AGENTICA) lint src examples tests agc-py

test:
	$(AGENTICA) test tests agc-py/tests

ci: check fmt-check lint test

example:
	$(AGENTICA) examples/python/main.agc examples/python/sample.py
