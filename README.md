# kdbx-simtick

Intraday tick data simulator for KDB-X using Hawkes process and GBM.

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
export QPATH=$QPATH:/path/to/kdbx-simtick
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

## Testing

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.simtick
```

## Project Structure

```
di/
  k4unit.q           # Test framework
  simtick/
    init.q           # Module code
    test.csv         # Unit tests
    presets.csv      # Market scenario presets
```

## License

MIT
