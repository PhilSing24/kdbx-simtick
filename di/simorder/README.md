# di.simorder

Order execution simulator for TCA (Transaction Cost Analysis) and market surveillance demos with KDB-X. Works a parent order into child orders against a `di.simtick` tape, and returns the order, its children, their lifecycle events and their fills.

## About

A TCA demo needs more than realistic market data — it needs a realistic *order* trading against that market, so cost metrics (VWAP slippage, implementation shortfall, effective spread, markouts) have something to measure. A surveillance demo needs the order's life, not just its fills: the child orders, their acknowledgements, replaces and cancels, and which of them printed. `di.simorder` takes the `trades`/`quotes` output of `di.simtick` (or `di.simcalendar`) and simulates an algo working a parent order into child orders that execute against that tape.

The module is designed around a single core idea: **execution quality is a config choice, not a random outcome**. The same order, run twice with different parameters against the *same* underlying market, produces two different, explainable cost outcomes — which is exactly the comparison a TCA demo needs to show.

- **Good execution**: patient timing (`even` pacing), mostly passive children resting at the near touch (low `spreadcapture`)
- **Bad execution**: rushed timing (`frontloaded` pacing, both in timestamp and in quantity), mostly aggressive children crossing the spread (high `spreadcapture`)
- **Arrival (implementation shortfall) algo**: `arrival` pacing, an Almgren-Chriss trajectory front-loaded by `urgency`, with the order's share of each interval's volume capped at `maxpct`

### Key Features

