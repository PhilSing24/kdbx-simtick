# di.simconfig

Layered configuration for the `di.*` simulators: how the market works, what a stock is, what kind of day it is, and what the run is, kept apart and composed into the flat dictionary the engines read.

## Why

A tick simulator has many knobs, and most of them describe a market and hardly ever change. Putting them all on one row per preset meant fifty columns to read and copy for every new stock. The layers keep the rarely-changed settings in one place and leave a user with a handful of values per stock.

## The four layers

| Layer | Content | Format |
|-------|---------|--------|
| Market | how a market works: session times, tick size, clock, trade clustering, intraday profile, auctions, trade-size mix, venue shares, off-exchange behaviour, spread and quote dynamics, order-flow impact, defaults for a run | JSON, one file per market, `markets/us_largecap.json` first |
| Instrument | what makes a stock itself: `sym`, `price`, `drift`, `vol`, `tradesperday`, and any market key it overrides | CSV, one row per stock, `instruments.csv` |
| Scenario | what makes a day type: multipliers on volatility, volume and spread, jump settings, the regimes of a multi-day run | CSV, one row per scenario, `scenarios.csv` |
| Run | date or calendar, seed, whether to return quotes | a small dictionary |

A later layer overrides an earlier one. The shipped files are examples; every loader takes any path.

## Usage

The module is used through the simulators, which pass their own schema in. Directly:

```q
q)simconfig:use`di.simconfig
q)schema:simtick.schema                                  / a module's schema
q)market:simconfig.loadmarket[schema;simconfig.path "markets/us_largecap.json"]
q)instruments:simconfig.loadinstruments[schema;simconfig.path "instruments.csv"]
q)scenarios:simconfig.loadscenarios[schema;simconfig.path "scenarios.csv"]
q)cfg:simconfig.compose[schema;market;instruments`NVDA;scenarios`normal;`seed`tradingdate!(42;2026.08.18)]
q)simconfig.saveconfig[`:run.json;cfg]                  / one file that reproduces the run
q)cfg:simconfig.loadconfig[schema;`:run.json]
```

`simconfig.path` finds a shipped file in the module search path from any working directory.

## Rules

- **Types come from the schema.** JSON gives floats for every number and strings for everything else; `compose` casts each value by the schema's type, so longs, symbols, dates and minutes come out typed. A list-valued key (`profile`, `venues`) is a JSON array in the market file and a space-separated string in a CSV cell.
- **No silent defaults.** A key missing after composition throws, naming the key and the layer that should supply it. An unknown key throws too.
- **An empty CSV cell is no override**, so an instrument row only carries the keys it changes.
- **A saved config replays.** `saveconfig` writes the composed dictionary as one JSON file and `loadconfig` reads it back without the layers.

## API

| Function | Description |
|----------|-------------|
| `simconfig.compose[schema;market;instrument;scenario;run]` | The flat configuration, cast and checked |
| `simconfig.loadmarket[schema;filepath]` | A market file, its groups flattened |
| `simconfig.loadinstruments[schema;filepath]` | Instrument rows keyed by `sym`; the five required columns must be filled |
| `simconfig.loadscenarios[schema;filepath]` | Scenario rows keyed by `name` |
| `simconfig.loadrows[schema;filepath;keycol]` | Any typed CSV of rows keyed by a column |
| `simconfig.saveconfig[filepath;cfg]` | Write a composed configuration as JSON |
| `simconfig.loadconfig[schema;filepath]` | Read one back |
| `simconfig.describe[schema]` | The schema as a table: `param`, `typ`, `layer`, `group`, `description`, the essential keys first |
| `simconfig.cast[type;value]` | Cast one value by a schema type |
| `simconfig.nonnull[dict]` | The entries of a row that carry a value |
| `simconfig.path[relative]` | A shipped file's handle |

A schema is a dictionary `key!(type;layer;group;description)`. Types: `S` symbol, `F` float, `J` long, `B` boolean, `D` date, `U` minute, `P` timestamp, `SL` `FL` `JL` lists of those, `*` as given. Layers: `essential`, `market`, `instrument`, `order` (`di.simorder`'s per-order keys), `scenario`, `run`, `optional` (cast when present, never required) and `derived` (left to the module's own compose). Layers: `essential`, `market`, `instrument`, `scenario`, `run`, `derived`.

## Testing

```bash
make test-simconfig
```

## License

MIT
