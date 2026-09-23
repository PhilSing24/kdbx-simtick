# kdbx-modules

A collection of custom modules for [KDB-X](https://code.kx.com/kdb-x/).

## Modules

| Module | Description | Status |
|--------|-------------|--------|
| [di.simconfig](di/simconfig/) | Layered configuration shared by the simulators: a market file, instrument rows, scenario rows and a run dictionary composed into the flat dictionary the engines read, with the shipped US large-cap market, three instruments, three scenarios and three orders | ✅ Ready |
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
q)result:simtick.quick[`NVDA;215.0;0.08;0.45;500000]     / one day of NVDA: trades and quotes
```

## Configuration

A simulator has many knobs, and most of them describe a market and hardly ever change. The parameters live in four layers, composed in order into the flat dictionary an engine reads, a later layer overriding an earlier one:

| Layer | What it holds | Shipped as |
|-------|---------------|------------|
| market | how a market works: session, tick size, arrival clustering and intraday profile, sizes, spreads, venues, impact, the order-execution defaults and the run defaults | `di/simconfig/markets/us_largecap.json` |
| instrument | what makes a stock itself: `sym`, `price`, `drift`, `vol`, `tradesperday`, and any market key it overrides | `di/simconfig/instruments.csv` (NVDA, XOM, PG) |
| scenario | what makes a day type: multipliers of vol, trades and spread, the jump model, the day-to-day regime | `di/simconfig/scenarios.csv` (normal, volatile, jumpy) |
| run | what changes between two runs: date, seed, whether to return quotes | a dictionary; the market file carries the defaults |

`simtick.quick` takes the five instrument values and runs a day on the shipped market; `simtick.compose` builds a configuration from the layers, applying the scenario multipliers once and deriving the Hawkes base intensity from the trades per day; `simcalendar.compose` does it for several instruments on one scenario or one each; `simorder.compose` joins the market's order keys with an order row (`di/simconfig/orders.csv`). Composition is strict: values are cast to the schema's types, unknown keys throw, missing keys throw naming the layer that should supply them, and a saved configuration replays. Every parameter is listed with its type, layer, group and description in the generated pages [simtick](di/simtick/docs/parameters.md), [simcalendar](di/simcalendar/docs/parameters.md) and [simorder](di/simorder/docs/parameters.md) (`make params`).

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
make test-simconfig      # one suite; exits non-zero when a check fails
make test-simtick
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
├── genparams.q            # generates the parameter reference pages
├── local/
│   └── k4unit.q           # test runner
└── di/
    ├── simconfig/         # layered configuration and the shipped files
    │   ├── init.q
    │   ├── markets/us_largecap.json
    │   ├── instruments.csv
    │   ├── scenarios.csv
    │   ├── orders.csv
    │   ├── test.csv
    │   └── README.md
    ├── simtick/           # 1 instrument, 1 day (atomic unit)
    │   ├── init.q
    │   ├── test.csv
    │   ├── testing.q
    │   ├── README.md
    │   └── docs/          # technical paper, parameters.md
    ├── simcalendar/       # 1 instrument, N days (uses di.simtick)
    │   ├── init.q
    │   ├── calendar.csv
    │   ├── test.csv
    │   ├── README.md
    │   └── docs/          # parameters.md
    └── simorder/          # 1 order, 1 day (uses di.simtick's trades/quotes)
        ├── init.q
        ├── test.csv
        ├── testing.q
        ├── README.md
        └── docs/          # parameters.md
```

## Creating New Modules

Each module should follow the [KDB-X module framework](https://code.kx.com/kdb-x/modules/) and include:

- `init.q` — Module code
- `test.csv` — Unit tests (k4unit format)
- `README.md` — Documentation

## License

MIT