- **Order lifecycle** — a parent algo order, one child order per scheduled time, and an event log with `new`, `ack`, `replace`, `cancel`, `fill` and `done`, so cancel-to-fill ratios, replace counts and time to fill are all there for surveillance
- **Children that execute against the tape** — an aggressive child is a marketable order: it takes what the far touch displays and walks one tick for the rest. A passive child is a limit at the near touch, queued behind the displayed size; it fills, at its limit, when prints by the opposite aggressor reach it, re-pegs when the touch moves away (a replace, up to `maxreplaces`), and what it leaves at expiry is cancelled and rolls into the next child. A final aggressive child before `endtime` completes the order
- **Configurable pacing** — `even` (uniformly spaced, patient), `frontloaded` (rushed, concentrated early — in both timing *and* quantity; use it as a deliberately bad contrast, not as an algo) or `arrival` (an implementation-shortfall schedule under a participation cap, see [Arrival pacing](#arrival-pacing))
- **Volume-aware sizing** — under `even` pacing, child sizes are weighted by real market volume in each time bucket (pulled from `trades`), not a naive flat split
- **Seeded jitter and aggression** — children leave the exact schedule by a random share `jitter` of the gap to their neighbours, and each is aggressive with probability `spreadcapture`, so fills differ from run to run of the seed while the mean execution style is the configured one
- **Exact quantity conservation** — the fills always sum exactly to the parent order's `orderqty`
- **Tape-consistent fills** — fill prices sit on the tick or exactly at the midpoint; aggressive fills are at the far touch in force or one tick beyond, passive fills at the child's limit; each fill carries its venue, whether it added or removed liquidity, and the order's capacity
- **Arrival price benchmark** — the parent order carries the mid at `starttime`, its filled quantity and its average price, ready for implementation-shortfall calculations
- **Interval per execution** — each execution carries the length of market its child was sized against (`interval`), which is what `impact` reads

### Market Focus

Built to sit directly on top of `di.simtick`'s presets. `run` keeps only the rows of `trades`/`quotes` for the order's `sym` on the day of `starttime`, so tables holding several instruments or days (`di.simcalendar` in memory) can be passed whole. It throws when the tables have no rows for that instrument and day, when `starttime` and `endtime` fall on different days, or when `starttime` precedes the first quote of the day, rather than pricing the order off the first or last quote in silence. The shipped presets are on the same date as `di.simtick`'s.

### Use Cases

**TCA demos** — the primary use case. Run the same order twice (good vs. bad presets) against one day of simulated market data, then compare VWAP slippage and implementation shortfall between the two using any downstream SQL or analytics engine.

**Surveillance demos** — the event log carries every child's new, ack, replaces, cancels and fills with their timestamps, quantities and venues, so cancel ratios, message rates, time to fill and fill-to-order ratios per account or algo are one query away. A layering or spoofing scenario is a matter of planting children that cancel before they fill.

**Algo behavior comparison** — vary `pacing`/`spreadcapture` independently to isolate the cost contribution of *timing* urgency vs. *aggression* (spread crossing), rather than conflating the two.

**Pipeline/schema testing** — generates a realistic `orders`/`children`/`events`/`executions` set of tables to validate downstream ingestion alongside `di.simtick`'s `trades`/`quotes`.

### Limitations

This module models the top of the book seen on the tape, not a matching engine. It does not simulate:

- **Market impact inside `run`** — `run` prices an order against the market it is given and never moves it. Transient impact across orders is a separate step, `impact` (see [Market impact](#market-impact)), which a caller runs after every order's schedule and sizes and before running the orders against the moved market
- **Depth beyond the touch** — an aggressive child larger than the displayed size walks exactly one tick for the rest; the book beyond is taken to hold it
- **The tape reacting to a resting child** — the quotes come from `di.simtick` and do not know about the child resting at the touch. When the market falls through a resting buy, the child fills at its limit on the seller-initiated prints, as it would, but the tape's ask may already be below that limit. Aggressive fills are always consistent with the quote in force
- **Queue changes other than prints** — a passive child's queue position advances only with the prints ahead of it; cancels by others ahead of it are not modelled, so passive fills are on the slow side
- **Multi-venue routing** — children are routed to lit venues by a fixed share; there is no per-venue book, no smart order routing, no venue-level price improvement
- **Orders interacting** — `runmany` runs each order against the market as given; orders on the same instrument and day do not see each other's fills except through the separate `impact` step
- **Tape inclusion** — `trades` represents the market independent of this order; an order's own executions are not folded back into `trades`. A passive fill coincides in time and price with the print that filled it, so folding is a join away; this matches the standard "exclusive VWAP" TCA convention.

For these, a limit order book simulator or a multi-venue market model would be needed.

### Next Steps

`di.simorder` runs one order at a time, or a whole flow of them across instruments and days. The natural extensions are impact inside the run, so that orders on the same instrument interact as they execute, and a market that reacts to a resting child.

**Note:** as with the other `di.*` modules, this uses absolute module paths (`use`di.simtick`) rather than relative sibling references, following the same convention noted in `di.simtick`'s README.

---

### Configuration

Simulations are driven by a configuration dictionary. Rather than building one manually every time, the module reads configurations from a **CSV file** via `loadconfig`, following the same pattern as `di.simtick`.

```q
q)cfgs:simorder.loadconfig`:di/simorder/presets.csv
q)cfg:cfgs`good
```

`loadconfig` checks the header against the schema: columns may come in any order, and a missing, unknown or repeated column throws rather than parsing values into the wrong types.

To see all available parameters and their descriptions:
```q
q)simorder.describe[]
```

## Overview

A KDB-X module for simulating a parent order, its child orders and their fills against existing market data. Features:

- **Config-driven execution style** (pacing + aggression) for good/bad execution comparisons
- **Order lifecycle events** for surveillance
- **Volume-weighted sizing** derived from real market activity
- **Nanosecond-precision timestamps**, consistent with `di.simtick`'s `trades`/`quotes`
- **CSV-based presets** for repeatable good/bad scenarios

## Installation

1. Add this repository to your `QPATH`:
```bash
export QPATH=$QPATH:/path/to/kdbx-modules
```

2. Load the module (and `di.simtick`, since `di.simorder` needs its output):
```q
q)simtick:use`di.simtick
q)simorder:use`di.simorder
```

## Usage

### Basic usage
```q
q)simtick:use`di.simtick
q)simorder:use`di.simorder
q)cfgs:simtick.loadconfig`:di/simtick/presets.csv
q)result:simtick.run cfgs`nvda_default
q)trades:result`trade
q)quotes:result`quote

