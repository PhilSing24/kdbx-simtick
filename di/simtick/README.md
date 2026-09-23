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

The presets are calibrated for **US large-cap stocks** (NVDA on NASDAQ, XOM and PG on NYSE):

- Busy open and close, quiet midday, with opening and closing auctions
- Spreads widest just after the open, one tick most of the day, slightly tighter at the close
- Trading rates and volatility typical of large caps

**Futures markets** behave differently: they are most active in the last minutes before the close, with the tightest spreads then and wider spreads at midday. A `profile` with a large last weight and the spread multipliers get close to that; set the auction percentages to 0.

### Use cases

**Stress testing and scenarios**: generate severe but plausible days. Lower `baseintensity` for a liquidity drought, use `pricemodel` `jump` for gap moves, or raise `vol` for turbulent markets, and see how your systems behave.

**Sensitivity testing**: vary one parameter at a time to see how a strategy or analysis responds to volatility, trading rate or spreads.

**System development**: load-test data pipelines by raising the trading rate, for example `baseintensity` from 8.25 to 50 with a higher `alpha` for intense bursts, and check that databases, queues and processing keep up.

**Demos and training**: feed dashboards, visualizations or trading screens without connecting to a live market.

### Limitations

- **Best bid and offer only**: there is no order book depth and no queue beyond the displayed size at the best prices.
- **One-way link between quotes and trades**: trades trigger quote updates, but quotes do not trigger trades.
- **Quotes per trade**: the presets use 4 to keep the data small; real large caps show 10 to 30 (`quotespertrade`).
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

The shipped presets return trades and quotes together:

```q
q)simtick:use`di.simtick
q)cfgs:simtick.loadconfig`:di/simtick/presets.csv
q)cfg:cfgs`nvda_default
q)result:simtick.run cfg
q)result`trade
sym  time                          seq price   qty    aggressor cond venue
--------------------------------------------------------------------------
NVDA 2026.08.18D09:30:00.000000000 2   215     424347           O    XNAS
NVDA 2026.08.18D09:30:00.100212953 7   215.011 7      S         I    TRF
NVDA 2026.08.18D09:30:00.182414049 11  215.01  66     S         I    XNAS
...
q)result`quote
```

For trades only, turn quotes off before running:

```q
q)cfg[`generatequotes]:0b
q)simtick.run cfg          / returns the trade table
```

The first trade is the opening auction (`cond` `O`), which has no aggressor.

## API

| Function | Description |
|----------|-------------|
| `simtick.run[cfg]` | Full simulation: a dictionary with `trade` and `quote` when `generatequotes` is 1, otherwise the trade table |
| `simtick.arrivals[cfg]` | Trade arrival times only, in seconds from the open |
| `simtick.price[cfg;times]` | Prices at the given times |
| `simtick.loadconfig[filepath]` | Load presets from a CSV file |
| `simtick.describe[]` | All configuration parameters, with their types and descriptions |

## Configuration

A run is driven by a configuration dictionary holding every parameter. Rather than building it by hand, load it from a CSV file.

`presets.csv` contains three scenarios for each of NVDA, XOM and PG, named `<sym>_<scenario>`:

| Preset | Description |
|--------|-------------|
| `nvda_default`, `xom_default`, `pg_default` | A normal trading day |
| `nvda_volatile`, `xom_volatile`, `pg_volatile` | Higher volatility and stronger clustering (earnings, macro events) |
| `nvda_jumpy`, `xom_jumpy`, `pg_jumpy` | Sudden price jumps (news, guidance), each followed by a burst of trading |

The three stocks differ in trading rate (`baseintensity`), price, spread and listing venue. They currently share the same volatility.

Every parameter is a column of the file, so a preset describes a run completely. `loadconfig` checks the header against the schema: columns can be in any order, and a missing, unknown or repeated column raises an error instead of loading values into the wrong types. You can:

- Use a preset directly: `` cfg:cfgs`nvda_default ``
- Change a value for one run: `` cfg[`vol]:0.65 ``
- Add rows to the file for your own scenarios
- Write your own CSV with the same columns

To list every parameter with its description:

```q
q)simtick.describe[]
```

## Configuration parameters

All parameters, with the values of the `nvda_default` preset.

