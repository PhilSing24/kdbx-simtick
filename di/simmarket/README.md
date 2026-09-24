# di.simmarket

Multi-day tick simulation over a trading calendar.

## About

This module runs `di.simtick` day after day and turns the days into one coherent history: each day opens at the previous close moved by an overnight return, the intraday and overnight variance share one budget so the configured `vol` stays the close-to-close volatility, quiet and busy spells come from a day-level regime, the calendar can mark half days and event days, and a `days` table summarizes every session. Every day draws from its own seed, so any day can be regenerated alone from its row of that table. It is the layer that makes multi-day TCA (the same execution style on different market days) and risk demos (close-to-close and close-to-open returns, volatility clustering across days) possible.

## Module Hierarchy

```
simtick ← simmarket
simtick ← simorder
```

`simtick` is one instrument for one day; `simmarket` runs it over N days. `simorder` runs against one day of the output (pass the whole result: it keeps the order's instrument and day).

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
└── simmarket/
    ├── init.q
    ├── calendar.csv
    └── README.md
```

> **Note:** We use absolute module paths (`use`di.simtick`) rather than relative sibling references (`use`..simtick`). The sibling syntax did not work in our testing with KDB-X Community Edition — further investigation needed.

## Usage

### In-memory simulation

```q
q)simtick:use`di.simtick
q)simmarket:use`di.simmarket

/ A configuration composed from the layers (see di.simtick): the scenario
/ row carries the calendar keys; the run dictionary sets the seed
q)f:simtick.files[]
q)market:simtick.loadmarket f`market
q)instruments:simtick.loadinstruments f`instruments
q)scenarios:simtick.loadscenarios f`scenarios
q)cfg:simtick.compose[market;instruments`NVDA;scenarios`normal;(enlist `seed)!enlist 42]

/ Load trading calendar
q)calendar:simmarket.loadcalendar[`:di/simmarket/calendar.csv]

/ Run multi-day simulation (in-memory)
q)result:simmarket.run[cfg;calendar;(::)]
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

### The output database

With a path instead of `(::)`, `run` and `runmany` write a standard, compressed, date-partitioned kdb+ database that anyone loads with `\l`. One call simulates several stocks over a calendar:

```q
q)cfgs:simmarket.compose[market;instruments;scenarios;`NVDA`XOM`PG!`normal`normal`volatile;(enlist `seed)!enlist 42]
q)simmarket.runmany[cfgs;calendar;`:/tmp/mydb]              / trades and quotes, zstd
q)simmarket.writehdb[cfgs;calendar;`:/tmp/mydb;(enlist `tables)!enlist `trade]   / trades only

q)\l /tmp/mydb
q)select count i by date,sym from trade
q)select sym,date,open,close,overnightret,trades,volume from days
```

The layout:

```
mydb/
  sym                symbol enumeration shared by all partitions
  config             the run: every stock's composed configuration, the calendar,
                     the tables written, the compression and the code version
  2026.08.18/
    trade/           all stocks that day, sorted by sym then time, `p#sym
    quote/           the same, when requested
    days/            one row per stock: regime multipliers, open, close, overnight gap, trades, volume
  2026.08.19/ ...
```

Every partition holds every requested table, empty ones included, so date-range queries never break. The partition is the date; there is no partition by sym. `config` is a q object (a kdb+ root holds q objects only, so a JSON file cannot live there): `\l` loads it as the variable `config`, `simmarket.loadrun` reads it back, and `.j.j` gives the JSON.

**One day at a time.** For each date of the calendar in order, every stock is simulated for that date (each carrying its own previous close into the day's open, with its own scenario and seeds), the stocks' tables are joined and the date's partition is written in one step, then the day's tables are dropped. Memory holds one day of all stocks; only each stock's close and the day's summary rows are carried forward.

**Compression.** `writehdb[cfgs;calendar;dbpath;opts]` takes `opts` with any of `tables` (`` `trade`quote `` by default, or `` `trade ``; `days` is always written) and `compression`, the `(logical block size;algorithm;level)` triple applied to every column, `17 5 3` by default: 128 KB blocks, zstd level 3, which gives gzip's size at snappy's speed on tick data. `17 2 6` (gzip) is readable by kdb+ before 4.1; `()` writes uncompressed. The session's own compression setting is left as it was found.

**Resume.** A date whose partition is complete (every requested table and `days` present, with a row per stock) is skipped, its closes carried forward, so an interrupted run continues where it stopped and, since every day has its own seeds, equals a full run exactly. `days` is written last, so a crash cannot leave a date looking complete; an incomplete date is deleted and written again from scratch. A database built with another configuration (other instruments, scenarios, tables or compression, or a calendar that is not extended) is refused rather than mixed.

**Reproducing.** `r:simmarket.loadrun dbpath` returns the run's `configs`, `calendar`, `opts` and `version`; `simmarket.writehdb[r`configs;r`calendar;newpath;r`opts]` reproduces the database. The version is the git commit of the code that wrote it, and `loadrun` warns when the code running differs, since the same configuration and seeds reproduce the data only with the same code.

The old single-stock layout (`days` at the root, no `sym` column) is replaced by this one: a one-stock database now has the same layout as a many-stock one. Databases written with the old layout should be regenerated.

### Several instruments

`compose` gives every instrument of the table its configuration, on one scenario or one per instrument, and `runmany` runs them over the same calendar. The regime seed of a date is shared, so the instruments live the same market days (the same quiet and busy spells under the same scenario); each has its own tape and overnight gaps.

