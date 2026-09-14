# di.simorder

Order execution simulator for TCA (Transaction Cost Analysis) demos with KDB-X. Generates a parent order and its child executions against an existing `di.simtick` trades/quotes market, with configurable execution quality.

## About

A TCA demo needs more than realistic market data — it needs a realistic *order* trading against that market, so cost metrics (VWAP slippage, implementation shortfall, effective spread) have something to measure. `di.simorder` takes the `trades`/`quotes` output of `di.simtick` (or `di.simcalendar`) for a given day and simulates an algo working a parent order into a series of child executions.

The module is designed around a single core idea: **execution quality is a config choice, not a random outcome**. The same order, run twice with different parameters against the *same* underlying market, produces two different, explainable cost outcomes — which is exactly the comparison a TCA demo needs to show.

- **Good execution**: patient timing (`even` pacing), fills close to the mid (low `spreadcapture`)
- **Bad execution**: rushed timing (`frontloaded` pacing, both in timestamp and in quantity), fills that cross toward the far touch (high `spreadcapture`)
- **Arrival (implementation shortfall) algo**: `arrival` pacing, an Almgren-Chriss trajectory front-loaded by `urgency`, with the order's share of each interval's volume capped at `maxpct`

### Key Features

- **Configurable pacing** — `even` (uniformly spaced, patient), `frontloaded` (rushed, concentrated early — in both timing *and* quantity; half the order fills in the first 1% of the window, so use it as a deliberately bad contrast, not as an algo) or `arrival` (an implementation-shortfall schedule under a participation cap, see [Arrival pacing](#arrival-pacing))
- **Volume-aware sizing** — under `even` pacing, child execution sizes are weighted by real market volume in each time bucket (pulled from `trades`), not a naive flat split
- **Spread-aware pricing** — each execution is priced relative to the prevailing bid/ask (from `quotes`) at its timestamp, placed between mid and the far touch according to `spreadcapture`
- **Exact quantity conservation** — child execution quantities always sum exactly to the parent order's `orderqty`, regardless of rounding or minimum-size flooring
- **Arrival price benchmark** — the parent order table carries the mid price at `starttime`, ready for implementation-shortfall calculations

### Market Focus

Built to sit directly on top of `di.simtick`'s NVDA/NASDAQ presets — an order's `sym` should match a symbol present in the `trades`/`quotes` tables it's run against, and `starttime`/`endtime` should fall within that day's trading session.

### Use Cases

**TCA demos** — the primary use case. Run the same order twice (good vs. bad presets) against one day of simulated market data, then compare VWAP slippage and implementation shortfall between the two using any downstream SQL or analytics engine.

**Algo behavior comparison** — vary `pacing`/`spreadcapture` independently to isolate the cost contribution of *timing* urgency vs. *aggression* (spread crossing), rather than conflating the two.

**Pipeline/schema testing** — generates a small, realistic `orders`/`executions` pair of tables to validate downstream ingestion (e.g. Parquet export, database loading) alongside `di.simtick`'s `trades`/`quotes`.

### Limitations

This module models execution **outcome**, not execution **mechanics**. It does not simulate:

- **Market impact** — an order's own executions never move the simulated market's price path; the market in `trades`/`quotes` is generated independently and is unaffected by the order trading against it
- **Multi-venue routing** — all executions are implicitly single-venue; there's no NBBO, no smart order routing, no venue-level price improvement modeling
- **Order book mechanics** — no queue position, no partial-fill-at-a-price-level dynamics; pricing is a direct function of `spreadcapture` against the prevailing quote, not a matching-engine simulation
- **Multiple concurrent orders** — one order at a time; no portfolio-level or cross-order interaction
- **Tape inclusion** — `trades` represents the market independent of this order; an order's own executions are not folded back into `trades`. This matches the standard "exclusive VWAP" TCA convention (benchmarking against the market rather than partly against yourself), but means anyone wanting an "inclusive" benchmark needs to union `trades` and `executions` themselves downstream.

For these, a proper limit order book simulator (see `di.simbook`) or a multi-venue market model would be needed.

### Next Steps

`di.simorder` currently runs against a single day's `trades`/`quotes` (from `di.simtick`). The natural extension is wiring it into `di.simcalendar`'s per-day loop, so an order can be replicated across multiple trading days — giving a second axis of comparison (same execution style, different market days) alongside the existing good-vs-bad comparison.

```
di/
├── simtick/      # 1 instrument, 1 day (atomic market data unit)
├── simcalendar/  # 1 instrument, N days (uses di.simtick)
└── simorder/     # 1 order, 1 day (uses di.simtick's trades/quotes output)
```

**Note:** as with the other `di.*` modules, this uses absolute module paths (`use`di.simtick`) rather than relative sibling references, following the same convention noted in `di.simtick`'s README.

---

### Configuration

Simulations are driven by a configuration dictionary. Rather than building one manually every time, the module reads configurations from a **CSV file** via `loadconfig`, following the same pattern as `di.simtick`.

```q
q)cfgs:simorder.loadconfig`:di/simorder/presets.csv
q)cfg:cfgs`good
```

To see all available parameters and their descriptions:
```q
q)simorder.describe[]
```

## Overview

A KDB-X module for simulating a parent order and its child executions against existing market data. Features:

- **Config-driven execution style** (pacing + spread capture) for good/bad execution comparisons
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
q)tickcfg:cfgs`nvda_default
q)tickcfg[`generatequotes]:1b
q)result:simtick.run[tickcfg]
q)trades:result`trade
q)quotes:result`quote

q)ordcfg:`orderid`sym`side`orderqty`starttime`endtime`numfills`pacing`spreadcapture`seed!
  (`ORD001;`NVDA;`BUY;10000;
   2026.01.20D09:35:00.000000000;2026.01.20D09:45:00.000000000;
   20;`even;0.1;1)
q)ordresult:simorder.run[ordcfg;trades;quotes]
q)ordresult`order
orderid sym  side orderqty starttime                     endtime                       arrivalprice
---------------------------------------------------------------------------------------------------
ORD001  NVDA BUY  10000    2026.01.20D09:35:00.000000000 2026.01.20D09:45:00.000000000 181.125

