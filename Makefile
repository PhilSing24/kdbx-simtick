# kdbx-modules Makefile
# Portable module development - no global installation required

PROJECT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
export QPATH := $(PROJECT_ROOT):$(QPATH)

.PHONY: repl test test-simtick-config test-simtick test-simmarket test-simorder params help

# Default target
help:
	@echo "kdbx-modules development commands:"
	@echo ""
	@echo "  make repl            - Start q REPL with QPATH configured"
	@echo "  make test            - Run all module tests"
	@echo "  make test-simtick-config  - Run the tests of di.simtick.config only"
	@echo "  make test-simtick    - Run simtick tests only"
	@echo "  make test-simmarket - Run simmarket tests only"
	@echo "  make test-simorder   - Run simorder tests only"
	@echo "  make params          - Regenerate the parameter reference pages (di/*/docs/parameters.md)"
	@echo ""
	@echo "Usage example:"
	@echo "  make repl"
	@echo "  q) simtick:use\`di.simtick"
	@echo "  q) simmarket:use\`di.simmarket"

# Interactive REPL
repl:
	q

# Run all tests
test: test-simtick-config test-simtick test-simmarket test-simorder

# Individual module tests
# The runner is di.k4unit, the Data Intellect test module, which ships upstream and must be on QPATH
# after this repository. Each target prints the counts and exits non-zero when a check fails, the
# suite aborts, or the runner is not found
define NOK4UNIT
di.k4unit was not found on QPATH. It ships with the Data Intellect modules: clone https://github.com/DataIntellectTech/kdbx-modules and add the clone to QPATH after this repository, for example: export QPATH=$(patsubst %/,%,$(PROJECT_ROOT)):$$HOME/.kx/mod:$$HOME/kdbx-modules-upstream
endef
define K4RUN
k4unit:@[use;`di.k4unit;{-1 "$(NOK4UNIT)"; exit 2}]; @[k4unit.moduletest;`$(1);{-1 "suite aborted: ",x;}]; r:k4unit.getresults[]; -1 "Passed: ",string sum r`ok; -1 "Failed: ",string sum not r`ok; exit $$[(0<count r)and all r`ok;0;1]
endef

test-simtick-config:
	@echo '$(call K4RUN,di.simtick.config)' | q -q

test-simtick:
	@echo '$(call K4RUN,di.simtick)' | q -q

test-simmarket:
	@echo '$(call K4RUN,di.simmarket)' | q -q

test-simorder:
	@echo '$(call K4RUN,di.simorder)' | q -q

# The parameter reference pages, generated from each module's describe[] and the shipped configuration files
params:
	q genparams.q -q