```q
q)cfgs:simmarket.compose[market;instruments;scenarios;`normal;(enlist `seed)!enlist 42]
q)cfgs:simmarket.compose[market;instruments;scenarios;`NVDA`XOM`PG!`normal`normal`volatile;(enlist `seed)!enlist 42]
q)result:simmarket.runmany[cfgs;calendar;(::)]        / or a dbpath
q)select sym,date,open,close,trades from result`days
```

In memory the trades and quotes of every instrument come merged and sorted by time, and the `days` table gets a `sym` column; on disk the database above holds every instrument, sorted by `sym` then time within each partition. An instrument named in the scenario dictionary but not in the table, or a scenario not in the scenario table, throws an error naming it.

## API

| Function | Description |
|----------|-------------|
| `simmarket.run[cfg;calendar;dbpath]` | Run one stock; returns a dict `trade`quote`days` in memory, or writes the database and returns `dbpath` |
| `simmarket.writehdb[cfgs;calendar;dbpath;opts]` | Several stocks written as a date-partitioned database one day at a time; `opts` with any of `tables` and `compression` |
| `simmarket.loadrun[dbpath]` | The run that wrote a database: `configs`, `calendar`, `opts`, `version` |
| `simmarket.version[]` | The git commit of the code (with `-dirty` when the modules have uncommitted changes) |
| `simmarket.runstep[cfg;state;day]` | One day of an in-memory run (the step `run` folds over the regimes table) |
| `simmarket.simday[cfg;day;price]` | One stock's day from its regimes row and its open: the tables, its days row and its close |
| `simmarket.runmany[cfgs;calendar;dbpath]` | Run several instruments (a dictionary sym!config from `compose`) over the same calendar, merged in memory or written as the database with the default options |
| `simmarket.compose[market;instruments;scenarios;scenario;run]` | The configuration of every instrument, on one scenario name or a dictionary sym!name |
| `simmarket.daycfg[cfg;day;price]` | The simtick config for one day from its row of the regimes or days table: date, closing time, open price, vol and trades per day multiplied, jump intensity, base intensity derived, seed |
| `simmarket.overnight[cfg;ndays]` | One overnight log return over a gap of `ndays` calendar days |
| `simmarket.seeds[cfg;dates]` | The per-day seeds: a regime seed per date shared across instruments, the instrument's day seed and gap seed |
| `simmarket.regimes[cfg;calendar]` | The calendar with the day-level regime resolved: seeds, AR(1) state, volatility and volume multipliers, closing time, jump intensity |
| `simmarket.loadcalendar[filepath]` | Load a calendar from CSV, returns a calendar table |
| `simmarket.savecalendar[filepath;calendar]` | Write a calendar table to CSV |
| `simmarket.nysecalendar[from;to]` | The NYSE trading days between two dates, early closes at 13:00 |
| `simmarket.validate[calendar]` | Validate a calendar (a date list or a table) and return it as a table |
| `simmarket.validatecfg[cfg]` | Validate the calendar keys of a config |
| `simmarket.describe[]` | The calendar keys of the configuration schema |

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
q)calendar:simmarket.nysecalendar[2026.01.01;2026.12.31]
q)count calendar
251
q)select from calendar where closingtime=13:00
date       closingtime volmult volumemult jumpintensity
-------------------------------------------------------
2026.11.27 13:00
2026.12.24 13:00
q)simmarket.savecalendar[`:mycalendar.csv;calendar]
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

Days differ. Two standardized AR(1) states with persistence `regimepersistence`, `volstate` for volatility and `volumestate` for volume, are driven by daily shocks with correlation `regimecorr`. They give each day a volatility multiplier `exp(volregimesd * volstate - volregimesd^2)` and a volume multiplier `exp(volumeregimesd * volumestate - volumeregimesd^2 / 2)`, so busy days tend to be volatile days (at 0.7 they are strongly related without being one thing, as in markets) and spells of a few days cluster. The volume multiplier averages 1; the volatility multiplier is normalized on its square instead, since volatility enters a day as variance, so the close-to-close variance averages the configured `vol^2 / tradingdays` rather than exceeding it by `exp(volregimesd^2)`. The calendar's own `volmult` and `volumemult` multiply on top, for event days. `simmarket.regimes[cfg;calendar]` returns the resolved multipliers, and the `days` table carries them.

### Seeds: one per day, shared across instruments

With `cfg[`seed]` set, every date gets a regime seed from the seed and the date alone, so a date's regime innovation is the same in any calendar that contains it and, since it does not depend on `sym`, the same for every instrument run on that date: the market's day. From it the instrument gets a day seed (for its tape) and a gap seed (for its overnight return). Consequences:

- Any day can be regenerated alone, exactly, from its row of the `days` table: `simtick.run simmarket.daycfg[cfg;days d;days[d]`open]`.
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
make test-simmarket
```

or from a q session:

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simmarket
```

The suite (161 checks) covers calendar validation and loading, the composition of several instruments on one scenario or one each, the NYSE generator (2026's 251 days, its holidays and early closes, Good Friday by year, the New Year and Christmas observance rules, a saved calendar loading back), the overnight gap and the variance budget, the seeds and regimes, a half day, a tripled-volume day and a jump day from the calendar, a day regenerated exactly from its row, several instruments run together in memory, the output database (loads with `\l`, schema and attributes, disk equal to memory per date and stock, two stocks in one run, a stock alone or with others, every table in every partition, trades only, compression applied and read back, an interrupted run resumed, a database of another configuration refused, the run reproduced from its config file) and reproducibility.

## Future Extensions

- **A market factor across instruments**: the shared regime seed is the hook for a common day and, later, a common intraday path

## License

MIT
