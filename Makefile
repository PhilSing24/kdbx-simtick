# kdbx-modules Makefile
# Portable module development - no global installation required

PROJECT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
export QPATH := $(PROJECT_ROOT):$(QPATH)

.PHONY: repl test test-simconfig test-simtick test-simmarket test-simorder params help

# Default target
help:
	@echo "kdbx-modules development commands:"
	@echo ""
	@echo "  make repl            - Start q REPL with QPATH configured"
	@echo "  make test            - Run all module tests"
	@echo "  make test-simconfig  - Run simconfig tests only"
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
test: test-simconfig test-simtick test-simmarket test-simorder

# Individual module tests
# The runner is the local.k4unit module; each target exits non-zero when a check fails or the suite aborts (the runner's error is trapped, since an untrapped error would end the piped q with status 0)
test-simconfig:
	echo 'k4unit:use`local.k4unit; r:@[k4unit.moduletest;`di.simconfig;{-1"suite aborted: ",x;()}]; exit $$[(98h=type r)and 0<count r;$$[all r`ok;0;1];1]' | q -q

test-simtick:
	echo 'k4unit:use`local.k4unit; r:@[k4unit.moduletest;`di.simtick;{-1"suite aborted: ",x;()}]; exit $$[(98h=type r)and 0<count r;$$[all r`ok;0;1];1]' | q -q

test-simmarket:
	echo 'k4unit:use`local.k4unit; r:@[k4unit.moduletest;`di.simmarket;{-1"suite aborted: ",x;()}]; exit $$[(98h=type r)and 0<count r;$$[all r`ok;0;1];1]' | q -q

test-simorder:
	echo 'k4unit:use`local.k4unit; r:@[k4unit.moduletest;`di.simorder;{-1"suite aborted: ",x;()}]; exit $$[(98h=type r)and 0<count r;$$[all r`ok;0;1];1]' | q -q

# The parameter reference pages, generated from each module's describe[] and the shipped configuration files
params:
	q genparams.q -q