q)ordcfgs:simorder.loadconfig`:di/simorder/presets.csv
q)res:simorder.run[ordcfgs`good;trades;quotes]
q)res`orders
orderid account algo sym  side orderqty ordtype limitprice capacity starttime                     endtime                       arrivalprice filledqty avgpx    status
----------------------------------------------------------------------------------------------------------------------------------------------------------------------
ORD001  ACC1    VWAP NVDA BUY  10000    ALGO               A        2026.08.18D09:35:00.000000000 2026.08.18D09:45:00.000000000 215.655      10000     216.3942 filled

q)4#res`children
childid orderid sym  side qty ordtype limitprice venue sendtime                      expiry                        filledqty status replaces interval
-----------------------------------------------------------------------------------------------------------------------------------------------------------------
1       ORD001  NVDA BUY  452 LMT     215.76     ARCX  2026.08.18D09:35:30.362180781 2026.08.18D09:35:58.715263114 452       filled 0        0D00:00:28.571428571
2       ORD001  NVDA BUY  510 LMT     215.92     ARCX  2026.08.18D09:35:58.715263114 2026.08.18D09:36:26.024712362 510       filled 5        0D00:00:28.571428571
3       ORD001  NVDA BUY  400 LMT     215.73     EDGX  2026.08.18D09:36:26.024712362 2026.08.18D09:36:54.285683894 400       filled 3        0D00:00:28.571428571
4       ORD001  NVDA BUY  563 MKT                XNAS  2026.08.18D09:36:54.285683894 2026.08.18D09:37:20.614671403 563       filled 0        0D00:00:28.571428571

q)8#res`events
orderid childid time                          event   qty price  leavesqty
--------------------------------------------------------------------------
ORD001  1       2026.08.18D09:35:30.362180781 new     452 215.76 452
ORD001  1       2026.08.18D09:35:30.363180781 ack     452 215.76 452
ORD001  1       2026.08.18D09:35:30.391952169 fill    452 215.76 0
ORD001  1       2026.08.18D09:35:30.391952169 done    0   215.76 0
ORD001  2       2026.08.18D09:35:58.715263114 new     510 215.87 510
ORD001  2       2026.08.18D09:35:58.716263114 ack     510 215.87 510
ORD001  2       2026.08.18D09:35:58.833420156 replace 510 215.88 510
ORD001  2       2026.08.18D09:35:58.948935335 replace 510 215.89 510

