# kdbx-modules

A collection of custom modules for [KDB-X](https://code.kx.com/kdb-x/).

## Modules

| Module | Description | Status |
|--------|-------------|--------|
| [di.simtick](di/simtick/) | Realistic intraday tick data simulator: Hawkes arrivals, quotes first and trades against the quote in force with an aggressor side, order-flow impact, spread in ticks, transaction-time volatility, auction prints and tape attributes | ✅ Ready |
| [di.simcalendar](di/simcalendar/) | Multi-day tick simulation over a trading calendar: overnight gaps with a shared variance budget, day-level regimes, half days and event days, a seed per day, an NYSE calendar generator and a per-day summary table | ✅ Ready |
| [di.simorder](di/simorder/) | Order execution simulator: parent orders worked into child orders that execute against the `di.simtick` tape, with lifecycle events (new, ack, replace, cancel, fill, done), market impact, and an order-flow generator over instruments and days, for TCA and surveillance demos | ✅ Ready |

### Module hierarchy

```
simtick ← simcalendar
simtick ← simorder                   (order execution against a single day's market)
```

`simtick` is the atomic unit — one instrument, one day. Each layer above it adds a dimension: multiple days (`simcalendar`) or a parent order worked against that day's market (`simorder`).

Together, `simtick` + `simorder` generate the four datasets (`trades`, `quotes`, `orders`, `executions`) needed to build Transaction Cost Analysis (TCA) — realistic market data plus a realistic, internally consistent order trading against it, with configurable execution quality for good-vs-bad comparisons.

## Quick Start

```bash
git clone https://github.com/youruser/kdbx-modules.git
cd kdbx-modules
make repl
```

```q
q)simtick:use`di.simtick
q)simcalendar:use`di.simcalendar
q)simorder:use`di.simorder
```

## Installation

**Option 1: Command line (Makefile)**
```bash
cd kdbx-modules
make repl
```

**Option 2: Manual QPATH**
```bash
export QPATH=$QPATH:/path/to/kdbx-modules
q
```

**Option 3: VS Code**

After connecting to q, add the module path:
```q
.Q.m.SP,:enlist"/path/to/kdbx-modules"
```

Then load modules:
```q
simcalendar:use`di.simcalendar
```

## Testing

Each module carries a `test.csv` in k4unit format, run by the `local.k4unit` module:

```bash
make test                # all suites
make test-simtick        # one suite; exits non-zero when a check fails
make test-simcalendar
make test-simorder
```

Or from a q session:

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simtick
```

## Project Structure
```
kdbx-modules/
├── Makefile
├── README.md
├── local/
│   └── k4unit.q           # test runner
└── di/
    ├── simtick/           # 1 instrument, 1 day (atomic unit)
    │   ├── init.q
    │   ├── presets.csv
    │   ├── test.csv
    │   ├── testing.q
    │   ├── README.md
    │   ├── docs/
    │   └── notebooks/
    ├── simcalendar/       # 1 instrument, N days (uses di.simtick)
    │   ├── init.q
    │   ├── calendar.csv
    │   ├── presets.csv
    │   ├── test.csv
    │   └── README.md
    └── simorder/          # 1 order, 1 day (uses di.simtick's trades/quotes)
        ├── init.q
        ├── presets.csv
        ├── test.csv
        ├── testing.q
        ├── README.md
        └── notebooks/
```

## Creating New Modules

Each module should follow the [KDB-X module framework](https://code.kx.com/kdb-x/modules/) and include:

- `init.q` — Module code
- `test.csv` — Unit tests (k4unit format)
- `README.md` — Documentation

## License

MIT
