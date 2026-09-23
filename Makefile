# kdbx-modules Makefile
# Portable module development - no global installation required

PROJECT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
export QPATH := $(QPATH):$(PROJECT_ROOT)

.PHONY: repl test test-simtick test-simcalendar test-simorder help

# Default target
help:
	@echo "kdbx-modules development commands:"
	@echo ""
	@echo "  make repl            - Start q REPL with QPATH configured"
	@echo "  make test            - Run all module tests"
	@echo "  make test-simtick    - Run simtick tests only"
	@echo "  make test-simcalendar - Run simcalendar tests only"
	@echo "  make test-simorder   - Run simorder tests only"
	@echo ""
	@echo "Usage example:"
	@echo "  make repl"
	@echo "  q) simtick:use\`di.simtick"
	@echo "  q) simcalendar:use\`di.simcalendar"

# Interactive REPL
repl:
	q

# Run all tests
test: test-simtick test-simcalendar test-simorder

# Individual module tests
# The runner is the local.k4unit module; each target exits non-zero when a check fails
test-simtick:
	echo 'k4unit:use`local.k4unit; r:k4unit.moduletest`di.simtick; exit $$[all r`ok;0;1]' | q -q

test-simcalendar:
	echo 'k4unit:use`local.k4unit; r:k4unit.moduletest`di.simcalendar; exit $$[all r`ok;0;1]' | q -q

test-simorder:
	echo 'k4unit:use`local.k4unit; r:k4unit.moduletest`di.simorder; exit $$[all r`ok;0;1]' | q -q
