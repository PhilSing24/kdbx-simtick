# di.simtick

Realistic intraday tick data simulator for KDB-X with configurable market microstructure.

For a detailed explanation of the mathematical foundations, see the [Technical Paper](docs/IntradayTickSimulatorPaper.pdf).

## About

Realistic synthetic tick data is valuable for many quantitative finance workflows. This module generates trade and quote data that captures key statistical properties of real markets.

The module is designed for **progressive complexity**: configure from simple to sophisticated scenarios by adjusting parameters:

- **Baseline**: Set `alpha:0` and equal multipliers for basic Poisson arrivals with GBM prices
- **Add seasonality**: Set `profile` to the half-hour weights of the intraday pattern (U-shape, J-shape, or anything measured)
- **Add clustering**: Increase `alpha` to enable Hawkes self-excitation for realistic trade bursts
- **Add jumps**: Switch to `pricemodel:jump` for discontinuous price moves
- **Add quotes**: Set `generatequotes:1b` to return the quotes as well as the trades (they are always generated, since trades execute against them)

This flexibility allows the same module to serve quick prototypes and sophisticated stress-testing scenarios.

### Key Features

- **Trade clustering** — real trades arrive in bursts, not uniformly. We use a Hawkes process to model this self-exciting behavior.
- **Intraday seasonality** — trading activity is high at open and close, low at midday. The `profile` gives one weight per half hour, so a flat midday and a spike in the last minutes are both expressible, and the opening and closing auction prints frame the session.
- **Price dynamics** — GBM with optional jump-diffusion captures continuous price movement and occasional discontinuities. The diffusion runs on a transaction clock by default: each quote update carries the same variance, so volatility follows activity, U-shaped through the day and higher in bursts, as in a market (`clock:calendar` keeps the flat, time-based variance).
- **Coupled activity, volatility and spread** — a jump seeds a burst of trades and quotes that fades over minutes (`jumpburst`, `jumpburstminutes`), and the spread widens with local activity (`spreadactivity`), so volatility, volume and spread rise together.
- **Microstructure** — quotes come first, on their own clock: the price path is the mid, the spread is a whole number of ticks (one most of the day, wider in the first minutes after the open), and trades execute against the quote in force. A buyer-initiated trade takes the ask and a seller-initiated one the bid, with a persistent aggressor side, a share of prints at the midpoint and a share with price improvement. Quote updates partly follow the trades, and quote sizes are lognormal round lots whose imbalance leans toward the next mid move. Trades carry an `aggressor` column, so effective spread, realized spread, Lee-Ready classification and markouts are all well defined.
- **Order-flow impact** — a propagator: each signed trade moves the mid in its direction by `impactticks` ticks scaled by its size, a share `impactpermanent` of which stays while the rest halves every `impacthalflife` seconds. With persistent aggressor signs the tape shows price impact and partial reversion after a trade, what markout curves measure.
- **Realistic pricing** — trade prices and quote bid/ask rounded to the configured tick size (`ticksize`, 0.01 for US equities).
- **Tape attributes** — trade sizes as printed on a US tape (round lots, blocks and odd lots under `qtymodel:mixture`), a condition flag (`R` regular, `I` odd lot, `O` and `C` auction prints), a venue (lit MIC codes by share, or `TRF` for off-exchange prints, which is where midpoint and improved prints go), and one sequence number across quotes and trades. The quotes are one consolidated top of book, the NBBO; venues appear on trades only.

### Market Focus

The default presets and parameter examples are calibrated for **US equity markets** (NVDA on NASDAQ). Key characteristics:

- High liquidity at open and close, quiet midday (J-shape or U-shape), with auction prints at the open and the close
- Spreads widest in the first minutes after the open, one tick most of the day, tightest at the close
- Arrival rates and volatility consistent with large-cap tech stocks

**Futures markets** have different microstructure — most liquid in the last 5-10 minutes before close with the tightest spreads, and wider spreads at midday. A `profile` with a large last weight and the spread multipliers approximate that; the auction percentages can be set to zero.

### Use Cases

**Stress testing and scenario analysis** — Generate data under severe but plausible conditions. Simulate liquidity shocks by lowering `baseintensity`, gap moves using the jump-diffusion model (`pricemodel:jump`), or extreme volatility regimes by increasing `vol`. Test how your systems behave when markets break from normal patterns.

**Sensitivity and robustness testing** — Vary parameters systematically to understand how strategies respond to changes in volatility, trade frequency, or spread dynamics. Identify breaking points before they occur in production.

**System development** — Stress-test data ingestion pipelines by adjusting trade arrival rates. Increase `baseintensity` (e.g., from 1.0 to 50) and `alpha` to simulate high-frequency bursts. This lets you verify that your database, message queues, and processing logic handle peak loads without data loss or latency spikes.

