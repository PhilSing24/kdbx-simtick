# di.simtick

Realistic intraday tick data simulator for KDB-X: one instrument, one trading day, trades and quotes.

For the mathematics behind every model, see the [technical paper](docs/IntradayTickSimulatorPaper.pdf).

## About

Realistic synthetic tick data is useful whenever real market data is unavailable, expensive or too sensitive to share. This module generates trades and quotes that reproduce the main features of real intraday data.

You can start simple and add realism one step at a time:

- **Baseline**: set `alpha` to 0 and all `profile` weights to 1 for trades arriving at a constant average rate and a plain random-walk price
- **Intraday pattern**: set `profile` to half-hour weights for a busy open and close and a quiet midday
- **Clustering**: raise `alpha` so that trades arrive in bursts
- **Jumps**: set `pricemodel` to `jump` for sudden price moves
- **Quotes**: set `generatequotes` to 1 to return the quotes as well as the trades (they are always generated, since trades happen against them)

### Key features

- **Trade clustering**: trades arrive in bursts, modelled by a Hawkes process, in which each trade makes the next one more likely.
- **Intraday pattern**: trading is busy in the first half hour, quiet at midday and busiest before the close. The `profile` gives one weight per half hour, and opening and closing auction trades frame the session.
- **Price moves**: the price moves continuously, with optional sudden jumps. By default its volatility follows trading activity, so it is U-shaped through the day and higher in bursts (`clock` set to `calendar` keeps it constant instead).
- **Activity, volatility and spread move together**: a jump is followed by a burst of trades and quotes that fades over minutes, and the spread widens when the market is busy.
- **Quotes and trades**: quotes come first and trades happen against them. The spread is a whole number of ticks, usually one, and wider just after the open. A buy trades at the ask and a sell at the bid, with some trades at the midpoint or slightly inside. Buys tend to follow buys and sells follow sells. Every trade carries an `aggressor` column (`B` or `S`), so effective spread, realized spread, trade classification and markouts can all be measured.
- **Order-flow impact**: a buy pushes the price up and a sell pushes it down, part of the move fades over time and part stays, so the data shows price impact and partial reversal after trades.
- **Tick size**: bid and ask prices sit on the tick grid (`ticksize`, 0.01 for US stocks).
- **Tape details**: trade sizes mix round lots, odd lots and occasional blocks; every trade has a condition code (`R` regular, `I` odd lot, `O` and `C` for the auctions), a venue (exchange codes, or `TRF` for off-exchange trades), and a sequence number shared with the quotes. The quotes are the consolidated best bid and offer across all venues.

### Market focus

The shipped market file and instruments are calibrated for **US large-cap stocks** (NVDA on NASDAQ, XOM and PG on NYSE):

- Busy open and close, quiet midday, with opening and closing auctions
- Spreads widest just after the open, one tick most of the day, slightly tighter at the close
- Trading rates and volatility typical of large caps

**Futures markets** behave differently: they are most active in the last minutes before the close, with the tightest spreads then and wider spreads at midday. A `profile` with a large last weight and the spread multipliers get close to that; set the auction percentages to 0.

### Use cases

**Stress testing and scenarios**: generate severe but plausible days. Lower `tradesperday` for a liquidity drought, use `pricemodel` `jump` for gap moves, or raise `vol` for turbulent markets, and see how your systems behave.

**Sensitivity testing**: vary one parameter at a time to see how a strategy or analysis responds to volatility, trading rate or spreads.

**System development**: load-test data pipelines by raising the trading rate, for example `tradesperday` from 500,000 to 3,000,000 with a higher `alpha` for intense bursts, and check that databases, queues and processing keep up.

**Demos and training**: feed dashboards, visualizations or trading screens without connecting to a live market.

### Limitations

- **Best bid and offer only**: there is no order book depth and no queue beyond the displayed size at the best prices.
- **One-way link between quotes and trades**: trades trigger quote updates, but quotes do not trigger trades.
- **Quotes per trade**: the shipped market uses 4 to keep the data small; real large caps show 10 to 30 (`quotespertrade`).
- **Instruments are independent**: running several instruments gives separate days that do not move together.
- **Quote sizes lean toward the next price move**: this reproduces a real regularity, but the model uses the known next move to do it, so the signal is cleaner than in real data. Keep it in mind before training predictive models on the output.
- **Price improvement**: trades slightly inside the spread sit on a tenth of a tick, and a small share of them are assigned to lit exchanges, where real prices would be on the tick or at the midpoint.