q)5#res`executions
execid orderid childid sym  side time                          price  qty venue liquidity capacity interval
-----------------------------------------------------------------------------------------------------------------------
1      ORD001  1       NVDA BUY  2026.08.18D09:35:30.391952169 215.76 452 ARCX  A         A        0D00:00:28.571428571
2      ORD001  2       NVDA BUY  2026.08.18D09:35:58.979094902 215.89 200 ARCX  A         A        0D00:00:28.571428571
3      ORD001  2       NVDA BUY  2026.08.18D09:35:59.371977372 215.89 100 ARCX  A         A        0D00:00:28.571428571
4      ORD001  2       NVDA BUY  2026.08.18D09:36:00.401842943 215.92 122 ARCX  A         A        0D00:00:28.571428571
5      ORD001  2       NVDA BUY  2026.08.18D09:36:00.500415358 215.92 24  ARCX  A         A        0D00:00:28.571428571
```

### Execution

Each scheduled time (jittered) sends one child, sized by the pacing plus whatever the previous child left, aggressive with probability `spreadcapture` and passive otherwise, routed to a lit venue by share.

- **Aggressive child** (`ordtype` `MKT`): after `latencyms`, it takes what the far touch displays at the far touch and the rest one tick beyond, at the same instant, both fills removing liquidity (`liquidity` `R`). It is `done` at once.
- **Passive child** (`ordtype` `LMT`): after `latencyms`, a limit at the near touch in force, behind the size displayed there. Every print by the opposite aggressor at or through the limit takes from that queue first, then from the child, at the child's limit (`liquidity` `A`, on the child's venue). When the near touch moves away from the limit the algo re-pegs: a `replace` to the new touch, behind its displayed size, up to `maxreplaces` times, after which the child rests where it is. At expiry (the next child's send time, or `endtime`) what is left is a `cancel`, and rolls into the next child.
- **Cleanup**: if the last child leaves quantity, a final aggressive child is sent `2 * latencyms` before `endtime` for all of it, so the order always completes.

On the good preset above, 66 of 69 fills added liquidity; on the bad preset 29 of 31 removed it. Whether the passive order ends up cheaper depends on the day: a passive child chasing a rising market re-pegs and pays later, an aggressive one pays the spread now.

### Comparing good vs. bad execution
```q
q)good:simorder.run[ordcfgs`good;trades;quotes]
q)bad:simorder.run[ordcfgs`bad;trades;quotes]
q)select orderid,algo,arrivalprice,avgpx,bps:10000*(avgpx-arrivalprice)%arrivalprice from good[`orders],bad`orders
q)select n:count i by orderid,liquidity from good[`executions],bad`executions
q)select cancels:sum event=`cancel,replaces:sum event=`replace by orderid from good[`events],bad`events
```

### Arrival pacing

`arrival` models an implementation shortfall (arrival price) algo: it trades faster early to reduce timing risk, but never takes more than a set share of the market's volume.

- **Schedule** — the window is cut into `numfills` equal intervals, one child execution at the midpoint of each (as a slicing algo sends a child every interval).
- **Trajectory** — the share of the order still to trade at time share `t` of the window is the Almgren-Chriss solution `sinh(k(1-t))/sinh(k)`, with `k` = `urgency` (kappa x horizon). Each interval wants the drop in that curve. At urgency 1 half the order is done 44% of the way through the window, at 2 at 32%, at 3 at 23%; as urgency tends to 0 the order trades evenly over time. `simorder.trajectory[urgency;n]` returns the curve.
- **Participation cap** — an interval takes what it wants up to `maxpct` of its volume, measured as own / (own + market) against the interval's trades. What a capped interval could not take is carried into the next ones, so an algo that falls behind catches up when liquidity allows. Anything still left at the end goes into earlier intervals' unused capacity; only an order larger than the whole window can absorb under the cap exceeds it, every interval taking the excess in proportion to its capacity. `simorder.capped[want;cap]` does this step.

```q
q)arrcfg:ordcfg,`urgency`maxpct!(2f;0.2)
q)arrcfg[`pacing]:`arrival
q)arrresult:simorder.run[arrcfg;trades;quotes]
```

On one simulated NVDA day, with 30 intervals over an hour and urgency 2:

| Order, % of the window's volume | Half done at | Participation, first interval | Highest interval |
|---|---|---|---|
| 1% | 33% of the window | 1.6% | 1.6% |
| 5% | 33% | 7.4% | 7.4% |
| 15% | 33% | 19.4% | 19.4% |
| 20% | 37% | 20.0% | 20.0% |
| 30% (beyond the cap) | 47% | 23.1% | 23.1% |

The sizes are the children's targets; each child then executes against the tape as described under Execution. Market impact is the separate step below.

### Market impact

`simorder.impact[icfg;execs;trades;quotes]` moves one instrument's day of market data by the transient impact of child executions. Pass every order's executions in that instrument, not one order's: impact acts across orders, so it runs after all their schedules and sizes and before any of their prices.

- **Child impact** — each execution's impact, as a fraction of the price, is `eta × sigma × p^beta` under the `participation` model, where `sigma` is the day's volatility (`dailyvol`, from 5-minute mids) and `p` the child's participation, own / (own + market), in the market volume of an interval of the child's length centred on its time (`execs` column `interval`); or `eta × sigma × sqrt(own / daily volume)` under the `sqrtlaw` model, the square-root law on the child's size against the day's volume. In currency it is that fraction of the mid in force.
- **Shift** — the price shift in force at any time is the sum of every earlier execution's signed impact (a buy pushes up): a share `permanent` of each stays through the day, the rest halves every `halflife`. The sum is tapered linearly to zero over `taper` before `closetime` and rounded to whole cents (`shiftat`), so bid and ask move by the same tick, a quote is never locked or crossed, and nothing is left at the close. The close, and the next day that `di.simcalendar` starts from it, are unmoved, so the permanent share is permanent within the day.
- **Market** — quotes and prints move by the shift in force at their time (a print by the shift of the quote in force, so it keeps its place inside that quote), and a quote is added at each execution time carrying the moved level. Volumes, sizes and the order of events are unchanged; with `eta` 0 or no executions the market is returned as it is.
- **Prices** — run each order again against the moved market (`run[cfg;moved`trades;moved`quotes]`). Its aggressive fills then take the moved touch, its passive children rest on the moved touch, and its arrival price includes earlier orders' impact but not its own.

```q
q)icfg:`eta`beta`halflife`taper`closetime!(0.01;0.5;0D00:05;0D00:05;0D16:00)
q)execs:`time`side`qty`interval#arrresult`executions
q)moved:simorder.impact[icfg;execs;trades;quotes]
q)arrmoved:simorder.run[arrcfg;moved`trades;moved`quotes]
```

| Key | Description |
|---|---|
| `eta` | Impact coefficient, zero or positive; 0 turns impact off |
| `beta` | Participation exponent, positive (0.5 is the square-root law) |
| `halflife` | Timespan over which an execution's impact halves |
| `taper` | Timespan before `closetime` over which the shift falls linearly to zero |
| `closetime` | Time of day (timespan) of the close |
| `permanent` | Optional, default 0: share of each execution's impact that stays through the day |
| `model` | Optional, default `participation`: `participation` (p^beta) or `sqrtlaw` (sqrt of own over daily volume) |

### Many orders and multiple days

`generate` draws an order flow over every instrument and day in the market it is given, and `runmany` runs a table of order configs; `runflow` does both. `di.simcalendar`'s in-memory result serves as the market as it is, and so do the `trade` and `quote` tables of its database.

```q
q)cal:simcalendar.run[cfg;calendar;(::)]
q)flow:simorder.runflow[`norders`seed!(3;7);cal`trade;cal`quote]
q)select orderid,sym,side,orderqty,`date$starttime,algo,account,filledqty,avgpx,arrivalprice from flow`orders
q)select orders:count i,cancels:sum event=`cancel,replaces:sum event=`replace by account from flow`events lj 1!select orderid,account from flow`orders
```

The spec is a dictionary; any key left out takes its default:

| Key | Default | Meaning |
|---|---|---|
| `norders` | 5 | Orders per instrument and day |
| `accounts` | `` `ACC1`ACC2`ACC3 `` | Accounts drawn uniformly |
| `algos` | `` `VWAP`IS`AGGRESSIVE`PASSIVE `` | Algos drawn uniformly from the menu `algos`, which sets each one's pacing and aggression (and urgency and cap for `IS`) |
| `sizepct` | `0.005 0.05` | Order size as a share of the day's volume, uniform in the range, in round lots |
| `windowminutes` | `10 60` | Window length, uniform in the range; the window sits inside the session with five minutes clear of the open and the close, one child every 30 seconds |
| `seed` | `0N` | Seeds the draws and gives every order its own seed; `0N` leaves everything unseeded |
| `ticksize`, `jitter`, `latencyms`, `maxreplaces`, `capacity` | 0.01, 0.3, 2.0, 20, `A` | Passed to every order |