**Real-time demos** — Feed simulated data to dashboards, visualization tools, or trading interfaces. Useful for demos, training sessions, or testing UI responsiveness without connecting to live markets.

### Limitations

Quotes are generated first and trades execute against the quote in force, so the causality of a real market is respected at the top of the book. The model stays simplified beyond that:

- **One-way link between the clocks** — a share `quotetradelink` of the quote updates is seeded by the trades, so a burst of trades brings a burst of quotes; quotes do not in turn excite trades
- **Quotes per trade** — the presets use 4 to keep a day's data small; a real large cap shows 10 to 30, and `quotespertrade` sets it
- **No depth** — only the touch is modelled: no queue, no queue position, no book beyond the best bid and ask

**Not suitable for:**

- **Advanced Market-making research** — no order book queue dynamics, no queue position modeling
- **Execution optimization** — no realistic fill probability or market impact simulation
- **HFT strategy development** — no depth, independent quote and trade clocks

For these advanced use cases, a full limit order book simulator with queue dynamics would be preferred.

### Next Steps

`di.simcalendar` extends this simulator, using the KDB-X module framework's **sibling architecture**. Each module lives at the same level under `di/` and declares dependencies via relative module references.

**Module hierarchy:**

```
di/
├── simtick/           # 1 instrument, 1 day (atomic unit)
└── simcalendar/       # 1 instrument, N days (uses ..simtick)
```

**Dependency chain:**

```
simtick ← simcalendar
```

Each module builds on its predecessor. This design allows users to load only what they need while keeping each module focused on a single responsibility.

**Note:** We use absolute module paths (`use`di.simtick`) rather than relative sibling references (`use`..simtick`). The sibling syntax did not work in our testing with KDB-X Community Edition — further investigation needed.

---

**`di.simcalendar`** — Single instrument over multiple trading days

- Accepts a list of trading dates (e.g., NYSE calendar)
- Orchestrates `di.simtick` for each day
- Carries forward closing price as next day's opening price (no overnight gap modeling)
- Optional disk persistence to date-partitioned kdb+ database

### Configuration

Simulations are driven by a configuration dictionary containing all model parameters (arrival rates, volatility, spread settings, etc.). Rather than building these manually, the module reads configurations from a **CSV file**.

A ready-to-use file `presets.csv` is included with three market scenarios (default, volatile, jumpy) for each of NVDA, XOM and PG. Every knob of a run is a column of the preset, including the tick size and the quote-generation settings, so a preset describes a run fully. `loadconfig` checks the header against the schema: columns may come in any order, and a missing, unknown or repeated column throws rather than parsing values into the wrong types. You can:

- Use presets directly: `cfg:cfgs`nvda_default`
- Modify values for specific runs: `cfg[`vol]:0.65`
- Add new rows to define custom scenarios
- Create your own CSV following the same schema

To see all available parameters and their descriptions:
```q
q)simtick.describe[]
```


## Overview

A KDB-X module for simulating realistic intraday trade and quote data. Features:

- **Hawkes process** for trade arrivals (self-exciting, captures trade clustering)
- **GBM / Jump-diffusion** for price dynamics
- **Configurable intraday patterns** (U-shape or J-shape intensity)
- **Quote generation** with realistic bid-ask spreads
- **CSV-based presets** for different market scenarios

## Installation

1. Add this repository to your `QPATH`:
```bash
export QPATH=$QPATH:/path/to/kdbx-modules
```

2. Load the module:
```q
q)simtick:use`di.simtick
```

## Usage

### Basic usage
```q
q)simtick:use`di.simtick
q)cfgs:simtick.loadconfig`:di/simtick/presets.csv
q)cfg:cfgs`nvda_default
q)simtick.run[cfg]
sym  time                          seq price   qty    aggressor cond venue
--------------------------------------------------------------------------
NVDA 2026.08.18D09:30:00.000000000 2   215     424347           O    XNAS
NVDA 2026.08.18D09:30:00.100212953 7   215.011 7      S         I    TRF
NVDA 2026.08.18D09:30:00.182414049 11  215.01  66     S         I    XNAS
...
```

