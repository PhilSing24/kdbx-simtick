# kdbx-simtick

Realistic intraday tick data simulator for KDB-X with configurable market microstructure.

## Rationale

Realistic synthetic tick data is valuable for many quantitative finance workflows. This module generates trade and quote data that captures key statistical properties of real markets:

- **Trade clustering** — real trades arrive in bursts, not uniformly. We use a Hawkes process to model this self-exciting behavior.
- **Intraday seasonality** — trading activity is high at open and close, low at midday. Configurable U-shape or J-shape patterns.
- **Price dynamics** — GBM with optional jump-diffusion captures continuous price movement and occasional discontinuities.
- **Microstructure** — bid-ask spreads that widen at open/close, quote updates between trades.

### Use Cases

**Stress testing and scenario analysis** — Generate data under severe but plausible conditions. Simulate liquidity shocks by lowering `baseintensity`, gap moves using the jump-diffusion model (`pricemodel:jump`), or extreme volatility regimes by increasing `vol`. Test how your systems behave when markets break from normal patterns.

**Sensitivity and robustness testing** — Vary parameters systematically to understand how strategies respond to changes in volatility, trade frequency, or spread dynamics. Identify breaking points before they occur in production.

**System development** — Stress-test data ingestion pipelines by adjusting trade arrival rates. Increase `baseintensity` (e.g., from 0.5 to 50) and `alpha` to simulate high-frequency bursts. This lets you verify that your database, message queues, and processing logic handle peak loads without data loss or latency spikes.

**Real-time demos** — Feed simulated data to dashboards, visualization tools, or trading interfaces. Useful for demos, training sessions, or testing UI responsiveness without connecting to live markets.

### Limitations

This module emphasizes **trade generation** and derives quotes in a simplified manner. Quotes are constructed *after* trades to ensure consistency with executed prices. This approach is computationally efficient but inverts the true market causality where quotes exist first and trades result from order matching.

**Not suitable for:**

- **Advanced Market-making research** — no order book queue dynamics, no queue position modeling
- **Execution optimization** — no realistic fill probability or market impact simulation
- **HFT strategy development** — quote generation is not causally realistic

For these advanced use cases, a full limit order book simulator with queue dynamics would be preferred.

### Next Steps

A future module will extend this simulator to support **multi-instrument generation with correlation**. Using KDB-X module hierarchy, a new `di.simmulti` module will build on `di.simtick` as the single-instrument foundation, adding:

- Correlated processes
- Configurable correlation matrices
- Synchronized or independent arrival processes

Correlated price paths across assets are essential for:

- **Portfolio risk management** — stress testing diversified portfolios under correlated drawdowns
- **Value at Risk (VaR) and Expected Shortfall (ES)** — generating scenarios for tail risk estimation
- **Cross-asset strategy testing** — pairs trading, statistical arbitrage, index replication

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
q)cfg:cfgs`default
q)simtick.run[cfg]
time                          price    qty
------------------------------------------
2026.01.20D09:30:02.487640474 100      43 
2026.01.20D09:30:03.846514899 100.0011 32 
2026.01.20D09:30:04.444929571 100.0122 78 
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

| Preset | Description |
|--------|-------------|
| `default` | Standard trading day |
| `liquid` | High volume, tighter spreads |
| `illiquid` | Low volume |
| `volatile` | Higher price volatility |
| `jumpy` | Jump-diffusion price model |

## Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `baseintensity` | Base arrival rate (trades/sec) | 0.5 |
| `alpha` | Hawkes excitation | 0.3 |
| `beta` | Hawkes decay (must be > alpha) | 1.0 |
| `vol` | Annualized volatility | 0.2 |
| `drift` | Annualized drift | 0.05 |
| `transitionpoint` | Intraday shape (0.3=J, 0.5=U) | 0.3 |
| `pricemodel` | `gbm` or `jump` | `gbm` |
| `qtymodel` | `lognormal` or `constant` | `lognormal` |
| `avgqty` | Average trade size | 100 |
| `basespread` | Base bid-ask spread (fraction) | 0.001 |
| `generatequotes` | Generate quotes flag | 0b |

## Testing
```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.simtick
```

### Test Coverage

| Group | Tests | Description |
|-------|-------|-------------|
| Validation | 3 | Bad configs throw correct errors (alpha >= beta, negative intensity, zero multipliers) |
| Arrivals | 5 | Output properties: non-empty, sorted, positive, within duration, correct type |
| Shape | 3 | Intraday pattern: open > mid, close > mid, J-shape verification |
| Price | 6 | Positive prices, startprice correct, realized vol within tolerance, jump model works |
| Trades | 8 | Correct schema, sorted times, positive prices/qty, integer qty, within session |
| Quotes | 8 | Correct schema, sorted times, bid < ask, positive sizes, quote before first trade |
| Config | 7 | Keyed table, correct column count, correct types (float, symbol, date) |
| Describe | 3 | Returns table, correct columns, correct parameter count |
| Constant Qty | 2 | All quantities equal, quantity equals avgqty |
| Reproducibility | 1 | Same seed produces same output |
| **Total** | **46** | |

## Documentation

The `documentation/` folder contains **Intraday Tick Simulator: Technical Documentation**, a paper detailing the mathematical foundations of this module including:

- Hawkes process theory and Ogata thinning algorithm
- Geometric Brownian Motion and Merton jump-diffusion
- Quote generation methodology
- Implementation details

## Project Structure
```
di/
  simtick/
    init.q              # Module code
    test.csv            # Unit tests (k4unit format)
    presets.csv         # Market scenario presets
    README.md           # This file
    documentation/
      tick_simulator_paper.pdf   # Mathematical foundations
```

## License

MIT