**Session**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `sym` | Ticker symbol | `` `NVDA `` |
| `tradingdate` | Date to simulate | 2026.08.18 |
| `openingtime`, `closingtime` | Session open and close | 09:30, 16:00 |
| `startprice` | Price at the open | 215.00 |
| `seed` | Random seed (`0N` for none) | 42 |
| `rngmodel` | Random number generator | `pseudo` |
| `tradingdays` | Trading days per year, used to annualize `vol` and `drift` | 252 |

**Price**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `drift` | Annual drift | 0.05 |
| `vol` | Annual volatility | 0.45 |
| `pricemodel` | `gbm` (continuous) or `jump` (with sudden jumps) | `gbm` |
| `jumpintensity` | Jump model: average number of jumps per day | 2.0 |
| `jumpmean`, `jumpvol` | Jump model: mean and standard deviation of the log jump size | 0.0, 0.02 |
| `jumpburst` | Extra trades started by each jump; each can trigger follow-up trades, so the burst grows larger | 3000 |
| `jumpburstminutes` | Average delay, in minutes, of those extra trades after the jump | 1.0 |
| `clock` | `transaction`: volatility follows trading activity (U-shaped, higher in bursts); `calendar`: constant through the day | `transaction` |

**Trade arrivals**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `baseintensity` | Base trading rate in trades per second, before the intraday profile and the follow-up trades | 8.25 |
| `alpha` | How strongly each trade triggers more trades (0 = no clustering) | 0.3 |
| `beta` | How fast that effect fades (must be greater than `alpha`) | 1.0 |
| `profile` | Intraday activity weights, one per half hour, space-separated in the CSV | `1.6 1.2 1.0 ... 1.8` |
| `openauctionpct` | Opening auction size as a share of the day's continuous volume | 0.01 |
| `closeauctionpct` | Closing auction size as a share of the day's continuous volume | 0.08 |

**Trade sizes**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `qtymodel` | `mixture` (round lots, odd lots and blocks), `lognormal` or `constant` | `mixture` |
| `avgqty` | Average size of the odd lots (or of all trades under `lognormal` and `constant`) | 60 |
| `qtyvol` | Spread of those sizes (log standard deviation) | 0.9 |
| `roundlotshare` | Share of trades that are round lots of 100, 200, 300, 500 or 1000 shares | 0.35 |
| `blockshare` | Share of trades that are blocks | 0.002 |
| `blockqty` | Median block size | 10000 |

**Quotes**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `generatequotes` | Return the quotes as well as the trades | 1b |
| `ticksize` | Minimum price increment | 0.01 |
| `spreadticks` | Average spread in ticks | 1.15 |
| `spreadopenmult` | Spread multiplier at the open | 2.5 |
| `spreadmidmult` | Spread multiplier through the day | 1.0 |
| `spreadclosemult` | Spread multiplier at the close | 0.9 |
| `spreaddecayminutes` | Minutes for the open and close effects to fade | 15 |
| `spreadactivity` | How much busy periods widen the spread (0 = not at all) | 0.5 |
| `quotespertrade` | Average number of quote updates per trade | 4 |
| `quotetradelink` | Share of quote updates triggered by trades | 0.5 |
| `avgquotesize` | Average size at the bid and at the ask, in shares | 500 |
| `quotesizevol` | Spread of the quote sizes (log standard deviation), in round lots of 100 | 0.6 |
| `imbalancesignal` | How much bid and ask sizes lean toward the next price move (0 = not at all) | 0.15 |

**Trades against the quotes**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `sidepersistence` | Probability that a trade has the same side (buy or sell) as the previous one (0.5 = independent) | 0.7 |
| `midpointshare` | Share of trades at the midpoint | 0.12 |
| `improvementshare` | Share of trades a tenth of a tick inside the bid or ask | 0.08 |
| `offexchangeshare` | Share of trades reported off-exchange (`TRF`) | 0.42 |
| `primaryvenue` | Listing exchange, where the auctions take place | `XNAS` |
| `impactticks` | Ticks an average-size trade moves the price in its direction, scaled by the square root of its relative size (0 = no impact) | 0.25 |
| `impacthalflife` | Seconds for the fading part of a trade's impact to halve | 30 |
| `impactpermanent` | Share of a trade's impact that never fades | 0.3 |

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
| Validation | 9 | Invalid configurations raise the right error |
| Arrivals | 9 | Arrival times are sorted and within the session; counts match the theoretical Hawkes average; trades cluster with `alpha` above 0 and not without |
| Shape | 3 | The intraday pattern: busier at the open and close than at midday |
| Price | 6 | Prices positive, start at `startprice`, volatility within tolerance, jump model works |
| Trades | 26 | Columns and types, trade sizes, condition codes, venues and off-exchange share, auctions, sequence numbers, prices on the grid, volatility over the day and by hour |
| Quotes | 43 | Every trade within its quote, buys at the ask and sells at the bid, side persistence, quotes per trade, spreads in whole ticks and their pattern through the day, market impact, bursts after jumps, quote updates following trades, quote sizes and their lean toward the next move |
| Config | 10 | CSV loading: types, columns in any order, missing or unknown columns rejected |
| Describe | 3 | The parameter list |
| Constant quantity | 2 | All sizes equal `avgqty` |
| Reproducibility | 1 | The same seed gives the same output |
| **Total** | **110** | |

## Documentation

The `docs/` folder contains:

- **[IntradayTickSimulatorPaper.pdf](docs/IntradayTickSimulatorPaper.pdf)**: the mathematical foundations of all three modules, with the statistics the simulator reproduces
- **[HawkesProcessesInFinance.pdf](docs/HawkesProcessesInFinance.pdf)**: reference paper on Hawkes processes in finance (Bacry, Mastromatteo and Muzy, 2015)

## Project structure

```
di/simtick/
├── init.q           # module code
├── presets.csv      # market scenario presets
├── test.csv         # unit tests (k4unit format)
├── testing.q        # manual test script
├── README.md        # this file
└── docs/
    ├── IntradayTickSimulatorPaper.pdf
    └── HawkesProcessesInFinance.pdf
```

## License

MIT
