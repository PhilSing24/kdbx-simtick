\c 50 200
.Q.m.SP:enlist"/home/philippe/kdbx-modules"
simtick:use`di.simtick

/ Load base config and modify for pure Poisson + no seasonality
cfgs:simtick.loadconfig`:di/simtick/presets.csv
cfg:cfgs`default

/ Pure Poisson: disable Hawkes excitation
cfg[`alpha]:0.0
cfg[`beta]:1.0  / must be > alpha, but irrelevant when alpha=0

/ No intraday seasonality: equal multipliers
cfg[`openmult]:1.0
cfg[`midmult]:1.0
cfg[`closemult]:1.0

/ Set a seed for reproducibility (optional)
cfg[`seed]:42

/ Three consecutive trading days (Mon, Tue, Wed example)
tradingdays:2026.01.19 2026.01.20 2026.01.21

/ Calculate calendar days between each trading day
/ e.g., Mon->Tue = 1, Fri->Mon = 3
calendardays:1_deltas tradingdays

/ ============================================================
/ OVERNIGHT GAP MODEL
/ ============================================================

/ Overnight return based on calendar days elapsed
/ More days = more variance accumulated
/ Returns multiplicative factor for next day's start price
overnightgap:{[closeprice;ndays;vol;tradingdaysyear]
  / ndays: calendar days between close and next open
  / vol: annualized volatility
  / Overnight variance scales with calendar time
  dt:ndays%tradingdaysyear;
  eps:first .z.m.rng.boxmuller[1];
  / Log-normal return: no drift overnight, just diffusion
  closeprice * exp[neg 0.5*vol*vol*dt] * exp[vol*sqrt[dt]*eps]
  }