### With quote generation
```q
q)cfg[`generatequotes]:1b
q)result:simtick.run[cfg]
q)result`trade
q)result`quote
```

## API

| Function | Description |
|----------|-------------|
| `simtick.run[cfg]` | Full simulation - returns trades (or dict with quotes) |
| `simtick.arrivals[cfg]` | Generate arrival times only (seconds from open) |
| `simtick.price[cfg;times]` | Generate prices for given times |
| `simtick.loadconfig[filepath]` | Load presets from CSV |
| `simtick.describe[]` | Return configuration schema as table |

## Presets

Three scenarios for each of three US large caps, NVDA (NASDAQ), XOM and PG (NYSE), named `<sym>_<scenario>`:

| Preset | Description |
|--------|-------------|
| `nvda_default`, `xom_default`, `pg_default` | Baseline trading day |
| `nvda_volatile`, `xom_volatile`, `pg_volatile` | Higher volatility and clustering regime (earnings, macro events) |
| `nvda_jumpy`, `xom_jumpy`, `pg_jumpy` | Jump-diffusion model (sudden news, guidance), with bursts after each jump |

The three names differ in `baseintensity`, `startprice`, `spreadticks` and `primaryvenue`.

## Configuration Parameters

All keys of the schema (`simtick.describe[]` returns the same list), with the `nvda_default` preset's values.

**Session**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `sym` | Ticker symbol | `` `NVDA `` |
| `tradingdate` | Simulation date | 2026.08.18 |
| `openingtime`, `closingtime` | Session open and close (minute) | 09:30, 16:00 |
| `startprice` | Price at the open | 215.00 |
| `seed` | Random seed (`0N` = no seed) | 42 |
| `rngmodel` | Random number source (`pseudo`) | `pseudo` |
| `tradingdays` | Trading days per year, for annualizing `vol` and `drift` | 252 |

**Price path**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `drift` | Annualized drift | 0.05 |
| `vol` | Annualized volatility | 0.45 |
| `pricemodel` | `gbm` or `jump` | `gbm` |
| `jumpintensity` | Jump model: jumps per day | 2.0 |
| `jumpmean`, `jumpvol` | Jump model: mean and standard deviation of the log jump size | 0.0, 0.02 |
| `jumpburst` | Extra trade immigrants seeded by each jump, each with its usual cascade | 3000 |
| `jumpburstminutes` | Mean delay in minutes of those immigrants after the jump | 1.0 |
| `clock` | `transaction` (variance per quote update: vol follows activity) or `calendar` (variance per second: flat vol) | `transaction` |

**Arrivals**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `baseintensity` | Immigrant arrival rate before the profile and the cascades (trades/sec) | 8.25 |
| `alpha` | Hawkes excitation (0 = Poisson) | 0.3 |
| `beta` | Hawkes decay (must be > alpha); the branching ratio is alpha/beta | 1.0 |
| `profile` | Intraday intensity weights, one per half hour, space-separated in the CSV | `1.6 1.2 1.0 ... 1.8` |
| `openauctionpct` | Opening auction print as a fraction of the continuous volume | 0.01 |
| `closeauctionpct` | Closing auction print as a fraction of the continuous volume | 0.08 |

**Trade sizes**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `qtymodel` | `mixture` (round lots, blocks, irregular lots), `lognormal` or `constant` | `mixture` |
| `avgqty` | Average trade size (of the irregular lots under `mixture`) | 60 |
| `qtyvol` | Log volatility of the lognormal sizes (the irregular lots under `mixture`) | 0.9 |
| `roundlotshare` | Mixture: share of trades that are round lots of 100, 200, 300, 500 or 1000 | 0.35 |
| `blockshare` | Mixture: share of trades that are blocks | 0.002 |
| `blockqty` | Mixture: median block size | 10000 |

**Quotes**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `generatequotes` | Return the quotes as well as the trades (they are always generated) | 1b |
| `ticksize` | Minimum price increment; quotes are rounded to it, trades to a tenth of it | 0.01 |
| `spreadticks` | Mean spread in ticks through the day (1 tick plus a Poisson excess) | 1.15 |
| `spreadopenmult` | Spread multiplier at the open, decaying to the midday one | 2.5 |
| `spreadmidmult` | Spread multiplier through the day | 1.0 |
| `spreadclosemult` | Spread multiplier at the close, reached by the same decay | 0.9 |
| `spreaddecayminutes` | Minutes over which the open and close multipliers decay toward the midday one | 15 |
| `spreadactivity` | Exponent of local quote activity (trailing minute over its expected level) on the mean spread; 0 = none | 0.5 |
| `quotespertrade` | Quote updates per trade on average (quotes arrive on their own Hawkes clock at this multiple of the trade intensity) | 4 |
| `quotetradelink` | Share of the quote updates seeded by the trades, at Exp(beta) delays after them | 0.5 |
| `avgquotesize` | Average quote size, in shares | 500 |
| `quotesizevol` | Log volatility of quote sizes, lognormal around `avgquotesize` in round lots of 100 | 0.6 |
| `imbalancesignal` | Log tilt of the sizes toward the side of the next mid move (the book leans, weakly, toward what comes next) | 0.15 |

