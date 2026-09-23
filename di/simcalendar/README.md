# di.simcalendar

Multi-day tick simulation over a trading calendar.

## About

This module runs `di.simtick` day after day and turns the days into one coherent history: each day opens at the previous close moved by an overnight return, the intraday and overnight variance share one budget so the configured `vol` stays the close-to-close volatility, and a `days` table summarizes every session. It is the layer that makes multi-day TCA (the same execution style on different market days) and risk demos (close-to-close and close-to-open returns) possible.

## Module Hierarchy

```
simtick ← simcalendar
simtick ← simorder
```

`simtick` is one instrument for one day; `simcalendar` runs it over N days. `simorder` runs against one day of the output (pass the whole result: it keeps the order's instrument and day).

## Installation

Requires `di.simtick` as a sibling module:

```
di/
├── simtick/
│   ├── init.q
│   └── presets.csv
└── simcalendar/
    ├── init.q
    ├── calendar.csv
    ├── presets.csv
    └── README.md
```

> **Note:** We use absolute module paths (`use`di.simtick`) rather than relative sibling references (`use`..simtick`). The sibling syntax did not work in our testing with KDB-X Community Edition — further investigation needed.

## Usage

### In-memory simulation

```q
q)simtick:use`di.simtick
q)simcalendar:use`di.simcalendar

/ A tick configuration from simtick, joined with a calendar preset from this module
q)tickcfg:simtick.loadconfig[`:di/simtick/presets.csv]`nvda_default
q)cfg:tickcfg,simcalendar.loadconfig[`:di/simcalendar/presets.csv]`default

/ Load trading calendar
q)calendar:simcalendar.loadcalendar[`:di/simcalendar/calendar.csv]

/ Run multi-day simulation (in-memory)
q)result:simcalendar.run[cfg;calendar;(::)]
q)key result
`trade`quote`days
q)result`days
date       open     close  overnightret trades volume  
-------------------------------------------------------
2026.08.18 215      223.26 0            276745 46253466
2026.08.19 226.2596 222.51 0.01334587   277738 45837884
2026.08.20 226.7656 223.05 0.01894494   277507 45756446
```

`generatequotes:0b` in the config returns `trade` and `days` only.

### Disk persistence
```q
/ Persist to date-partitioned kdb+ database
q)simcalendar.run[cfg;calendar;`:/tmp/mydb]
`:/tmp/mydb

/ Load and query
q)\l /tmp/mydb
q)5#select from trade where date=2026.08.18
date       sym  time                          seq price   qty    aggressor cond venue
-------------------------------------------------------------------------------------
2026.08.18 NVDA 2026.08.18D09:30:00.000000000 2   215     424344           O    XNAS
2026.08.18 NVDA 2026.08.18D09:30:00.100212953 7   215.011 7      S         I    TRF
2026.08.18 NVDA 2026.08.18D09:30:00.182414049 11  215.01  66     S         I    XNAS
2026.08.18 NVDA 2026.08.18D09:30:00.232009923 14  215     300    S         R    XNAS
2026.08.18 NVDA 2026.08.18D09:30:00.309357209 15  215     300    S         R    EDGX
q)days
```

`trade` and `quote` are written per date partition; `days` is a splayed table at the root, loaded with the database.

## API

| Function | Description |
|----------|-------------|
| `simcalendar.run[cfg;calendar;dbpath]` | Run the simulation; returns a dict `trade`quote`days` in memory, or `dbpath` on disk |
| `simcalendar.runstep[cfg;dst;state;date]` | One day of the run (the step `run` folds over the calendar) |
| `simcalendar.daycfg[cfg;date;startprice]` | The simtick config for one day: date, open price, intraday vol |
| `simcalendar.overnight[cfg;ndays]` | One overnight log return over a gap of `ndays` calendar days |
| `simcalendar.loadcalendar[filepath]` | Load calendar from CSV, returns date list |
| `simcalendar.loadconfig[filepath]` | Load the calendar presets from CSV, returns keyed table |
| `simcalendar.validate[calendar]` | Validate a calendar |
| `simcalendar.validatecfg[cfg]` | Validate the calendar keys of a config |
| `simcalendar.describe[]` | The calendar configuration schema |

## Configuration

All tick parameters come from `di.simtick`'s configuration; `tradingdate` and `startprice` are set per day. The calendar keys come from this module's `presets.csv` and are joined onto the tick config. `loadconfig` checks the header against the schema like the other modules.

| Parameter | Description | Example |
|-----------|-------------|---------|
| `overnightshare` | Share of a trading day's variance that occurs overnight, between 0 and 1 (1 excluded) | 0.3 |
| `gapdayweight` | Weight of each calendar day beyond the first in a gap's variance; 0.25 gives a weekend 1.5 nights' worth | 0.25 |

| Preset | Description |
|--------|-------------|
| `default` | 30% of the daily variance overnight, weekends at 1.5 nights |
| `nogap` | No overnight return: each day opens exactly at the previous close |

## Calendar Format

Simple CSV with a single `date` column:

```csv
date
2026.08.18
2026.08.19
2026.08.20
```

You can generate this from:
- NYSE official calendar PDFs
- `pandas_market_calendars` Python package
- Manual list of trading days

## Behavior

### Overnight gap and the variance budget

Each day after the first opens at the previous close times `exp` of an overnight log return, drawn as a normal with mean minus half its variance (no drift overnight) and variance

```
overnightshare * vol^2 / tradingdays * (1 + gapdayweight * (calendar days - 1))
```

The intraday simulation runs at `vol * sqrt(1 - overnightshare)`, so over a one-night gap the close-to-close variance is exactly `vol^2 / tradingdays`: the configured `vol` is the close-to-close volatility, as it is quoted. A weekend or holiday gap carries more variance than one night but less than its calendar days, which is what markets show.

The `days` table records, per session, the open, the close (the last print, the closing auction), the overnight return that produced the open, the number of trades and the volume, so close-to-open and close-to-close returns are one query away. With `overnightshare:0` the module behaves as before: each day opens exactly at the previous close.

### Seed Management

If `cfg[`seed]` is set, the RNG is initialized once at the start of the simulation. Random numbers then flow sequentially across all days from a single stream:

```
Day 1: consumes randoms for arrivals, prices, quantities
Day 2: continues from where Day 1 left off
Day 3: continues from where Day 2 left off
```

Same seed gives the same output; each day has different random draws.

### Validation

The calendar is validated for:
- Must be a date list
- Non-empty
- No duplicates
- Sorted ascending

The config must carry the calendar keys, with `overnightshare` below 1 and `gapdayweight` non-negative.

## Testing

```bash
make test-simcalendar
```

or from a q session:

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simcalendar
```

## Future Extensions

- **Per-day regimes and per-day seeds**: day-level volatility and volume multipliers, event days, half days, and a seed per date so any day can be regenerated alone
- **Holiday calendar generator**: NYSE-rule trading days for a date range

## License

MIT
