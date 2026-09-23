/ di.simtick - realistic intraday tick simulator

/ time unit conversions
nsperms:1000000
nspersec:1000000000


val.haskeys:{[cfg;reqkeys;fn]
  / check config dictionary has all required keys
  / cfg: configuration dictionary
  / reqkeys: symbol list of required keys
  / fn: function name string for error context
  if[count missing:reqkeys where not reqkeys in key cfg;
    '"(",fn,"): missing config keys - ",", " sv string missing];
  };

val.nonempty:{[x;name;fn]
  / check list is non-empty
  / x: list to check
  / name: parameter name for error message
  / fn: function name string for error context
  if[not count x; '"(",fn,"): ",name," cannot be empty"];
  };

val.hascols:{[t;reqcols;fn]
  / check table has required columns
  / t: table to check
  / reqcols: symbol list of required columns
  / fn: function name string for error context
  if[not all reqcols in cols t;
    '"(",fn,"): table missing columns - ",", " sv string reqcols where not reqcols in cols t];
  };


rng.boxmuller:{[n]
  / Box-Muller transform for n standard normal random variates
  / n: number of samples required
  / returns: list of n standard normal floats
  m:2*(n+1) div 2;  / ensure even count
  u:m?1.0;
  u:2 0N#u;
  r:sqrt -2f*log u 0;
  theta:2f*acos[-1]*u 1;
  n#(r*cos theta),r*sin theta
  };

rng.normal:{[n;cfg]
  / generate n standard normal random samples
  / n: number of samples required
  / cfg: config dict containing `rngmodel
  / returns: list of n standard normal floats
  model:cfg`rngmodel;
  $[model=`pseudo; .z.m.rng.boxmuller[n];
    '"rng.normal: unknown rngmodel - ",string model]
  };


rng.poisson:{[lams;maxk]
  / Poisson variates with element-wise means, by inversion truncated at maxk
  / lams: list of means, non-negative
  / maxk: largest value returned; choose it so that P(X>maxk) is negligible
  /   for the means in use (12 covers means up to about 3)
  / returns: list of longs
  / X is the number of k from 0 up with P(X<=k) below the uniform
  u:(count lams)?1.0;
  term:exp neg lams;
  cdf:term;
  k:`long$u>cdf;
  m:1;
  while[m<=maxk; term*:lams%m; cdf+:term; k+:u>cdf; m+:1];
  k
  };

shape:{[cfg;progress]
  / intraday intensity multiplier using cosine interpolation
  / cfg: config dict with `openmult`midmult`closemult`transitionpoint
  / progress: fraction of trading day elapsed (0 to 1)
  / returns: intensity multiplier for current time
  /
  / transitionpoint controls when to switch from open->mid to mid->close
  / 0.5 = symmetric (U-shape), 0.3 = asymmetric (J-shape)
  / progress may be an atom or a list; the multiplier never exceeds the
  / largest of the three, which arrivals relies on
  openmult:cfg`openmult;
  midmult:cfg`midmult;
  closemult:cfg`closemult;
  tp:cfg`transitionpoint;
  early:progress<tp;
  earlyvals:midmult+(openmult-midmult)*cos progress*acos[-1]%(2*tp);
  latevals:midmult+(closemult-midmult)*sin (progress-tp)*acos[-1]%(2*1-tp);
  ?[early;earlyvals;latevals]
  };

poisson:{[rate;duration]
  / event times of a homogeneous Poisson process on [0;duration)
  / rate: events per unit time, positive
  / duration: length of the interval, non-negative
  / returns: ascending float times; their count is Poisson(rate*duration)
  /
  / exponential waits are drawn in blocks of about the expected count plus
  / four standard deviations, until the cumulative time passes duration.
  / 1-u keeps the uniform away from 0, so no wait is infinite
  m:1+`long$(rate*duration)+4*sqrt rate*duration;
  t:sums neg log[1-m?1.0]%rate;
  while[duration>last t; t,:last[t]+sums neg log[1-m?1.0]%rate];
  t where t<duration
  };

hawkes.children:{[params;parents]
  / one generation of offspring in a Hawkes process with exponential kernel
  / alpha*exp(-beta*t): each parent has Poisson(alpha/beta) children, each
  / at an Exp(beta) delay after its parent. Their total is then
  / Poisson(count[parents]*alpha/beta) with each child picking its parent
  / uniformly, which has the same law and is a vector operation
  / params: dict with `alpha`beta`duration
  / parents: event times in seconds
  / returns: ascending child times below duration
  n:count parents;
  if[0=n; :`float$()];
  k:count .z.m.poisson[1f;n*params[`alpha]%params`beta];
  t:parents[k?n]+neg log[1-k?1.0]%params`beta;
  asc t where t<params`duration
  };

hawkes.process:{[cfg;baseintensity;extra]
  / a Hawkes process with exponential kernel on the session, simulated
  / through its cluster representation (Hawkes and Oakes, 1974): immigrants
  / arrive as an inhomogeneous Poisson process of intensity
  / baseintensity*shape(t), plus any extra immigrants given, and every event
  / spawns Poisson(alpha/beta) children at Exp(beta) delays, generation after
  / generation until a generation is empty. The union of all generations is
  / the process
  / cfg: config dict with `alpha`beta`openingtime`closingtime and the shape keys
  / baseintensity: immigrant intensity before the intraday shape (per second)
  / extra: extra immigrant times in seconds from open (a shock, see hawkes.shock)
  / returns: ascending event times in seconds from session start
  /
  / This is exact: unlike Ogata thinning it needs no upper bound on the
  / intensity, so bursts are never capped (a fixed bound under-produced
  / arrivals by 5% at branching ratio 0.4 and by 3x at 0.9), and each
  / generation is a vector operation rather than a scan over candidates
  open:`timespan$cfg`openingtime;
  close:`timespan$cfg`closingtime;
  if[open>=close; '"arrivals: openingtime must be before closingtime"];
  duration:(close-open)%nspersec;

  / immigrants: a homogeneous Poisson process at the day's peak baseline,
  / thinned by shape/maxmult (exact, since shape never exceeds maxmult)
  maxmult:cfg[`openmult]|cfg[`midmult]|cfg`closemult;
  cand:.z.m.poisson[baseintensity*maxmult;duration];
  immigrants:cand where (count[cand]?1.0)<.z.m.shape[cfg;cand%duration]%maxmult;
  immigrants:asc immigrants,extra where extra<duration;

  / offspring, generation by generation, until a generation is empty
  params:`alpha`beta`duration!(cfg`alpha;cfg`beta;duration);
  generations:.z.m.hawkes.children[params]\[{0<count x};immigrants];
  asc `float$raze generations
  };

hawkes.shock:{[cfg;jumptimes;n]
  / extra immigrants seeded by price jumps: n after each jump, at exponential
  / delays of mean jumpburstminutes; each then seeds its usual cascade, so a
  / jump brings a burst of activity that fades over minutes
  / cfg: config dict with `jumpburstminutes
  / jumptimes: jump times in seconds from open
  / n: immigrants per jump
  / returns: ascending times in seconds from open
  if[(0=count jumptimes) or 0=n; :`float$()];
  parents:jumptimes where (count jumptimes)#n;
  asc parents+neg log[1-(count parents)?1.0]*60*cfg`jumpburstminutes
  };

arrivals:{[cfg]
  / generate trade arrival times using a Hawkes process with exponential
  / kernel at the config's baseintensity (see hawkes.process)
  / cfg: configuration dictionary
  / returns: ascending list of arrival times in seconds from session start
  /
  / Required config keys:
  /   baseintensity, alpha, beta, openingtime, closingtime,
  /   openmult, midmult, closemult, transitionpoint
  reqkeys:`baseintensity`alpha`beta`openingtime`closingtime;
  reqkeys,:`openmult`midmult`closemult`transitionpoint;
  .z.m.val.haskeys[cfg;reqkeys;"arrivals"];
  .z.m.hawkes.process[cfg;cfg`baseintensity;`float$()]
  };

gbm:{[s;r;eps;t]
  / GBM single-step return factor
  / s: annualized volatility (sigma)
  / r: annualized drift (mu)
  / eps: standard normal random variate
  / t: time step in years
  / returns: multiplicative return factor exp((r - 0.5*s^2)*t + s*sqrt(t)*eps)
  exp (t*r-.5*s*s)+eps*s*sqrt t
  };

diffusion:{[cfg;dts]
  / geometric Brownian motion factors per step
  / cfg: config dict with `vol`drift`rngmodel
  / dts: list of time steps in years (a first step of 0 leaves the first
  /   point at the start price)
  / returns: multiplicative factor per step
  eps:.z.m.rng.normal[count dts;cfg];
  .z.m.gbm[cfg`vol;cfg`drift;eps;dts]
  };

jump.events:{[cfg;duration]
  / the day's price jumps as events (Merton jump-diffusion): Poisson arrivals
  / at jumpintensity per day, uniform in the session, with lognormal sizes
  / cfg: config dict with `jumpintensity`jumpmean`jumpvol`rngmodel
  / duration: session length in seconds
  / returns: table `time`factor, time in seconds from open ascending, factor
  /   the multiplicative jump exp(jumpmean+jumpvol*N)
  n:first .z.m.rng.poisson[enlist `float$cfg`jumpintensity;40];
  times:asc n?`float$duration;
  ([]time:times;factor:exp cfg[`jumpmean]+cfg[`jumpvol]*.z.m.rng.normal[n;cfg])
  };

clocksteps:{[cfg;times]
  / the time steps in years between successive points, by the config's clock
  / cfg: config dict with `clock`tradingdays`openingtime`closingtime
  / times: points in seconds from open, ascending
  / returns: float per point, the first 0
  /
  / clock `calendar: elapsed seconds over the trading year's seconds, so
  /   variance grows with clock time and realized vol is flat through the day
  / clock `transaction: every step carries the same variance, a trading
  /   day's over the points, so variance grows with activity: realized vol
  /   follows the intraday profile and rises in bursts (and clusters), as it
  /   does in a market
  n:count times;
  $[`transaction=`calendar^cfg`clock;
    0f,(n-1)#1%cfg[`tradingdays]*1|n-1;
    [open:`timespan$cfg`openingtime; close:`timespan$cfg`closingtime;
     (0f,1_deltas times)%cfg[`tradingdays]*(close-open)%nspersec]]
  };

pricepath:{[cfg;times;jumps]
  / the price path at the given points: start price, diffusion steps by the
  / config's clock, and the jumps at or before each point
  / cfg: config dict with `startprice`vol`drift`clock`tradingdays and the session keys
  / times: points in seconds from open, ascending
  / jumps: `time`factor table (see jump.events), possibly empty
  / returns: price per point
  times:`float$times;
  path:cfg[`startprice]*prds .z.m.diffusion[cfg;.z.m.clocksteps[cfg;times]];
  path*1f^(prds jumps`factor) jumps[`time] bin times
  };

price:{[cfg;times]
  / generate prices for given points in time
  / cfg: configuration dictionary
  / times: list of times in seconds from session start, ascending
  / returns: list of prices corresponding to each time
  /
  / Required config keys:
  /   openingtime, closingtime, tradingdays, pricemodel, startprice, vol, drift
  /   For jump model: jumpintensity, jumpmean, jumpvol
  /   clock (`calendar or `transaction, see clocksteps) defaults to `calendar
  /
  / startprice is the price at the session open; a first time of 0 returns it
  .z.m.val.nonempty[times;"times";"price"];
  if[any times<0; '"price: times must be non-negative"];
  reqkeys:`openingtime`closingtime`tradingdays`pricemodel`startprice`vol`drift;
  .z.m.val.haskeys[cfg;reqkeys;"price"];
  duration:(`timespan$cfg[`closingtime])-`timespan$cfg`openingtime;
  jumps:$[`jump=cfg`pricemodel; .z.m.jump.events[cfg;duration%nspersec]; ([]time:`float$();factor:`float$())];
  .z.m.pricepath[cfg;times;jumps]
  };

qty.constant:{[n;cfg]
  / generate constant quantities
  / n: number of quantities
  / cfg: config dict with `qty
  / returns: list of n identical quantities
  n#cfg`avgqty
  };

qty.lognormal:{[n;cfg]
  / generate lognormal random quantities
  / n: number of quantities
  / cfg: config dict with `avgqty`qtyvol`rngmodel
  / returns: list of n integer quantities (minimum 1)
  avgqty:cfg`avgqty;
  qtyvol:cfg`qtyvol;
  mu:log[avgqty]-0.5*qtyvol*qtyvol;
  eps:.z.m.rng.normal[n;cfg];
  `long$1|floor exp mu+qtyvol*eps
  };

qty.gen:{[n;cfg]
  / dispatch to appropriate quantity generator
  / n: number of quantities
  / cfg: config dict with `qtymodel and model-specific params
  / returns: list of n quantities
  model:cfg`qtymodel;
  $[model=`constant;  .z.m.qty.constant[n;cfg];
    model=`lognormal; .z.m.qty.lognormal[n;cfg];
    '"qty.gen: unknown qtymodel - ",string model]
  };

quote.seeds:{[cfg;arrs]
  / quote updates seeded by the trades: after each trade, Poisson
  / (quotetradelink*quotespertrade*(1-alpha/beta)) immigrants at Exp(beta)
  / delays, each with its usual cascade, so that quotetradelink of the
  / quote updates follow the trades (a burst of trades brings a burst of
  / quotes) and the rest arrive on the background quote clock
  / cfg: config dict with `quotetradelink`quotespertrade`alpha`beta
  / arrs: trade times in seconds from open
  / returns: ascending times in seconds from open
  n:count arrs;
  k:count .z.m.poisson[1f;n*cfg[`quotetradelink]*cfg[`quotespertrade]*1-cfg[`alpha]%cfg`beta];
  if[0=k; :`float$()];
  asc arrs[k?n]+neg log[1-k?1.0]%cfg`beta
  };

quote.activity:{[cfg;quotearrs]
  / local quote activity relative to its expected level: the quotes in the
  / trailing minute over the number the intensity profile expects there,
  / raised to spreadactivity; multiplies the mean spread, so bursts widen it
  / cfg: config dict with `spreadactivity`quotespertrade`baseintensity`alpha`beta and the shape keys
  / quotearrs: quote times in seconds from open, ascending
  / returns: float multiplier per quote, 1 when spreadactivity is 0
  n:count quotearrs;
  if[0=cfg`spreadactivity; :n#1f];
  duration:((`timespan$cfg`closingtime)-`timespan$cfg`openingtime)%nspersec;
  cnt:(til n)-quotearrs bin quotearrs-60f;
  rate:cfg[`quotespertrade]*cfg[`baseintensity]*.z.m.shape[cfg;quotearrs%duration]%1-cfg[`alpha]%cfg`beta;
  ratio:(1+cnt)%1+rate*60f&quotearrs;
  xexp[0.25|ratio&4;cfg`spreadactivity]
  };

quote.generate:{[cfg;times;mids;activity]
  / quote table from the mid path sampled on the quote clock
  / cfg: config dict with `spreadticks`spreadopenmult`spreadmidmult`spreadclosemult`spreaddecayminutes`avgquotesize`quotesizevol`imbalancesignal`ticksize`rngmodel
  / times: quote timestamps, ascending, the first at the session open
  / mids: mid price at each time (the price path sampled on the quote clock)
  / activity: spread multiplier per quote from local activity (see quote.activity)
  / returns: quote table `time`bid`ask`bidsize`asksize; bid and ask on the
  /   tick grid, the spread a whole number of ticks, at least one; sizes in
  /   round lots of 100
  n:count times;
  ticksize:cfg`ticksize;

  / spread in whole ticks: one tick plus a Poisson excess whose mean is
  / spreadticks times the time-of-day multiplier, less the one tick
  meanticks:cfg[`spreadticks]*activity*.z.m.quote.spreadmults[cfg;times];
  ticks:1+.z.m.rng.poisson[0f|meanticks-1;12];

  / the spread sits around the mid, its bid on the tick grid
  bid:ticksize*floor 0.5+(mids-0.5*ticks*ticksize)%ticksize;
  ask:bid+ticks*ticksize;

  / sizes: lognormal around avgquotesize, in round lots, the bid side
  / larger before the mid rises and the ask side before it falls
  / (imbalancesignal: the book leans toward the next move, weakly)
  lv:cfg`quotesizevol;
  nextmove:signum (1_mids,last mids)-mids;
  tilt:cfg[`imbalancesignal]*nextmove;
  bidsize:cfg[`avgquotesize]*exp (lv*.z.m.rng.normal[n;cfg])+tilt-0.5*lv*lv;
  asksize:cfg[`avgquotesize]*exp (lv*.z.m.rng.normal[n;cfg])-tilt+0.5*lv*lv;
  bidsize:100*1|`long$0.5+bidsize%100;
  asksize:100*1|`long$0.5+asksize%100;
  ([]time:times;bid:bid;ask:ask;bidsize:bidsize;asksize:asksize)
  };

flow.generate:{[cfg;n]
  / the order flow of n trades: aggressor signs and quantities
  / cfg: config dict with `sidepersistence and the quantity model keys
  / n: number of trades, positive
  / returns: dict `sign`qty; sign +1 (buyer-initiated) or -1 (seller-initiated)
  /
  / signs follow a Markov chain, each repeating the previous one with
  / probability sidepersistence (lag-1 autocorrelation 2*sidepersistence-1)
  flips:(n?1.0)>cfg`sidepersistence;
  flips[0]:0b;
  sign:(1-2*first 1?2)*1-2*(sums flips) mod 2;
  `sign`qty!(sign;.z.m.qty.gen[n;cfg])
  };

flow.impact:{[cfg;tradetimes;flow;quotetimes]
  / the shift of the mid in force at each quote time from the signed trades
  / before it (a propagator): each trade moves the mid by impactticks ticks
  / times sqrt(qty/avgqty) in its direction; a share impactpermanent of that
  / stays, the rest halves every impacthalflife seconds. With persistent
  / signs this gives the tape price impact and partial reversion after a
  / trade, what markout curves measure
  / cfg: config dict with `impactticks`impacthalflife`impactpermanent`ticksize`avgqty
  / tradetimes: trade times in seconds from open, ascending
  / flow: `sign`qty of those trades (see flow.generate)
  / quotetimes: quote times in seconds from open, ascending
  / returns: float shift per quote time, in price units
  n:count tradetimes;
  if[(0=n) or 0=cfg`impactticks; :(count quotetimes)#0f];
  imp:cfg[`impactticks]*cfg[`ticksize]*flow[`sign]*sqrt flow[`qty]%cfg`avgqty;
  lam:log[2]%cfg`impacthalflife;
  perm:cfg`impactpermanent;
  / transient part in force just after each trade, and the permanent part
  trans:{[e;dt;a] a+e*exp neg dt}\[0f;lam*deltas tradetimes;(1-perm)*imp];
  permcum:sums perm*imp;
  / at each quote time: the parts left from the last trade before it
  j:tradetimes bin quotetimes;
  0f^permcum[j]+trans[j]*exp neg lam*quotetimes-tradetimes j
  };

trade.generate:{[cfg;times;quotes;flow]
  / trades against the quote in force at their time: a buyer-initiated trade
  / takes the ask, a seller-initiated one the bid; a share of trades prints
  / at the midpoint and a share a tenth of a tick inside the touch (price
  / improvement)
  / cfg: config dict with `midpointshare`improvementshare`ticksize
  / times: trade timestamps, ascending, none before the first quote
  / quotes: quote table (see quote.generate)
  / flow: `sign`qty of the trades (see flow.generate)
  / returns: trade table `time`price`qty`aggressor, aggressor `B (buyer-
  /   initiated) or `S; prices on the tenth-of-a-tick grid
  n:count times;
  idx:quotes[`time] bin times;
  bid:quotes[`bid] idx;
  ask:quotes[`ask] idx;
  mid:0.5*bid+ask;
  sign:flow`sign;

  / where the trade prints: touch, midpoint or a tenth of a tick inside the touch
  u:n?1.0;
  atmid:u<cfg`midpointshare;
  improved:(not atmid)&u<cfg[`midpointshare]+cfg`improvementshare;
  touch:?[sign>0;ask;bid];
  price:?[atmid;mid;?[improved;touch-sign*0.1*cfg`ticksize;touch]];
  grid:0.1*cfg`ticksize;
  price:grid*floor 0.5+price%grid;

  ([]time:times;price:price;qty:flow`qty;aggressor:?[sign>0;`B;`S])
  };

quote.spreadmults:{[cfg;times]
  / spread multiplier by time of day (vectorized): spreadmidmult through the
  / day, moved toward spreadopenmult after the open and toward
  / spreadclosemult before the close, each with an exponential decay of
  / spreaddecayminutes (for a large cap the spread is widest in the first
  / minutes and tightens within the half hour; it is tightest at the close)
  / cfg: config dict with `openingtime`closingtime`spreadopenmult`spreadmidmult`spreadclosemult`spreaddecayminutes
  / times: list of timestamps
  / returns: list of spread multipliers
  opentime:`timespan$cfg`openingtime;
  closetime:`timespan$cfg`closingtime;
  timeofday:times-`timestamp$`date$times;
  sinceopen:0f|(`float$timeofday-opentime)%60*nspersec;
  toclose:0f|(`float$closetime-timeofday)%60*nspersec;
  tau:cfg`spreaddecayminutes;
  midm:cfg`spreadmidmult;
  midm+((cfg[`spreadopenmult]-midm)*exp neg sinceopen%tau)+(cfg[`spreadclosemult]-midm)*exp neg toclose%tau
  };

validate:{[cfg]
  / validate configuration dictionary for run
  / cfg: configuration dictionary
  / returns: cfg if valid, throws error otherwise
  /
  / Checks:
  /   - Hawkes stability: alpha < beta
  /   - Positive multipliers: openmult, midmult, closemult > 0
  /   - Positive base intensity
  /   - Transitionpoint in valid range (prevents division by zero)
  /   - Positive volatility (zero vol produces degenerate flat price path)
  /   - Positive start price (negative/zero price is economically invalid)
  /   - Positive tick size, positive quotespertrade, sidepersistence and the
  /     midpoint and improvement shares between 0 and 1 (shares summing to
  /     at most 1)

  / check Hawkes stability condition
  if[cfg[`alpha]>=cfg`beta; '"validate: Hawkes unstable - alpha must be < beta"];
  / check multipliers positive
  if[0>=min cfg`openmult`midmult`closemult; '"validate: multipliers must be positive"];
  / check base intensity
  if[0>=cfg`baseintensity; '"validate: baseintensity must be positive"];
  / check transitionpoint bounds (prevents division by zero in shape function)
  if[not cfg[`transitionpoint] within 0.01 0.99;
    '"validate: transitionpoint must be between 0.01 and 0.99"];
  / check vol positive (zero produces NaN in log, flat path with no signal)
  if[0>=cfg`vol; '"validate: vol must be positive"];
  / check startprice positive (GBM/jump models require positive initial price)
  if[0>=cfg`startprice; '"validate: startprice must be positive"];
  / microstructure keys: in the config since a preset must describe a run fully
  reqkeys:`ticksize`spreadticks`spreadopenmult`spreadmidmult`spreadclosemult`spreaddecayminutes`avgquotesize;
  reqkeys,:`quotespertrade`sidepersistence`midpointshare`improvementshare;
  .z.m.val.haskeys[cfg;reqkeys;"validate"];
  if[0>=cfg`ticksize; '"validate: ticksize must be positive"];
  if[1>cfg`spreadticks; '"validate: spreadticks must be at least 1"];
  if[0>=min cfg`spreadopenmult`spreadmidmult`spreadclosemult; '"validate: spread multipliers must be positive"];
  if[0>=cfg`spreaddecayminutes; '"validate: spreaddecayminutes must be positive"];
  if[0>=cfg`quotespertrade; '"validate: quotespertrade must be positive"];
  .z.m.val.haskeys[cfg;`quotetradelink`quotesizevol`imbalancesignal;"validate"];
  if[not cfg[`quotetradelink] within 0 1; '"validate: quotetradelink must be between 0 and 1"];
  if[0>cfg`quotesizevol; '"validate: quotesizevol must be zero or positive"];
  if[0>cfg`imbalancesignal; '"validate: imbalancesignal must be zero or positive"];
  if[not cfg[`sidepersistence] within 0 1; '"validate: sidepersistence must be between 0 and 1"];
  if[not all cfg[`midpointshare`improvementshare] within 0 1;
    '"validate: midpointshare and improvementshare must be between 0 and 1"];
  if[1<cfg[`midpointshare]+cfg`improvementshare;
    '"validate: midpointshare and improvementshare must not exceed 1 together"];
  / clock, activity coupling, jump bursts
  .z.m.val.haskeys[cfg;`clock`spreadactivity`jumpburst`jumpburstminutes;"validate"];
  if[not cfg[`clock] in `calendar`transaction; '"validate: clock must be calendar or transaction"];
  if[0>cfg`spreadactivity; '"validate: spreadactivity must be zero or positive"];
  if[0>cfg`jumpburst; '"validate: jumpburst must be zero or positive"];
  if[0>=cfg`jumpburstminutes; '"validate: jumpburstminutes must be positive"];
  / order-flow impact
  .z.m.val.haskeys[cfg;`impactticks`impacthalflife`impactpermanent;"validate"];
  if[0>cfg`impactticks; '"validate: impactticks must be zero or positive"];
  if[0>=cfg`impacthalflife; '"validate: impacthalflife must be positive"];
  if[not cfg[`impactpermanent] within 0 1; '"validate: impactpermanent must be between 0 and 1"];
  cfg
  };


run:{[cfg]
  / main simulation entry point
  / cfg: configuration dictionary (typically loaded via loadconfig)
  / returns: trade table if generatequotes=0b, else dict with `trade`quote
  /
  / quotes come first: quote updates arrive on their own Hawkes clock at
  / quotespertrade times the trade intensity (same clustering), a share
  / quotetradelink of them seeded by the trades themselves (see
  / quote.seeds), starting with a quote at the open, and the price path is
  / sampled on that clock
  / as the mid, shifted by the impact of the signed order flow before each
  / quote (see flow.impact); a jump seeds a burst on both clocks (see
  / hawkes.shock) and local activity widens the spread (see quote.activity).
  / Trades arrive on the trade clock and execute
  / against the quote in force (see trade.generate), so every trade sits
  / inside its prevailing quote and carries an aggressor side
  /
  / Example:
  /   cfg:first loadconfig`:presets.csv
  /   trades:run[cfg]
  /   cfg[`generatequotes]:1b
  /   result:run[cfg]  / result`trade, result`quote
  cfg:.z.m.validate[cfg];

  / set seed for reproducibility (0N = no seed)
  if[not null cfg`seed; system "S ",string cfg`seed];

  basetime:cfg[`tradingdate]+`timespan$cfg`openingtime;

  / the day's jumps, and the bursts of activity they seed on both clocks
  duration:((`timespan$cfg`closingtime)-`timespan$cfg`openingtime)%nspersec;
  jumps:$[`jump=cfg`pricemodel; .z.m.jump.events[cfg;duration]; ([]time:`float$();factor:`float$())];
  tradeshock:.z.m.hawkes.shock[cfg;jumps`time;cfg`jumpburst];
  quoteshock:.z.m.hawkes.shock[cfg;jumps`time;`long$cfg[`jumpburst]*cfg`quotespertrade];

  / the trade clock (seconds from open) and the order flow on it
  arrs:.z.m.hawkes.process[cfg;cfg`baseintensity;tradeshock];
  n:count arrs;
  flow:$[n; .z.m.flow.generate[cfg;n]; `sign`qty!(`long$();`long$())];

  / the quote clock: a quote at the open, background updates at
  / (1-quotetradelink) of the rate, and updates seeded by the trades
  background:cfg[`baseintensity]*cfg[`quotespertrade]*1-cfg`quotetradelink;
  quotearrs:0f,.z.m.hawkes.process[cfg;background;asc quoteshock,.z.m.quote.seeds[cfg;arrs]];

  / the mid on the quote clock: the price path (by the config's clock, with
  / the jumps) plus the order flow's impact
  mids:.z.m.pricepath[cfg;quotearrs;jumps];
  mids+:.z.m.flow.impact[cfg;arrs;flow;quotearrs];
  activity:.z.m.quote.activity[cfg;quotearrs];
  quotes:.z.m.quote.generate[cfg;basetime+`timespan$`long$quotearrs*nspersec;mids;activity];

  / trades against the quote in force
  trades:$[n;
    .z.m.trade.generate[cfg;basetime+`timespan$`long$arrs*nspersec;quotes;flow];
    ([]time:`timestamp$();price:`float$();qty:`long$();aggressor:`symbol$())];

  addsym:{[s;t] update `p#sym from `sym`time xcols update sym:s from t};
  trades:addsym[cfg`sym;trades];
  $[cfg`generatequotes; `trade`quote!(trades;addsym[cfg`sym;quotes]); trades]
  };

/ configuration schema: column name -> (type; description)
/ type codes: S=symbol, D=date, U=minute, F=float, J=long, B=boolean
schema:()!()
schema[`name]:("S";"preset name (key)")
schema[`sym]:("S";"ticker symbol")
schema[`tradingdate]:("D";"simulation date")
schema[`openingtime]:("U";"market open time")
schema[`closingtime]:("U";"market close time")
schema[`startprice]:("F";"initial price")
schema[`seed]:("J";"random seed (0N = no seed, use null long)")
schema[`rngmodel]:("S";"RNG model (`pseudo)")
schema[`drift]:("F";"annualized drift")
schema[`vol]:("F";"annualized volatility")
schema[`tradingdays]:("J";"trading days per year")
schema[`pricemodel]:("S";"price model (`gbm or `jump)")
schema[`jumpintensity]:("F";"jump arrival rate (jumps/day)")
schema[`jumpmean]:("F";"log jump mean")
schema[`jumpvol]:("F";"log jump volatility")
schema[`jumpburst]:("J";"extra trade immigrants seeded by each jump (each with its usual cascade); 0 = none")
schema[`jumpburstminutes]:("F";"mean delay in minutes of those immigrants after the jump")
schema[`clock]:("S";"clock of the diffusion: `calendar (variance grows with time, flat intraday vol) or `transaction (variance grows with activity: U-shaped vol, bursts)")
schema[`baseintensity]:("F";"base trade arrival rate (trades/sec)")
schema[`alpha]:("F";"Hawkes excitation parameter")
schema[`beta]:("F";"Hawkes decay parameter (must be > alpha)")
schema[`transitionpoint]:("F";"intraday shape parameter (0.3=J, 0.5=U)")
schema[`openmult]:("F";"intensity multiplier at open")
schema[`midmult]:("F";"intensity multiplier at midday")
schema[`closemult]:("F";"intensity multiplier at close")
schema[`qtymodel]:("S";"quantity model (`constant or `lognormal)")
schema[`avgqty]:("J";"average trade quantity")
schema[`qtyvol]:("F";"quantity volatility (for lognormal)")
schema[`generatequotes]:("B";"generate quotes flag")
schema[`spreadticks]:("F";"mean bid-ask spread in ticks through the day, at least 1 (the spread is 1 tick plus a Poisson excess)")
schema[`spreadopenmult]:("F";"spread multiplier at the open, decaying to the midday one")
schema[`spreadmidmult]:("F";"spread multiplier through the day")
schema[`spreadclosemult]:("F";"spread multiplier at the close, reached by the same decay")
schema[`spreaddecayminutes]:("F";"minutes over which the open and close spread multipliers decay toward the midday one (e-folding time)")
schema[`spreadactivity]:("F";"exponent of local quote activity (trailing minute over its expected level) multiplying the mean spread; 0 = none")
schema[`avgquotesize]:("J";"average quote size")
schema[`ticksize]:("F";"minimum price increment; quotes are rounded to it, trades to a tenth of it (0.01 for US equities)")
schema[`quotespertrade]:("F";"quote updates per trade on average: quotes arrive on their own Hawkes clock at this multiple of the trade intensity")
schema[`quotetradelink]:("F";"share of the quote updates seeded by the trades (at Exp(beta) delays after them), between 0 and 1; the rest arrive on the background quote clock")
schema[`quotesizevol]:("F";"log volatility of quote sizes (lognormal around avgquotesize, in round lots of 100)")
schema[`imbalancesignal]:("F";"log tilt of the quote sizes toward the side of the next mid move (bid larger before a rise); 0 = none")
schema[`sidepersistence]:("F";"probability a trade's aggressor side repeats the previous trade's (0.5 = independent sides)")
schema[`midpointshare]:("F";"share of trades printing at the midpoint")
schema[`improvementshare]:("F";"share of trades printing a tenth of a tick inside the touch")
schema[`impactticks]:("F";"order-flow impact: ticks an average-size trade moves the mid in its direction (0 = none), scaled by sqrt(qty/avgqty)")
schema[`impacthalflife]:("F";"order-flow impact: seconds over which the transient part of a trade's impact halves")
schema[`impactpermanent]:("F";"order-flow impact: share of a trade's impact that never decays, between 0 and 1")

/ derive type string from schema
csvtypes:raze first each value schema

loadconfig:{[filepath]
  / load preset configurations from CSV file
  / filepath: file handle to CSV (e.g., `:presets.csv)
  / returns: keyed table with preset name as key
  /
  / Example:
  /   cfgs:loadconfig`:di/simtick/presets.csv
  /   cfg:cfgs`default
  /   run[cfg]
  if[not -11h=type filepath; '"loadconfig: filepath must be a file handle"];
  / the type string is applied by column position, so the header is checked
  / against the schema first: any column order loads, a missing, unknown or
  / repeated column throws instead of parsing values into the wrong types
  hdr:`$csv vs first read0 filepath;
  expected:key .z.m.schema;
  if[count missing:expected except hdr; '"loadconfig: missing columns - ",", " sv string missing];
  if[count unknown:hdr except expected; '"loadconfig: unknown columns - ",", " sv string unknown];
  if[count[hdr]<>count distinct hdr; '"loadconfig: repeated columns - ",", " sv string distinct hdr where 1<count each group[hdr] hdr];
  types:raze first each .z.m.schema hdr;
  1!expected xcols (types;enlist csv) 0: filepath
  };

describe:{[]
  / return configuration schema as a table
  / useful for documentation and introspection
  / Example:
  /   simtick.describe[]
  ([]param:key .z.m.schema;typ:first each value .z.m.schema;description:last each value .z.m.schema)
  };

/ export public interface
export:([run;arrivals;price;loadconfig;describe])