**Trades against the quotes**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `sidepersistence` | Probability a trade's aggressor side repeats the previous one (0.5 = independent) | 0.7 |
| `midpointshare` | Share of trades printing at the midpoint | 0.12 |
| `improvementshare` | Share of trades printing a tenth of a tick inside the touch | 0.08 |
| `offexchangeshare` | Share of trades printed off-exchange (`TRF`) | 0.42 |
| `primaryvenue` | Primary listing venue, where the auction prints are | `XNAS` |
| `impactticks` | Ticks an average-size trade moves the mid in its direction, scaled by sqrt(qty / mean size); 0 turns impact off | 0.25 |
| `impacthalflife` | Seconds over which the transient part of a trade's impact halves | 30 |
| `impactpermanent` | Share of a trade's impact that never decays | 0.3 |

## Testing

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simtick
```

### Test Coverage

| Group | Tests | Description |
|-------|-------|-------------|
| Validation | 9 | Bad configs throw correct errors (alpha >= beta, negative intensity, zero profile weight, zero/negative vol, zero/negative startprice, impactpermanent above 1, unknown clock) |
| Arrivals | 9 | Output properties: non-empty, sorted, positive, within duration, correct type; count matches the Hawkes mean for a flat baseline at branching ratios 0.3 and 0.9; 1-second counts overdispersed with excitation, Poisson without |
| Shape | 3 | Intraday pattern: open > mid, close > mid, J-shape verification |
| Price | 6 | Positive prices, startprice correct, realized vol within tolerance, jump model works |
| Trades | 26 | Correct schema with aggressor, cond, venue and seq, round-lot, odd-lot and block shares, cond I on odd lots, venues in the MIC set with about offexchangeshare on the TRF and auctions on the primary venue, sequence ascending, the opening and closing auction prints at the open and close with closeauctionpct of the continuous volume and no aggressor, sorted times, positive prices/qty, integer qty, within session, prices on the tenth-of-a-tick grid, day-level realized vol matches the configured vol, hourly vol follows activity on the transaction clock and is flat on the calendar clock |
| Quotes | 43 | Correct schema, sorted times, bid < ask, positive sizes, first quote at the open, every trade inside its prevailing quote, shares at the touch, midpoint and inside the touch match the config, buys at the ask and sells at the bid, aggressor signs persist, about quotespertrade quotes per trade, spread a whole number of ticks and at least one, one tick most of the time midday with a mean about spreadticks, wider in the first five minutes and no wider in the last five, bids and asks on the tick grid, signed 1-second markout positive with impact and zero without, a jump seeds a burst of trades, the burst widens the spread with activity coupling and not without, with flat profiles the spread tracks activity, per-second quote counts follow trade counts with the trade link and not without, sizes in round lots, seq ascending and one sequence across quotes and trades starting with the opening quote, midpoint prints off-exchange, the size imbalance leans toward the next mid move with the signal and not without |
| Config | 10 | Keyed table, correct column count, correct types (float, symbol, date); columns in any order load identically, a missing or unknown column throws |
| Describe | 3 | Returns table, correct columns, correct parameter count |
| Constant Qty | 2 | All quantities equal, quantity equals avgqty |
| Reproducibility | 1 | Same seed produces same output |
| **Total** | **110** | |

## Documentation

The `docs/` folder contains:

- **[IntradayTickSimulatorPaper.pdf](docs/IntradayTickSimulatorPaper.pdf)** — Technical paper detailing the mathematical foundations of this module (Hawkes process, GBM, jump-diffusion, quote generation)
- **[HawkesProcessesInFinance.pdf](docs/HawkesProcessesInFinance.pdf)** — Reference paper on Hawkes processes in finance (Bacry et al., 2015)

The technical paper describes quotes as derived from the trades; the module now generates the quotes first, on their own clock, and the trades against them (see [Limitations](#limitations)). The paper also describes the arrivals as simulated by Ogata thinning. The module simulates the same process through its cluster representation instead (Hawkes and Oakes, 1974): immigrants arrive as an inhomogeneous Poisson process at the seasonal baseline, and every event spawns Poisson(`alpha`/`beta`) children at exponential delays, generation after generation. The two are equal in distribution, but the cluster form needs no upper bound on the intensity, so bursts are never capped (a fixed bound under-produced arrivals by 5% at branching ratio 0.4 and by 3x at 0.9), and it runs as vector operations.

## Project Structure

```
di/simtick/
├── init.q           # Module code
├── presets.csv      # Market scenario presets
├── test.csv         # Unit tests (k4unit format)
├── README.md        # This file
└── docs/
    ├── IntradayTickSimulatorPaper.pdf
    └── HawkesProcessesInFinance.pdf
```

## License

MIT
