# di.simbasket

Multi-instrument correlated tick simulation over a trading calendar.

> **Status: Work in Progress** — This module is not yet implemented. This README describes the intended design.

## About

`di.simbasket` extends `di.simcalendar` to simulate a **portfolio of correlated instruments** over multiple trading days. Each instrument follows its own calibrated price process, with cross-instrument correlations driven by a **factor model**.

## Module Hierarchy

```
simtick ← simcalendar ← simbasket
```

`simbasket` sits at the top of the stack. It orchestrates `simcalendar` for each instrument and introduces correlation across instruments at the price path level.

## Correlation Approach

### Why not a full correlation matrix?

For a portfolio of N instruments, a full N×N correlation matrix requires N²/2 parameters to estimate and maintain. For 200 stocks this means 20,000 parameters — difficult to estimate reliably, hard to keep positive semi-definite, and economically meaningless (it treats every pair of stocks as independent observations with no underlying structure).

### Factor model

Instead, `simbasket` uses a **factor model**. Each instrument's return is decomposed into:

```
return(i) = beta(i,1)*F1 + beta(i,2)*F2 + ... + beta(i,k)*Fk + epsilon(i)
```

Where:
- `F1..Fk` — small number of common factors (e.g. market, sector, size)
- `beta(i,k)` — each instrument's sensitivity to each factor
- `epsilon(i)` — idiosyncratic residual, independent per instrument

For 200 stocks this reduces the problem to:
- A **k×k factor correlation matrix** (e.g. 5×5) — tiny and easy to keep PSD
- A **N×k beta matrix** — factor loadings per instrument
- **N idiosyncratic vols** — one per instrument

Correlation between any two instruments is fully determined by their shared factor exposures, which reflects economic reality — two stocks in the same sector move together because they share the same sector factor. PSD is guaranteed by construction since the covariance matrix is expressed as `B * F * B' + D` where F is the factor covariance and D is diagonal (idiosyncratic), and the sum of two PSD matrices is always PSD.

This is the same approach used by industry-standard risk models (Barra, Axioma).

## Intended API

```q
simbasket:use`di.simbasket

/ Load per-instrument configs (one row per symbol)
cfgs:simbasket.loadconfigs`:di/simbasket/basket.csv

/ Load factor model inputs
factors:simbasket.loadfactors`:di/simbasket/factors.csv
betas:simbasket.loadbetas`:di/simbasket/betas.csv

/ Load trading calendar
calendar:simcalendar.loadcalendar`:di/simcalendar/calendar.csv

/ Run simulation (in-memory)
trades:simbasket.run[cfgs;factors;betas;calendar;(::)]

/ Run with disk persistence
simbasket.run[cfgs;factors;betas;calendar;`:/tmp/mydb]
```

Output is a standard date-partitioned kdb+ trade table with multiple syms:

```q
q)select count i by sym from trade where date=2026.01.20
sym  | x
-----| -----
AAPL | 58432
MSFT | 61204
NVDA | 60871
...
```

## License

MIT
