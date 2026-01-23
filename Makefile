# kdbx-modules Makefile
# Portable module development - no global installation required

PROJECT_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
export QPATH := $(QPATH):$(PROJECT_ROOT)

.PHONY: repl test test-simtick test-simcalendar help

# Default target
help:
	@echo "kdbx-modules development commands:"
	@echo ""
	@echo "  make repl            - Start q REPL with QPATH configured"
	@echo "  make test            - Run all module tests"
	@echo "  make test-simtick    - Run simtick tests only"
	@echo "  make test-simcalendar - Run simcalendar tests only"
	@echo ""
	@echo "Usage example:"
	@echo "  make repl"
	@echo "  q) simtick:use\`di.simtick"
	@echo "  q) simcalendar:use\`di.simcalendar"

# Interactive REPL
repl:
	q

# Run all tests
test: test-simtick test-simcalendar

# Individual module tests
test-simtick:
	q -c "k4unit:use\`di.k4unit; k4unit.moduletest\`di.simtick; exit 0"

test-simcalendar:
	q -c "k4unit:use\`di.k4unit; k4unit.moduletest\`di.simcalendar; exit 0"
