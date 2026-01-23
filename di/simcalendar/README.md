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

```q
q)simtick:use`di.simtick
q)simcalendar:use`di.simcalendar

/ Load tick configuration from simtick
q)cfg:simtick.loadconfig[`:di/simtick/presets.csv]`default

/ Load trading calendar
q)calendar:simcalendar.loadcalendar[`:di/simcalendar/calendar.csv]

/ Run multi-day simulation
q)trades:simcalendar.run[cfg;calendar]
```

## API

| Function | Description |
|----------|-------------|
| `simcalendar.run[cfg;calendar]` | Run simulation over calendar, returns trades table |
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

### Overnight Gap

Currently, each day's opening price equals the previous day's closing price — there is no overnight gap. This produces a continuous price path.

**Assumption:** The calendar contains consecutive trading days. If there are gaps (e.g., holidays), the price still carries forward without any adjustment for the elapsed time. A Friday close becomes the following Monday's open with no weekend effect.

Implementing a realistic overnight gap is not straightforward. If we add random overnight returns (even with zero drift), we introduce additional variance:

- **Intraday variance:** σ²/252 per trading day (from simtick)
- **Overnight variance:** σ² × (calendar days)/252 per gap

Over a week (5 trading days, 7 calendar days of gaps), total variance would be approximately double what the configured `vol` implies for daily close-to-close returns.

To maintain consistency with the simtick configuration, adding overnight gaps would require either:

1. Recalibrating `vol` to account for the additional overnight variance
2. Introducing a separate overnight volatility parameter with careful documentation
3. Splitting variance budget between intraday and overnight components

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

- **Overnight gaps**: Model price jumps between close and next open (requires variance budget design)
- **Early closes**: Support variable trading hours per day
- **Daily statistics**: Return summary table alongside trades

## License

MIT