q)ordresult`executions
orderid execid sym  side time                          price  qty
-----------------------------------------------------------------
ORD001  1      NVDA BUY  2026.01.20D09:35:28.571428571 181.07 587
ORD001  2      NVDA BUY  2026.01.20D09:35:57.142857143 181.17 717
...
```

### Comparing good vs. bad execution
```q
q)badcfg:ordcfg;
q)badcfg[`pacing]:`frontloaded;
q)badcfg[`spreadcapture]:0.9;
q)badresult:simorder.run[badcfg;trades;quotes]

q)goodvwap:{[e](sum e[`price]*e[`qty])%sum e`qty}ordresult`executions
q)badvwap:{[e](sum e[`price]*e[`qty])%sum e`qty}badresult`executions
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

Prices are unchanged: each child is priced against the prevailing quote by `spreadcapture`, and the order still has no market impact (see Limitations).

## API

| Function | Description |
|----------|-------------|
| `simorder.run[cfg;trades;quotes]` | Full simulation - returns dict with `order`/`executions` |
| `simorder.schedule[cfg]` | Generate child execution timestamps only |
| `simorder.sizing[cfg;trades;filltimes]` | Generate child execution quantities only |
| `simorder.trajectory[urgency;n]` | Arrival pacing: share of the order left at each of n+1 interval boundaries |
| `simorder.capped[want;cap]` | Arrival pacing: quantities per interval under a cap, shortfalls carried forward |
| `simorder.pricing[cfg;quotes;filltimes]` | Generate child execution prices only |
| `simorder.buildorder[cfg;quotes]` | Build the 1-row parent order table only |
| `simorder.buildexecutions[cfg;trades;quotes]` | Build the child executions table only |
| `simorder.loadconfig[filepath]` | Load presets from CSV |
| `simorder.describe[]` | Return configuration schema as table |

## Presets

Presets should be calibrated as good/bad execution style pairs, matched against a `di.simtick` symbol/day:

| Preset | Description |
|--------|-------------|
| `good` | Even pacing, tight spread capture (patient, low-impact) |
| `bad` | Frontloaded pacing, wide spread capture (rushed, high-impact) |
| `arrival` | Arrival pacing at urgency 2 under a 20% participation cap, moderate spread capture |

## Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `orderid` | Unique order identifier | `` `ORD001 `` |
| `sym` | Ticker symbol - must match the trades/quotes tables | `` `NVDA `` |
| `side` | `BUY` or `SELL` | `` `BUY `` |
| `orderqty` | Total order quantity | 10000 |
| `starttime` | Execution window start (timestamp) | `2026.01.20D09:35:00.000000000` |
| `endtime` | Execution window end (timestamp) | `2026.01.20D09:45:00.000000000` |
| `numfills` | Number of child executions to generate | 20 |
| `pacing` | `even` (patient), `frontloaded` (rushed) or `arrival` (urgency trajectory under a participation cap) | `` `even `` |
| `spreadcapture` | 0=fills at mid (best), 1=fills at far touch (worst) | 0.1 |
| `seed` | Random seed (`0N` = no seed) | 1 |
| `urgency` | Arrival pacing only (required there): Almgren-Chriss urgency, kappa x horizon, positive; higher trades earlier | 2 |
| `maxpct` | Arrival pacing only (required there): participation cap per interval, own / (own + market), between 0 and 1 | 0.2 |

`urgency` and `maxpct` are the last two columns of `presets.csv`; leave them empty for `even` and `frontloaded`.

## Testing

```q
q)k4unit:use`local.k4unit
q)k4unit.moduletest`di.simorder
```

### Test Coverage

| Group | Tests | Description |
|-------|-------|--------------|
| Validation | 7 | Bad configs throw correct errors (starttime>=endtime, zero orderqty/numfills, invalid side/pacing, spreadcapture out of range) |
| Schedule | 5 | Output properties: correct count, sorted, within window, frontloaded gaps widen over time |
| Sizing | 7 | Exact quantity conservation (even and frontloaded), minimum size respected, frontloaded concentrates quantity early |
| Arrival pacing | 18 | Missing or out-of-range urgency and maxpct throw; trajectory endpoints, shape, sinh(1)/sinh(2) at mid-window, urgency ordering, even at vanishing urgency; cap carry-forward, backfill and excess beyond capacity; schedule count and window; exact quantity conservation; participation per interval within maxpct for an order of 15% of the window's volume |
| Pricing | 5 | Positive prices, BUY far-touch priced above mid, SELL far-touch priced below mid |
| Order | 4 | Correct schema, single row, positive arrival price |
| Executions/Run | 12 | Dict shape, correct schema, exact quantity conservation end-to-end (even, frontloaded, arrival), time bounds, sorted, positive price/qty |
| Reproducibility | 1 | Same inputs produce identical output |
| **Total** | **55** | |

The fixture is one simulated day from `di.simtick`'s `nvda_default` preset; order windows are set on that day's date.

## Project Structure

```
di/simorder/
├── init.q      # Module code
├── test.csv    # Unit tests (k4unit format)
└── README.md   # This file
```

## License

MIT
