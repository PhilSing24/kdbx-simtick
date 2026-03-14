# kdbx-modules

A collection of custom modules for [KDB-X](https://code.kx.com/kdb-x/).

## Modules

| Module | Description | Status |
|--------|-------------|--------|
| [di.simtick](di/simtick/) | Realistic intraday tick data simulator with configurable market microstructure | ✅ Ready |
| [di.simcalendar](di/simcalendar/) | Multi-day tick simulation over a trading calendar | ✅ Ready |
| [di.simbasket](di/simbasket/) | Multi-instrument correlated tick simulation using a factor model | 🚧 In progress |
| [di.simbook](di/simbook/) | L2 order book simulator | 🚧 In progress |

### Module hierarchy

```
simtick ← simcalendar ← simbasket
simbook                              ← standalone (future: integration with simcalendar)
```

`simtick` is the atomic unit — one instrument, one day. Each layer above it adds a dimension: multiple days (`simcalendar`), multiple instruments (`simbasket`). `simbook` is a separate bottom-up simulator that models individual order flow events rather than deriving quotes from a price process.

## Quick Start

```bash
git clone https://github.com/youruser/kdbx-modules.git
cd kdbx-modules
make repl
```

```q
q)simtick:use`di.simtick
q)simcalendar:use`di.simcalendar
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

## Project Structure
```
kdbx-modules/
├── Makefile
├── README.md
└── di/
    ├── simtick/           # 1 instrument, 1 day (atomic unit)
    │   ├── init.q
    │   ├── presets.csv
    │   ├── test.csv
    │   └── README.md
    ├── simcalendar/       # 1 instrument, N days (uses di.simtick)
    │   ├── init.q
    │   ├── calendar.csv
    │   └── README.md
    ├── simbasket/         # M instruments, N days (uses di.simcalendar) [WIP]
    │   ├── init.q
    │   └── README.md
    └── simbook/           # L2 order book simulator, Gillespie algorithm [WIP]
        ├── init.q
        └── README.md
```

## Creating New Modules

Each module should follow the [KDB-X module framework](https://code.kx.com/kdb-x/modules/) and include:

- `init.q` — Module code
- `test.csv` — Unit tests (k4unit format)
- `README.md` — Documentation

## License

MIT
