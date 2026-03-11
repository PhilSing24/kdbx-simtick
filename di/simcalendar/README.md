# di.simcalendar

Multi-day tick simulation over a trading calendar.

## About

This module orchestrates `di.simtick` over multiple trading days, producing a **coherent price path** where each day's closing price becomes the next day's opening price.

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
    └── README.md
```

> **Note:** We use absolute module paths (`use`di.simtick`) rather than relative sibling references (`use`..simtick`). The sibling syntax did not work in our testing with KDB-X Community Edition — further investigation needed.

## Usage

### In-memory simulation

```q
q)simtick:use`di.simtick
q)simcalendar:use`di.simcalendar

/ Load tick configuration from simtick
q)cfg:simtick.loadconfig[`:di/simtick/presets.csv]`default

/ Load trading calendar
q)calendar:simcalendar.loadcalendar[`:di/simcalendar/calendar.csv]

/ Run multi-day simulation (in-memory)
q)trades:simcalendar.run[cfg;calendar;(::)]
q)cols trades
`sym`time`price`qty
q)count trades
180778
```

### Disk persistence

```q
/ Persist to date-partitioned kdb+ database
q)simcalendar.run[cfg;calendar;`:/home/philippe/mydb]
`:/home/philippe/mydb

/ Load and query
q)\l /home/philippe/mydb
q)5#select from trade where date=2026.01.20
date       sym  time                          price    qty
----------------------------------------------------------
2026.01.20 NVDA 2026.01.20D09:30:01.243820237 181.9    85
2026.01.20 NVDA 2026.01.20D09:30:01.923257449 181.903  102
2026.01.20 NVDA 2026.01.20D09:30:02.222464786 181.8667 142
2026.01.20 NVDA 2026.01.20D09:30:02.233927676 181.8648 63
2026.01.20 NVDA 2026.01.20D09:30:02.484859713 181.8648 446
```

### With quotes

```q
/ Enable quote generation
q)cfg[`generatequotes]:1b

/ In-memory - returns dict with `trade`quote
q)result:simcalendar.run[cfg;calendar;(::)]
q)result`trade
q)result`quote

/ On disk - writes both trade/ and quote/ partitions
q)simcalendar.run[cfg;calendar;`:/home/philippe/mydb]
```

## API

| Function | Description |
|----------|-------------|
| `simcalendar.run[cfg;calendar;dbpath]` | Run simulation, returns trades table or dbpath |
| `simcalendar.loadcalendar[filepath]` | Load calendar from CSV, returns date list |
| `simcalendar.describe[]` | Return module description |

## Calendar Format

Simple CSV with a single `date` column:

```csv
date
2026.01.20
2026.01.21
2026.01.22
```

You can generate this from:
- NYSE official calendar PDFs
- `pandas_market_calendars` Python package
- Manual list of trading days

## Behavior

### Price Continuity

Prices form one continuous path across days:

```
Day 1: starts at cfg[`startprice], ends at P1
Day 2: starts at P1, ends at P2
Day 3: starts at P2, ends at P3
```

### Disk Persistence

Pass a file handle as the third argument to persist to a date-partitioned kdb+ database:

- `(::)` — in-memory only, returns trades table (or dict with quotes)
- `` `:/path/mydb `` — writes date-partitioned DB, returns dbpath

The database structure on disk:

```
/path/mydb/
├── sym                    / symbol enumeration file
├── 2026.01.20/
│   ├── trade/             / splayed trade table
│   └── quote/             / splayed quote table (if generatequotes:1b)
├── 2026.01.21/
│   ├── trade/
│   └── quote/
...
```

When `generatequotes:1b`, both `trade` and `quote` partitions are written for each day.

### Overnight Gap

Currently, each day's opening price equals the previous day's closing price — there is no overnight gap. This produces a continuous price path.

**Assumption:** The calendar contains consecutive trading days. If there are gaps (e.g., holidays), the price still carries forward without any adjustment for the elapsed time. A Friday close becomes the following Monday's open with no weekend effect.

Implementing a realistic overnight gap is not straightforward. If we add random overnight returns (even with zero drift), we introduce additional variance:

- **Intraday variance:** σ²/252 per trading day (from simtick)
- **Overnight variance:** σ² × (calendar days)/252 per gap

Over a week (5 trading days, 7 calendar days of gaps), total variance would be approximately double what the configured `vol` implies for daily close-to-close returns.

To maintain consistency with the simtick configuration, adding overnight gaps would require either:

1. Recalibrating `vol` to account for the additional overnight variance
2. Introducing a separate overnight volatility parameter
3. Splitting variance between intraday and overnight components

For now, we keep the simpler approach where the configured `vol` governs the entire price path. Future versions may address overnight gaps with proper variance accounting.

### Seed Management

If `cfg[`seed]` is set, the RNG is initialized once at the start of the simulation. Random numbers then flow sequentially across all days from a single stream:

```
Day 1: consumes randoms for arrivals, prices, quantities
Day 2: continues from where Day 1 left off
Day 3: continues from where Day 2 left off
```

This ensures:
- **Reproducibility:** same seed → same outputs
- **Continuity:** one coherent random sequence across the entire simulation
- **Variety:** each day has different random draws (not repeated patterns)

The number of random draws per day varies with trade count, which is path-dependent by nature.

### Validation

The calendar is validated for:
- Must be a date list
- Non-empty
- No duplicates
- Sorted ascending

## Configuration

All tick simulation parameters come from `di.simtick` configuration. The `tradingdate` field is overridden for each day in the calendar.

See `simtick.describe[]` for available parameters.

## Future Extensions

- **Overnight gaps**: Model price jumps between close and next open (requires variance recalibration)

## License

MIT
