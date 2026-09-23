# di.simcalendar

Multi-day tick simulation over a trading calendar.

## About

This module runs `di.simtick` day after day and turns the days into one coherent history: each day opens at the previous close moved by an overnight return, the intraday and overnight variance share one budget so the configured `vol` stays the close-to-close volatility, quiet and busy spells come from a day-level regime, the calendar can mark half days and event days, and a `days` table summarizes every session. Every day draws from its own seed, so any day can be regenerated alone from its row of that table. It is the layer that makes multi-day TCA (the same execution style on different market days) and risk demos (close-to-close and close-to-open returns, volatility clustering across days) possible.

## Module Hierarchy

```
simtick ← simcalendar
simtick ← simorder
```

`simtick` is one instrument for one day; `simcalendar` runs it over N days. `simorder` runs against one day of the output (pass the whole result: it keeps the order's instrument and day).

## Installation

Requires `di.simtick` (and through it `di.simconfig`, which holds the shipped market, instrument and scenario files) as sibling modules:

```
di/
├── simconfig/
│   ├── init.q
│   ├── markets/us_largecap.json
│   ├── instruments.csv
│   └── scenarios.csv
├── simtick/
│   └── init.q
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

/ A configuration composed from the layers (see di.simtick): the scenario
/ row carries the calendar keys; the run dictionary sets the seed
q)f:simtick.files[]
q)market:simtick.loadmarket f`market
q)instruments:simtick.loadinstruments f`instruments
q)scenarios:simtick.loadscenarios f`scenarios
q)cfg:simtick.compose[market;instruments`NVDA;scenarios`normal;(enlist `seed)!enlist 42]

/ Load trading calendar
q)calendar:simcalendar.loadcalendar[`:di/simcalendar/calendar.csv]

/ Run multi-day simulation (in-memory)
q)result:simcalendar.run[cfg;calendar;(::)]
q)key result
`trade`quote`days
q)select date,closingtime,volmult,volumemult,dayseed,open,close,overnightret,trades,volume from result`days
date       closingtime volmult   volumemult dayseed  open     close  overnightret trades volume  
-------------------------------------------------------------------------------------------------
2026.08.18 16:00       0.852167  0.852167   10612790 215      211.74 0            237203 39090196
2026.08.19 16:00       0.7869607 0.7869607  10612821 209.1146 214.22 -0.01247679  218335 36320283
2026.08.20 13:00       1.325001  1.325001   10612852 212.5223 221.48 -0.007956562 196695 32583884
```

`generatequotes:0b` in the config returns `trade` and `days` only. The `days` table starts with the calendar and regime columns (`closingtime`, `volmult`, `volumemult`, `jumpintensity`, the seeds and the regime states `volstate` and `volumestate`) and ends with the day's open, close, overnight return, trades and volume.

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

### Several instruments

`compose` gives every instrument of the table its configuration, on one scenario or one per instrument, and `runmany` runs them over the same calendar. The regime seed of a date is shared, so the instruments live the same market days (the same quiet and busy spells under the same scenario); each has its own tape and overnight gaps.

```q
q)cfgs:simcalendar.compose[market;instruments;scenarios;`normal;(enlist `seed)!enlist 42]
q)cfgs:simcalendar.compose[market;instruments;scenarios;`NVDA`XOM`PG!`normal`normal`volatile;(enlist `seed)!enlist 42]
q)result:simcalendar.runmany[cfgs;calendar;(::)]        / or a dbpath
q)select sym,date,open,close,trades from result`days
```

In memory the trades and quotes of every instrument come merged and sorted by time, and the `days` table gets a `sym` column; on disk the partitions hold every instrument, sorted by `sym` then time. An instrument named in the scenario dictionary but not in the table, or a scenario not in the scenario table, throws an error naming it.

## API

| Function | Description |
|----------|-------------|
| `simcalendar.run[cfg;calendar;dbpath]` | Run the simulation; returns a dict `trade`quote`days` in memory, or `dbpath` on disk |
| `simcalendar.runstep[cfg;dst;state;day]` | One day of the run (the step `run` folds over the regimes table) |
| `simcalendar.runmany[cfgs;calendar;dbpath]` | Run several instruments (a dictionary sym!config from `compose`) over the same calendar, merged |
| `simcalendar.compose[market;instruments;scenarios;scenario;run]` | The configuration of every instrument, on one scenario name or a dictionary sym!name |
| `simcalendar.daycfg[cfg;day;price]` | The simtick config for one day from its row of the regimes or days table: date, closing time, open price, vol and trades per day multiplied, jump intensity, base intensity derived, seed |
| `simcalendar.overnight[cfg;ndays]` | One overnight log return over a gap of `ndays` calendar days |
| `simcalendar.seeds[cfg;dates]` | The per-day seeds: a regime seed per date shared across instruments, the instrument's day seed and gap seed |
| `simcalendar.regimes[cfg;calendar]` | The calendar with the day-level regime resolved: seeds, AR(1) state, volatility and volume multipliers, closing time, jump intensity |
| `simcalendar.loadcalendar[filepath]` | Load a calendar from CSV, returns a calendar table |
| `simcalendar.savecalendar[filepath;calendar]` | Write a calendar table to CSV |
| `simcalendar.nysecalendar[from;to]` | The NYSE trading days between two dates, early closes at 13:00 |
| `simcalendar.validate[calendar]` | Validate a calendar (a date list or a table) and return it as a table |
| `simcalendar.validatecfg[cfg]` | Validate the calendar keys of a config |
| `simcalendar.describe[]` | The calendar keys of the configuration schema |

## Configuration

A run takes a configuration composed by `di.simtick` from its four layers (market, instrument, scenario, run). The calendar keys below belong to the scenario layer, so `di/simconfig/scenarios.csv` carries them per scenario: `normal` has persistence 0.7, 30% spread and correlation 0.7; `volatile` long spells (persistence 0.8) with 60% spread and correlation 0.8. `tradingdate` and `price` are set per day by `daycfg`, which also multiplies `vol` and `tradesperday` by the day's regime and derives the day's `baseintensity` the way `simtick.compose` does (a half day trades about half a day).

| Parameter | Description | Example |
|-----------|-------------|---------|
| `overnightshare` | Share of a trading day's variance that occurs overnight, between 0 and 1 (1 excluded) | 0.3 |
| `gapdayweight` | Weight of each calendar day beyond the first in a gap's variance; 0.25 gives a weekend 1.5 nights' worth | 0.25 |
| `regimepersistence` | AR(1) persistence of the day-level regimes, between 0 and 1: 0 gives independent days, 0.7 quiet and busy spells of a few days | 0.7 |
| `regimecorr` | Correlation of the daily shocks to the volatility and volume regimes, between -1 and 1 | 0.7 |
| `volregimesd` | Standard deviation of the log volatility multiplier across days, normalized so the mean daily variance is the configured one; 0 keeps every day at the configured vol | 0.3 |
| `volumeregimesd` | Standard deviation of the log volume multiplier across days, driven by the same regime as the volatility | 0.3 |

For no overnight gap set `overnightshare` and `gapdayweight` to 0; for no regime set the two spreads to 0. Either goes on a scenario row, or on the composed dictionary before the run.

## Calendar Format

A CSV with a `date` column and any of four optional columns; an empty cell means the config's value (1 for the multipliers):

```csv
date,closingtime,volmult,volumemult,jumpintensity
2026.08.18,,,,
2026.08.19,,,,
2026.08.20,13:00,,,
```

| Column | Meaning |
|--------|---------|
| `closingtime` | The day's close (minute): `13:00` makes a half day |
| `volmult` | Multiplies the day's volatility on top of the regime: 2 for an earnings day |
| `volumemult` | Multiplies the day's trade intensity on top of the regime: 3 for an earnings day |
| `jumpintensity` | The day's jumps per day; a positive value selects the jump model for that day |

`run` and `validate` also accept a plain date list. A calendar table can be built in q as well, for instance an earnings day:

```q
q)calendar:update volmult:2f,volumemult:3f,jumpintensity:3f from calendar where date=2026.08.19
```

### Generating an NYSE calendar

```q
q)calendar:simcalendar.nysecalendar[2026.01.01;2026.12.31]
q)count calendar
251
q)select from calendar where closingtime=13:00
date       closingtime volmult volumemult jumpintensity
-------------------------------------------------------
2026.11.27 13:00
2026.12.24 13:00
q)simcalendar.savecalendar[`:mycalendar.csv;calendar]
```

The generator applies the NYSE rules: weekdays less New Year's Day (not observed on the Friday when it falls on a Saturday), Martin Luther King Jr. Day, Presidents' Day, Good Friday, Memorial Day, Juneteenth (from 2022), Independence Day, Labor Day, Thanksgiving and Christmas, with a Saturday holiday observed on the Friday and a Sunday one on the Monday; early closes on the day after Thanksgiving, July 3 and Christmas Eve when they are trading days. Special closures (days of mourning, disasters) are not modelled: check against the official calendar for a past year. Edit the table for event days before running, or save it and edit the CSV.

## Behavior

### Overnight gap and the variance budget

Each day after the first opens at the previous close times `exp` of an overnight log return, drawn as a normal with mean minus half its variance (no drift overnight) and variance

```
overnightshare * vol^2 / tradingdays * (1 + gapdayweight * (calendar days - 1))
```

The intraday simulation runs at `vol * sqrt(1 - overnightshare)`, so over a one-night gap the close-to-close variance is exactly `vol^2 / tradingdays`: the configured `vol` is the close-to-close volatility, as it is quoted. A weekend or holiday gap carries more variance than one night but less than its calendar days, which is what markets show.

The `days` table records, per session, the open, the close (the last print, the closing auction), the overnight return that produced the open, the number of trades and the volume, so close-to-open and close-to-close returns are one query away. With `overnightshare:0` the module behaves as before: each day opens exactly at the previous close.

### Day-level regimes

Days differ. Two standardized AR(1) states with persistence `regimepersistence`, `volstate` for volatility and `volumestate` for volume, are driven by daily shocks with correlation `regimecorr`. They give each day a volatility multiplier `exp(volregimesd * volstate - volregimesd^2)` and a volume multiplier `exp(volumeregimesd * volumestate - volumeregimesd^2 / 2)`, so busy days tend to be volatile days (at 0.7 they are strongly related without being one thing, as in markets) and spells of a few days cluster. The volume multiplier averages 1; the volatility multiplier is normalized on its square instead, since volatility enters a day as variance, so the close-to-close variance averages the configured `vol^2 / tradingdays` rather than exceeding it by `exp(volregimesd^2)`. The calendar's own `volmult` and `volumemult` multiply on top, for event days. `simcalendar.regimes[cfg;calendar]` returns the resolved multipliers, and the `days` table carries them.

### Seeds: one per day, shared across instruments

With `cfg[`seed]` set, every date gets a regime seed from the seed and the date alone, so a date's regime innovation is the same in any calendar that contains it and, since it does not depend on `sym`, the same for every instrument run on that date: the market's day. From it the instrument gets a day seed (for its tape) and a gap seed (for its overnight return). Consequences:

- Any day can be regenerated alone, exactly, from its row of the `days` table: `simtick.run simcalendar.daycfg[cfg;days d;days[d]`open]`.
- Adding or removing days elsewhere in the calendar does not change a day's innovation or tape, only the regime level that the AR(1) carries into it and the open it inherits.
- Without a seed nothing is seeded and every run differs.

### Validation

The calendar is validated for:
- Must be a date list
- Non-empty
- No duplicates
- Sorted ascending
- Only the known columns (`date`, `closingtime`, `volmult`, `volumemult`, `jumpintensity`)

The config must carry the calendar keys, with `overnightshare` and `regimepersistence` below 1 and `gapdayweight` and the regime spreads non-negative.

## Testing

```bash
make test-simcalendar
```

or from a q session:

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simcalendar
```

The suite (127 checks) covers calendar validation and loading, the composition of several instruments on one scenario or one each, the NYSE generator (2026's 251 days, its holidays and early closes, Good Friday by year, the New Year and Christmas observance rules, a saved calendar loading back), the overnight gap and the variance budget, the seeds and regimes, a half day, a tripled-volume day and a jump day from the calendar, a day regenerated exactly from its row, several instruments run together in memory and to disk, disk persistence and reproducibility.

## Future Extensions

- **A market factor across instruments**: the shared regime seed is the hook for a common day and, later, a common intraday path

## License

MIT
