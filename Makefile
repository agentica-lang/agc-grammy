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

# Each test gets 2.6M steps, twice the 1.3M the heaviest one needs (a
# translation of a few modules in-process, grammar load included); the
# default is 1M.
test:
	$(AGENTICA) test --max-steps 2600000 tests agc-py/tests

ci: check fmt-check lint test

example:
	$(AGENTICA) examples/python/main.agc examples/python/sample.py