**Not suitable for** market-making or high-frequency research that needs order book depth and queue dynamics; a full limit order book simulator is the right tool there.

## Related modules

`di.simtick` is the first of three modules, each building on the one before:

```
di/
├── simtick/       # one instrument, one day
├── simcalendar/   # runs simtick over a calendar of trading days
└── simorder/      # generates orders and executes them against the simulated market
```

- **`di.simcalendar`**: runs `di.simtick` day after day over a trading calendar (with a generator for NYSE holidays and half days), links consecutive days with overnight price gaps, varies volatility and volume from day to day, and can write the result to a date-partitioned kdb+ database. Any single day can be regenerated on its own.
- **`di.simorder`**: splits parent orders into child orders that cross the spread or wait at the best price, records every order event (new, replace, cancel, fill), and can apply the market impact of the executions.

**Note:** modules are loaded with absolute paths (`` use`di.simtick ``) rather than relative sibling references (`` use`..simtick ``), which did not work in our testing with KDB-X Community Edition.

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

The simplest run takes the five values that describe a stock (ticker, price, annual drift, annual volatility, trades per day) and the date. Everything else comes from the shipped market file:

```q
q)simtick:use`di.simtick
q)result:simtick.quick[`NVDA;215.0;0.08;0.45;500000;2026.08.18]
q)result`trade
sym  time                          seq price   qty    aggressor cond venue
--------------------------------------------------------------------------
NVDA 2026.08.18D09:30:00.000000000 2   215     424347           O    XNAS
NVDA 2026.08.18D09:30:00.100212953 7   215.011 7      S         I    TRF
NVDA 2026.08.18D09:30:00.182414049 11  215.01  66     S         I    XNAS
...
q)result`quote
```

`quick` is reproducible: the seed is the run default of the market file. `quickwith` takes a seventh argument with any run override, for example `` (enlist `seed)!enlist 7 `` or `` `seed`generatequotes!(7;0b) ``.

For anything beyond that, compose a configuration from the four layers and run it:

```q
q)f:simtick.files[]                         / the shipped market, instruments and scenarios
q)market:simtick.loadmarket f`market
q)instruments:simtick.loadinstruments f`instruments
q)scenarios:simtick.loadscenarios f`scenarios
q)cfg:simtick.compose[market;instruments`XOM;scenarios`volatile;(enlist `seed)!enlist 7]
q)result:simtick.run cfg
```

For trades only, turn quotes off in the run layer, or on the composed configuration before running:

```q
q)cfg[`generatequotes]:0b
q)simtick.run cfg          / returns the trade table
```

The first trade is the opening auction (`cond` `O`), which has no aggressor.

## API

| Function | Description |
|----------|-------------|
| `simtick.quick[sym;price;drift;vol;tradesperday;tradingdate]` | One day of one stock from its five essential values and the date, on the shipped market and the normal scenario |
| `simtick.quickwith[sym;price;drift;vol;tradesperday;tradingdate;run]` | The same with a run override (seed, quotes) |
| `simtick.compose[market;instrument;scenario;run]` | The flat configuration of a run from the four layers, with the scenario multipliers applied and `baseintensity` derived |
| `simtick.run[cfg]` | Full simulation: a dictionary with `trade` and `quote` when `generatequotes` is 1, otherwise the trade table |
| `simtick.arrivals[cfg]` | Trade arrival times only, in seconds from the open |
| `simtick.price[cfg;times]` | Prices at the given times |
| `simtick.files[]` | The paths of the shipped market, instrument and scenario files |
| `simtick.loadmarket[filepath]` | A market file (JSON) as a flat dictionary |
| `simtick.loadinstruments[filepath]` | An instrument file (CSV) as a table keyed by `sym` |
| `simtick.loadscenarios[filepath]` | A scenario file (CSV) as a table keyed by `name` |
| `simtick.saveconfig[filepath;cfg]` | Write a composed configuration to a JSON file |
| `simtick.loadconfig[filepath]` | Read it back; `baseintensity` is checked against `tradesperday` |
| `simtick.intensityfor[cfg]` | The base intensity that gives `tradesperday` trades under the configuration |
| `simtick.describe[]` | Every parameter with its type, layer, group and description |

## Configuration

A run is driven by a flat dictionary holding every parameter, which `compose` builds from four layers so that nobody has to look at seventy keys to simulate a stock:

| Layer | What it holds | Shipped as |
|-------|---------------|------------|
| market | How a market works: session times, tick size, arrival clustering and intraday profile, sizes, spreads, venues and their shares, impact. Also the run defaults (date, seed, quotes) | `di/simconfig/markets/us_largecap.json`, grouped by topic |
| instrument | What makes a stock itself: `sym`, `price`, `drift`, `vol`, `tradesperday`, and any market key it overrides (XOM and PG override `spreadticks` and `primaryvenue`) | `di/simconfig/instruments.csv`, one row per stock |
| scenario | What makes a day type: multipliers of vol, trades per day and spread, the jump model, and the day-to-day regime keys read by `di.simcalendar` | `di/simconfig/scenarios.csv`: `normal`, `volatile`, `jumpy` |
| run | What changes between two runs of the same stock: `tradingdate`, `seed`, `generatequotes` | a dictionary, empty for the market defaults |

The layers are composed in that order, a later one overriding an earlier one. `compose` is strict: every value is cast to the type of the schema, an unknown key throws, and a missing key throws naming the layer that should supply it. There are no silent defaults. The scenario multipliers are applied once and then set to 1, so a saved configuration is not multiplied again.

`baseintensity`, the immigrant rate of the Hawkes process, is derived from `tradesperday`: the trades the jump bursts are expected to add are taken out, the cascades (a share `alpha/beta` of all trades) are taken out, and the rest is spread over the session at the average level of the intraday profile. `loadconfig` recomputes it, so a hand-edited `tradesperday` in a saved file is honoured and a `baseintensity` that disagrees with it throws.

To edit the layers, add a row to the instrument or scenario file, copy the market file for another market, or pass your own dictionaries: `compose` takes any dictionary for the instrument, so `` `sym`price`drift`vol`tradesperday!(`ACME;100.0;0.05;0.3;100000) `` is a complete instrument. The loaders take any path.