Orders on the same instrument and day do not interact: each runs against the market as given. For impact across them, run the flow, move the market with `impact` from all its executions on that instrument and day, and run the same configs again with `runmany` against the moved market.

## API

| Function | Description |
|----------|-------------|
| `simorder.run[cfg;trades;quotes]` | One order: returns a dict `orders`children`events`executions |
| `simorder.runmany[cfgs;trades;quotes]` | A table of order configs, each on its own instrument and day, gathered into the same four tables |
| `simorder.generate[spec;trades;quotes]` | An order flow over every instrument and day in the market, as a table of order configs |
| `simorder.runflow[spec;trades;quotes]` | `generate` then `runmany`; returns `configs and the four tables |
| `simorder.marketday[cfg;t;name]` | Rows of a trades or quotes table for the order's instrument and day, time-sorted; throws if none |
| `simorder.schedule[cfg]` | The exact child schedule |
| `simorder.jittered[cfg;times]` | The schedule moved by the seeded jitter |
| `simorder.sizing[cfg;trades;filltimes]` | The children's target quantities |
| `simorder.intervals[cfg;filltimes]` | The interval each child was sized against, one timespan per child |
| `simorder.trajectory[urgency;n]` | Arrival pacing: share of the order left at each of n+1 interval boundaries |
| `simorder.capped[want;cap]` | Arrival pacing: quantities per interval under a cap, shortfalls carried forward |
| `simorder.execute[cfg;trades;quotes]` | The children against the tape: returns `children`events`executions |
| `simorder.child[cfg;trades;quotes;spec]` | One child order (aggressive or passive) and what became of it |
| `simorder.aggressivefills[cfg;quotes;t;qty]` | The fills of an aggressive child sent at t |
| `simorder.passivefills[cfg;trades;quotes;t;expiry;qty]` | A passive child's fills, events, leaves and replaces |
| `simorder.quoteat[quotes;t]` | The quote in force at t |
| `simorder.buildorder[cfg;quotes;executions]` | The 1-row parent order table |
| `simorder.impact[icfg;execs;trades;quotes]` | Market impact: one instrument's day of quotes and prints moved by its executions' transient impact |
| `simorder.shiftat[icfg;times;moves]` | Market impact: the price shift in force at each time |
| `simorder.childimpact[icfg;execs;trades;sigma]` | Market impact: each execution's impact as a fraction of the price |
| `simorder.dailyvol[quotes]` | Market impact: the day's volatility from 5-minute mids |
| `simorder.validateimpact[icfg]` | Validate an impact configuration |
| `simorder.loadconfig[filepath]` | Load presets from CSV |
| `simorder.describe[]` | Return configuration schema as table |

