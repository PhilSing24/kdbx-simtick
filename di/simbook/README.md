# di.simbook

L2 Order Book Simulator using the Gillespie algorithm.

## About

This module simulates a limit order book from the **bottom up**: individual order flow events (limit arrivals, cancellations, market orders) drive the book state, and prices/quotes emerge from it.

This is fundamentally different from `di.simtick`, which takes a **top-down** approach (GBM price process → derive quotes from trades). Both are valid — they serve different purposes.

Based on: Cont, Stoikov & Talreja (2010) — *"A stochastic model for order book dynamics"*

## Status

**Work in progress.** 

- [x] Book state (two price→size dictionaries)
- [x] Rate computation (Poisson arrival/cancellation rates with exponential decay)
- [x] Gillespie event selection (time-to-next-event + weighted draw)
- [x] Event application (limit arrivals, cancellations, market orders)
- [x] Book shifting when BBO is depleted
- [ ] Main simulation loop with event log accumulation
- [ ] L2 snapshot derivation from event log
- [ ] Trade/BBO derivation from event log
- [ ] Seed management
- [ ] Intraday volume profile
- [ ] Multi-sym support
- [ ] Integration with simcalendar

## Installation

```
di/
├── simtick/
├── simcalendar/
└── simbook/
    ├── init.q
    └── README.md
```

## Quick Start

```q
q)simbook:use`di.simbook

/ Initialize a 5-level book with mid at 100.00
q)book:simbook.initbook[100.0;0.01;5]

/ Load default parameters
q)params:simbook.defaultparams[]

/ Compute event rates
q)rates:simbook.computeRates[book;params]

/ One Gillespie step: returns (time_delta; event_index)
q)simbook.gillespie[rates]

/ Apply an event to the book
q)book:simbook.applyEvent[book;params;7]
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `lambda`  | Limit order arrival base rate | 1.5 |
| `kappa`   | Arrival decay away from BBO (exponential) | 0.5 |
| `theta`   | Cancellation rate per unit of resting size | 0.6 |
| `mu`      | Market order arrival rate per side | 0.3 |
| `lotsz`   | Lot size for arrivals | 100 |

## Event Model

Three event types, each as independent Poisson processes:

1. **Limit order arrival** at level δ from mid: rate = λ · e^(-κδ)
2. **Cancellation** at level δ: rate = θ · q(δ), where q(δ) is queue depth
3. **Market order** (buy/sell): rate = μ per side

Event selection uses the Gillespie algorithm (continuous-time Markov chain simulation).

## Limitations (current)

- L1 quotes in simtick are derived from trades (acknowledged simplification)
- No queue-reactive dynamics (rates don't depend on book state beyond queue depth)
- No Hawkes/self-exciting order arrival clustering
- No informed vs uninformed trader distinction
- Fixed tick grid (no gaps in price levels)

## License

MIT