Every parameter, with its type, layer, group and description, is listed in [docs/parameters.md](docs/parameters.md), generated from `simtick.describe[]`. The shared loading and composition code is in `di.simconfig`.


## Testing

From the repository root:

```bash
make test-simtick
```

or in a q session:

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simtick
```

### Test coverage

| Group | Tests | What is checked |
|-------|-------|-----------------|
| Validation | 8 | Invalid configurations raise the right error |
| Arrivals | 9 | Arrival times are sorted and within the session; counts match the theoretical Hawkes average; trades cluster with `alpha` above 0 and not without |
| Shape | 3 | The intraday pattern: busier at the open and close than at midday |
| Price | 6 | Prices positive, start at `price`, volatility within tolerance, jump model works |
| Trades | 26 | Columns and types, trade sizes, condition codes, venues and off-exchange share, auctions, sequence numbers, prices on the grid, volatility over the day and by hour |
| Quotes | 42 | Every trade within its quote, buys at the ask and sells at the bid, side persistence, quotes per trade, spreads in whole ticks and their pattern through the day, market impact, bursts after jumps, quote updates following trades, quote sizes and their lean toward the next move |
| Config | 31 | The layers load and compose: types, instrument overrides, scenario multipliers applied once, run overrides, missing and unknown keys rejected, a spread below one tick rejected |
| Derivation | 5 | `baseintensity` from `tradesperday`: the mean trade count over twenty seeds within 2%, with and without jumps; bursts beyond `tradesperday` rejected |
| Quick and saved | 7 | `quick` equals compose and run, on the date it is given; a saved configuration reloads unchanged and replays; `baseintensity` derived or checked on reload |
| Describe | 5 | The parameter list, the essential five first |
| Constant quantity | 2 | All sizes equal `avgqty` |
| Reproducibility | 1 | The same seed gives the same output |
| **Total** | **145** | |

## Documentation

The `docs/` folder contains:

- **[IntradayTickSimulatorPaper.pdf](docs/IntradayTickSimulatorPaper.pdf)**: the mathematical foundations of all three modules, with the statistics the simulator reproduces
- **[HawkesProcessesInFinance.pdf](docs/HawkesProcessesInFinance.pdf)**: reference paper on Hawkes processes in finance (Bacry, Mastromatteo and Muzy, 2015)

## Project structure

```
di/simconfig/
├── init.q           # layered configuration shared by the modules
├── markets/us_largecap.json
├── instruments.csv
└── scenarios.csv
di/simtick/
├── init.q           # module code
├── test.csv         # unit tests (k4unit format)
├── testing.q        # manual test script
├── README.md        # this file
└── docs/
    ├── IntradayTickSimulatorPaper.pdf
    └── HawkesProcessesInFinance.pdf
```

## License

MIT