## Presets

| Preset | Description |
|--------|-------------|
| `good` | Even pacing, one child in ten aggressive (patient, mostly resting at the touch), account ACC1, algo VWAP |
| `bad` | Frontloaded pacing, nine children in ten aggressive (rushed, crossing the spread), account ACC2, algo AGGRESSIVE |
| `arrival` | Arrival pacing at urgency 2 under a 20% participation cap, a third of the children aggressive, algo IS |

## Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `orderid` | Unique order identifier | `` `ORD001 `` |
| `account` | The account the order is for | `` `ACC1 `` |
| `algo` | The algorithm working the order, a label | `` `VWAP `` |
| `capacity` | `A` (agency) or `P` (principal), carried on the fills | `` `A `` |
| `sym` | Ticker symbol - must match the trades/quotes tables | `` `NVDA `` |
| `side` | `BUY` or `SELL` | `` `BUY `` |
| `orderqty` | Total order quantity | 10000 |
| `starttime` | Execution window start (timestamp, on the market data's date) | `2026.08.18D09:35:00.000000000` |
| `endtime` | Execution window end (timestamp, same day as `starttime`) | `2026.08.18D09:45:00.000000000` |
| `numfills` | Number of child orders to send | 20 |
| `pacing` | `even` (patient), `frontloaded` (rushed) or `arrival` (urgency trajectory under a participation cap) | `` `even `` |
| `spreadcapture` | Probability a child is aggressive (a marketable order crossing the spread) rather than passive (a limit at the near touch): 0=best, 1=worst | 0.1 |
| `jitter` | Random shift of each child's time as a share of half the gap to its neighbours; 0 = exact schedule | 0.3 |
| `latencyms` | Milliseconds from a child's send to its arrival at the market (half of it to its ack) | 2.0 |
| `maxreplaces` | Times a passive child re-pegs to the near touch when it moves away, before resting where it is | 20 |
| `ticksize` | Minimum price increment; fill prices sit on the tick or exactly at the midpoint | 0.01 |
| `seed` | Random seed (`0N` = no seed) for the jitter, the aggression and the venues | 1 |
| `urgency` | Arrival pacing only (required there): Almgren-Chriss urgency, kappa x horizon, positive; higher trades earlier | 2 |
| `maxpct` | Arrival pacing only (required there): participation cap per interval, own / (own + market), between 0 and 1 | 0.2 |

