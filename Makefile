AGENTICA ?= agentica
export AGC_PY_AGENTICA = $(AGENTICA)

.PHONY: check fmt fmt-check lint test ci example

check:
	$(AGENTICA) check src examples tests agc-py

fmt:
	$(AGENTICA) fmt src examples tests agc-py

fmt-check:
	$(AGENTICA) fmt --check src examples tests agc-py

lint:
	$(AGENTICA) lint src examples tests agc-py

# Each test gets 5M steps: translating a few modules in-process needs more than
# the default 1M.
test:
	$(AGENTICA) test --max-steps 5000000 tests agc-py/tests

ci: check fmt-check lint test

example:
	$(AGENTICA) examples/python/main.agc examples/python/sample.py