`urgency` and `maxpct` are the last two columns of `presets.csv`; leave them empty for `even` and `frontloaded`.

## Testing

```bash
make test-simorder
```

or from a q session:

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simorder
```

### Test Coverage

| Group | Tests | Description |
|-------|-------|-------------|
| Validation | 15 | Bad configs throw correct errors (starttime>=endtime, zero orderqty/numfills, invalid side/pacing/capacity, spreadcapture, jitter, latency out of range, zero ticksize, window on a day or symbol the market data does not cover, window spanning two days, start before the first quote) |
| Schedule | 10 | Correct count, sorted, within window, frontloaded gaps widen over time; jitter moves children off the schedule, keeps their order and the window, within its bound, and is exact at 0 |
| Sizing | 7 | Exact quantity conservation (even and frontloaded), minimum size respected, frontloaded concentrates quantity early |
| Arrival pacing | 18 | Missing or out-of-range urgency and maxpct throw; trajectory endpoints, shape, sinh(1)/sinh(2) at mid-window, urgency ordering, even at vanishing urgency; cap carry-forward, backfill and excess beyond capacity; schedule count and window; exact quantity conservation; participation per interval within maxpct for an order of 15% of the window's volume |
| Market impact | 31 | Missing keys, zero halflife, negative eta, permanent above 1 and an unknown model throw; the optional keys default; with a permanent share the move stays in full at its time, keeps its permanent half after one and two halflives and still vanishes at the close; the square-root law gives eta x sigma x sqrt(own / daily volume) and moves the market without locking a quote; shift in force at its own time, halved after one halflife, quartered after two, gone at the close, halved by the taper five minutes before it; positive daily volatility and child impact; one quote added per execution time, no locked or crossed quote, prints inside the moved quotes, volumes unchanged, a buy moves the quote up, aggressive fills against the moved market at its ask or one tick beyond, eta 0 leaves the market as it is |
| Execution | 41 | Result shape; the parent order's columns, arrival price at the mid, filled in full, avgpx; the children's columns, numbering, order types and limits, lit venues, statuses; the executions' columns, quantity conservation, order, window, half-tick grid, liquidity flags, capacity, fills per child; aggressive fills at the ask in force or one tick beyond, passive fills at the child's limit in force and on its venue |
| Events | 14 | Columns, event kinds, order; one new and one ack per child, replaces matching the children, fill events matching the executions, a done per filled child and a cancel per cancelled one, nothing left at a done, ack before the first fill |
| Aggression | 13 | spreadcapture 1: all children marketable, all fills removing liquidity, no replace or cancel; spreadcapture 0: scheduled children all limit orders adding liquidity; about spreadcapture of 400 children aggressive; SELL aggressive fills at the bid or one tick below and filled in full; frontloaded and arrival orders filled in full, frontloaded intervals tiling the window |
| Rollover | 6 | A large passive order on the least liquid preset: cancels at expiry, a marketable cleanup child, the order still filled in full, cancels carrying the unfilled quantity, the cleanup carrying what the scheduled children left |
| Config | 4 | Presets load; columns in any order load identically, a missing or unknown column throws |
| Mixed market | 2 | An order against tables holding two instruments matches the single-instrument run; marketday returns the order's instrument and day only |
| Order flow | 30 | generate: norders per instrument and day, the schema's keys, windows inside the sessions and within a day, round-lot sizes, sides, accounts and algos from the menu with IS the arrival algo, a seed per order, the same flow from the same seed and none without; runmany: the four tables, every order filled for its quantity, unique execution ids, fills on their order's instrument and day; runflow returns the configs and the same orders |
| Reproducibility | 1 | Same inputs produce identical output |
| **Total** | **173** | |

The fixture is one simulated day from `di.simtick`'s `nvda_default` preset (and `pg_default` for the rollover tests); order windows are set on that day's date.

## Project Structure

```
di/simorder/
├── init.q           # Module code
├── presets.csv      # Order presets (good / bad / arrival)
├── test.csv         # Unit tests (k4unit format)
├── testing.q        # Manual test script
├── notebooks/       # TCA parquet export notebook
└── README.md        # This file
```

## License

MIT
