/ di.simtick - realistic intraday tick simulator

/ time unit conversions
nsperms:1000000
nspersec:1000000000

/ configuration layers (market, instrument, scenario, run) composed by di.simconfig
simconfig:use`di.simconfig


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

profile:{[cfg]
  / the intraday profile as float weights, from the config's `profile: a
  / space-separated string (as in the CSV) or a list of numbers
  / cfg: config dict with `profile
  / returns: list of positive floats, one per equal bin of the session
  p:cfg`profile;
  w:$[10h=abs type p; "F"$" " vs (),p; `float$(),p];
  if[(0=count w) or any null w; '"profile: must be a list of numbers (a space-separated string in the CSV)"];
  w
  };

shape:{[cfg;progress]
  / intraday intensity multiplier: the config's profile gives one weight per
  / equal bin of the session (13 half hours for a 6.5-hour day), interpolated
  / linearly between bin midpoints and flat beyond the first and last, so a
  / flat midday and a spike in the last minutes are both expressible. The
  / multiplier never exceeds the largest weight, which hawkes.process relies on
  / cfg: config dict with `profile
  / progress: fraction of trading day elapsed (0 to 1), atom or list
  / returns: intensity multiplier for each progress
  w:.z.m.profile cfg;
  n:count w;
  if[1=n; :$[0>type progress; first w; (count progress)#first w]];
  x:0f|(n-1)&(progress*n)-0.5;
  i:(n-2)&`long$floor x;
  w[i]+(x-i)*w[i+1]-w[i]
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
  / cfg: config dict with `alpha`beta`openingtime`closingtime`profile
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
  maxmult:max .z.m.profile cfg;
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
  /   baseintensity, alpha, beta, openingtime, closingtime, profile
  reqkeys:`baseintensity`alpha`beta`openingtime`closingtime`profile;
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
  / cfg: config dict with `price`vol`drift`clock`tradingdays and the session keys
  / times: points in seconds from open, ascending
  / jumps: `time`factor table (see jump.events), possibly empty
  / returns: price per point
  times:`float$times;
  path:cfg[`price]*prds .z.m.diffusion[cfg;.z.m.clocksteps[cfg;times]];
  path*1f^(prds jumps`factor) jumps[`time] bin times
  };

price:{[cfg;times]
  / generate prices for given points in time
  / cfg: configuration dictionary
  / times: list of times in seconds from session start, ascending
  / returns: list of prices corresponding to each time
  /
  / Required config keys:
  /   openingtime, closingtime, tradingdays, pricemodel, price, vol, drift
  /   For jump model: jumpintensity, jumpmean, jumpvol
  /   clock (`calendar or `transaction, see clocksteps) defaults to `calendar
  /
  / price is the price at the session open; a first time of 0 returns it
  .z.m.val.nonempty[times;"times";"price"];
  if[any times<0; '"price: times must be non-negative"];
  reqkeys:`openingtime`closingtime`tradingdays`pricemodel`price`vol`drift;
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

qty.mixture:{[n;cfg]
  / a mixture of trade sizes as printed on a US tape: a share roundlotshare
  / of round lots (roundlots by roundlotweights), a share blockshare of
  / blocks (lognormal, median blockqty, log-sd blockqtyvol), and the
  / rest irregular lots, lognormal with mean avgqty and log-sd qtyvol (mostly
  / odd lots for a large cap)
  / n: number of quantities
  / cfg: config dict with `roundlotshare`blockshare`blockqty`blockqtyvol`roundlots`roundlotweights`avgqty`qtyvol`rngmodel
  / returns: list of n long quantities (minimum 1)
  u:n?1.0;
  isround:u<cfg`roundlotshare;
  isblock:(not isround)&u<cfg[`roundlotshare]+cfg`blockshare;
  rq:cfg[`roundlots] (sums cfg`roundlotweights) binr n?1.0;
  bq:floor 0.5+cfg[`blockqty]*exp cfg[`blockqtyvol]*.z.m.rng.normal[n;cfg];
  iq:.z.m.qty.lognormal[n;cfg];
  1|?[isround;rq;?[isblock;bq;iq]]
  };

qty.mean:{[cfg]
  / the expected trade size under the config's quantity model, the size
  / an average trade's impact is scaled by
  / cfg: config dict with `qtymodel and model-specific params
  / returns: float
  model:cfg`qtymodel;
  $[model=`mixture;
    [r:cfg`roundlotshare; b:cfg`blockshare;
     ((1-r+b)*cfg`avgqty)+(r*sum cfg[`roundlots]*cfg`roundlotweights)+b*cfg[`blockqty]*exp 0.5*cfg[`blockqtyvol]*cfg`blockqtyvol];
    `float$cfg`avgqty]
  };

qty.gen:{[n;cfg]
  / dispatch to appropriate quantity generator
  / n: number of quantities
  / cfg: config dict with `qtymodel and model-specific params
  / returns: list of n quantities
  model:cfg`qtymodel;
  $[model=`constant;  .z.m.qty.constant[n;cfg];
    model=`lognormal; .z.m.qty.lognormal[n;cfg];
    model=`mixture;   .z.m.qty.mixture[n;cfg];
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
  / trailing activitywindowseconds over the number the intensity profile
  / expects there, clipped to activityclip and raised to spreadactivity;
  / multiplies the mean spread, so bursts widen it
  / cfg: config dict with `spreadactivity`activitywindowseconds`activityclip`quotespertrade`baseintensity`alpha`beta`profile
  / quotearrs: quote times in seconds from open, ascending
  / returns: float multiplier per quote, 1 when spreadactivity is 0
  n:count quotearrs;
  if[0=cfg`spreadactivity; :n#1f];
  duration:((`timespan$cfg`closingtime)-`timespan$cfg`openingtime)%nspersec;
  w:`float$cfg`activitywindowseconds;
  cnt:(til n)-quotearrs bin quotearrs-w;
  rate:cfg[`quotespertrade]*cfg[`baseintensity]*.z.m.shape[cfg;quotearrs%duration]%1-cfg[`alpha]%cfg`beta;
  ratio:(1+cnt)%1+rate*w&quotearrs;
  clip:cfg`activityclip;
  xexp[clip[0]|ratio&clip[1];cfg`spreadactivity]
  };

quote.generate:{[cfg;times;mids;activity]
  / quote table from the mid path sampled on the quote clock
  / cfg: config dict with `spreadticks`spreadopenmult`spreadmidmult`spreadclosemult`spreaddecayminutes`avgquotesize`quotesizevol`quotelot`imbalancesignal`ticksize`rngmodel
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

  / sizes: lognormal around avgquotesize, in lots of quotelot, the bid side
  / larger before the mid rises and the ask side before it falls
  / (imbalancesignal: the book leans toward the next move, weakly)
  lv:cfg`quotesizevol;
  nextmove:signum (1_mids,last mids)-mids;
  tilt:cfg[`imbalancesignal]*nextmove;
  bidsize:cfg[`avgquotesize]*exp (lv*.z.m.rng.normal[n;cfg])+tilt-0.5*lv*lv;
  asksize:cfg[`avgquotesize]*exp (lv*.z.m.rng.normal[n;cfg])-tilt+0.5*lv*lv;
  lot:cfg`quotelot;
  bidsize:lot*1|floor 0.5+bidsize%lot;
  asksize:lot*1|floor 0.5+asksize%lot;
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
  / times sqrt(qty/mean size) in its direction; a share impactpermanent of that
  / stays, the rest halves every impacthalflifeseconds. With persistent
  / signs this gives the tape price impact and partial reversion after a
  / trade, what markout curves measure
  / cfg: config dict with `impactticks`impacthalflifeseconds`impactpermanent`ticksize and the quantity keys
  / tradetimes: trade times in seconds from open, ascending
  / flow: `sign`qty of those trades (see flow.generate)
  / quotetimes: quote times in seconds from open, ascending
  / returns: float shift per quote time, in price units
  n:count tradetimes;
  if[(0=n) or 0=cfg`impactticks; :(count quotetimes)#0f];
  imp:cfg[`impactticks]*cfg[`ticksize]*flow[`sign]*sqrt flow[`qty]%.z.m.qty.mean cfg;
  lam:log[2]%cfg`impacthalflifeseconds;
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
  / at the midpoint and a share improvementtick of a tick inside the touch
  / (price improvement); prices sit on the printgrid of a tick
  / cfg: config dict with `midpointshare`improvementshare`improvementtick`printgrid`ticksize`offexchangeshare`offexchangeinside`venues`venueshares
  / times: trade timestamps, ascending, none before the first quote
  / quotes: quote table (see quote.generate)
  / flow: `sign`qty of the trades (see flow.generate)
  / returns: trade table `time`price`qty`aggressor`cond`venue, aggressor `B
  /   (buyer-initiated) or `S, cond `R (regular) or `I (odd lot, below 100),
  /   venue a lit MIC code or `TRF
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
  price:?[atmid;mid;?[improved;touch-sign*cfg[`improvementtick]*cfg`ticksize;touch]];
  grid:cfg[`printgrid]*cfg`ticksize;
  price:grid*floor 0.5+price%grid;

  / venue: midpoint and improved prints are off-exchange with probability
  / offexchangeinside (dark pools, wholesalers reporting to the TRF); prints
  / at the touch are split so that the day's off-exchange share is
  / offexchangeshare; lit prints spread over venues by venueshares
  inside:atmid|improved;
  offinside:cfg`offexchangeinside;
  offtouch:0f|(cfg[`offexchangeshare]-offinside*avg inside)%1-avg inside;
  isoff:(n?1.0)<?[inside;offinside;offtouch];
  lit:cfg[`venues] (sums cfg`venueshares) binr n?1.0;
  venue:?[isoff;`TRF;lit];

  qty:flow`qty;
  ([]time:times;price:price;qty:qty;aggressor:?[sign>0;`B;`S];cond:?[qty<100;`I;`R];venue:venue)
  };

auction.prints:{[cfg;quotes;volume]
  / the opening and closing auction prints: at the first and last mid, for
  / openauctionpct and closeauctionpct of the continuous volume, cond `O and
  / `C, with no aggressor; a print of zero quantity is left out
  / cfg: config dict with `openauctionpct`closeauctionpct`closingtime`ticksize`primaryvenue
  / quotes: the day's quote table
  / volume: the day's continuous volume
  / returns: trade table `time`price`qty`aggressor`cond`venue, up to two rows,
  /   venue the primary listing venue
  ts:cfg`ticksize;
  q0:first quotes;
  q1:last quotes;
  opent:q0`time;
  closet:(`date$opent)+`timespan$cfg`closingtime;
  mids:0.5*(q0[`bid]+q0`ask;q1[`bid]+q1`ask);
  t:([]time:(opent;closet);price:ts*floor 0.5+mids%ts;
    qty:floor 0.5+volume*cfg`openauctionpct`closeauctionpct;aggressor:2#`;cond:`O`C;venue:2#cfg`primaryvenue);
  select from t where qty>0
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
  /   - Positive profile weights
  /   - Positive base intensity
  /   - Non-negative auction percentages
  /   - Positive volatility (zero vol produces degenerate flat price path)
  /   - Positive price (negative/zero price is economically invalid)
  /   - Positive tick size, positive quotespertrade, sidepersistence and the
  /     midpoint and improvement shares between 0 and 1 (shares summing to
  /     at most 1)

  / check Hawkes stability condition
  if[cfg[`alpha]>=cfg`beta; '"validate: Hawkes unstable - alpha must be < beta"];
  / check the intraday profile
  if[0>=min .z.m.profile cfg; '"validate: profile weights must be positive"];
  / check base intensity
  if[0>=cfg`baseintensity; '"validate: baseintensity must be positive"];
  / quantity mixture, venues
  .z.m.val.haskeys[cfg;`roundlotshare`blockshare`blockqty`offexchangeshare`primaryvenue;"validate"];
  if[not all cfg[`roundlotshare`blockshare`offexchangeshare] within 0 1;
    '"validate: roundlotshare, blockshare and offexchangeshare must be between 0 and 1"];
  if[1<cfg[`roundlotshare]+cfg`blockshare; '"validate: roundlotshare and blockshare must not exceed 1 together"];
  if[0>=cfg`blockqty; '"validate: blockqty must be positive"];
  / auctions
  .z.m.val.haskeys[cfg;`openauctionpct`closeauctionpct;"validate"];
  if[0>min cfg`openauctionpct`closeauctionpct; '"validate: auction percentages must be zero or positive"];
  / check vol positive (zero produces NaN in log, flat path with no signal)
  if[0>=cfg`vol; '"validate: vol must be positive"];
  / check price positive (GBM/jump models require positive initial price)
  if[0>=cfg`price; '"validate: price must be positive"];
  / microstructure keys: in the config since a preset must describe a run fully
  reqkeys:`ticksize`printgrid`spreadticks`spreadopenmult`spreadmidmult`spreadclosemult`spreaddecayminutes`avgquotesize;
  reqkeys,:`activitywindowseconds`activityclip`quotelot`improvementtick`offexchangeinside`venues`venueshares;
  reqkeys,:`roundlots`roundlotweights`blockqtyvol;
  reqkeys,:`quotespertrade`sidepersistence`midpointshare`improvementshare;
  .z.m.val.haskeys[cfg;reqkeys;"validate"];
  if[0>=cfg`ticksize; '"validate: ticksize must be positive"];
  if[not (0<cfg`printgrid)&1>=cfg`printgrid; '"validate: printgrid must be between 0 and 1"];
  if[not cfg[`offexchangeinside] within 0 1; '"validate: offexchangeinside must be between 0 and 1"];
  if[not cfg[`improvementtick] within 0 1; '"validate: improvementtick must be between 0 and 1"];
  if[count[cfg`venues]<>count cfg`venueshares; '"validate: venues and venueshares must have the same length"];
  if[1e-6<abs 1-sum cfg`venueshares; '"validate: venueshares must sum to 1"];
  if[count[cfg`roundlots]<>count cfg`roundlotweights; '"validate: roundlots and roundlotweights must have the same length"];
  if[1e-6<abs 1-sum cfg`roundlotweights; '"validate: roundlotweights must sum to 1"];
  if[0>cfg`blockqtyvol; '"validate: blockqtyvol must be zero or positive"];
  if[0>=cfg`quotelot; '"validate: quotelot must be positive"];
  if[0>=cfg`activitywindowseconds; '"validate: activitywindowseconds must be positive"];
  if[not (2=count cfg`activityclip)&(<). cfg`activityclip; '"validate: activityclip must be two ascending values"];
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
  .z.m.val.haskeys[cfg;`impactticks`impacthalflifeseconds`impactpermanent;"validate"];
  if[0>cfg`impactticks; '"validate: impactticks must be zero or positive"];
  if[0>=cfg`impacthalflifeseconds; '"validate: impacthalflifeseconds must be positive"];
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
  / The opening and closing auction prints frame the session (see
  / auction.prints), and one sequence number runs across quotes and
  / trades in time order. Trades arrive on the trade clock and execute
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
    ([]time:`timestamp$();price:`float$();qty:`long$();aggressor:`symbol$();cond:`symbol$();venue:`symbol$())];

  / the auction prints around the continuous session
  auctions:.z.m.auction.prints[cfg;quotes;sum trades`qty];
  trades:`time xasc trades,auctions;

  / one sequence number across quotes and trades in time order, a quote
  / before a trade at the same time (the quote is in force for the trade)
  seq:1+rank (quotes`time),trades`time;
  quotes:update seq:(count quotes)#seq from quotes;
  trades:update seq:(count quotes)_seq from trades;

  addsym:{[s;t] update `p#sym from `sym`time`seq xcols update sym:s from t};
  trades:addsym[cfg`sym;trades];
  $[cfg`generatequotes; `trade`quote!(trades;addsym[cfg`sym;quotes]); trades]
  };

/ ============================================================
/ CONFIGURATION: SCHEMA AND LAYERS
/ ============================================================
/ schema: key!(type;layer;group;description), see di.simconfig. The essential
/ layer is what a user sets for a stock; market keys come from the market
/ file (and any of them can be overridden on an instrument row); scenario
/ keys from the scenario row; run keys from the run dictionary (the market
/ file carries their defaults); baseintensity is derived by compose
schema:()!()
schema[`sym]:("S";`essential;`instrument;"ticker")
schema[`price]:("F";`essential;`instrument;"price at the open of the (first) day")
schema[`drift]:("F";`essential;`instrument;"expected annual return (annualized drift of the mid)")
schema[`vol]:("F";`essential;`instrument;"annual volatility of the close-to-close return")
schema[`tradesperday]:("J";`essential;`instrument;"average number of trades per day (long-run average over the day-to-day regime)")
schema[`openingtime]:("U";`market;`session;"market open time")
schema[`closingtime]:("U";`market;`session;"market close time")
schema[`tradingdays]:("J";`market;`session;"trading days per year, for annualizing vol and drift")
schema[`rngmodel]:("S";`market;`session;"random number source (`pseudo)")
schema[`ticksize]:("F";`market;`session;"minimum price increment; quotes sit on it (0.01 for US equities)")
schema[`printgrid]:("F";`market;`session;"fraction of a tick trade prints sit on (0.1: a tenth of a tick, for midpoint and improved prints)")
schema[`clock]:("S";`market;`session;"clock of the diffusion: `transaction (variance grows with activity: U-shaped vol, bursts) or `calendar (variance grows with time, flat vol)")
schema[`alpha]:("F";`market;`arrivals;"Hawkes excitation per event")
schema[`beta]:("F";`market;`arrivals;"Hawkes decay (must be > alpha); the branching ratio is alpha/beta")
schema[`profile]:("FL";`market;`arrivals;"intraday intensity profile: positive weights, one per equal bin of the session (13 half hours), interpolated between bin midpoints")
schema[`jumpburst]:("J";`market;`arrivals;"extra trade immigrants seeded by each jump (each with its usual cascade); 0 = none")
schema[`jumpburstminutes]:("F";`market;`arrivals;"mean delay in minutes of those immigrants after the jump")
schema[`quotespertrade]:("F";`market;`arrivals;"quote updates per trade on average: quotes arrive on their own Hawkes clock at this multiple of the trade intensity")
schema[`quotetradelink]:("F";`market;`arrivals;"share of the quote updates seeded by the trades (at Exp(beta) delays after them), between 0 and 1")
schema[`openauctionpct]:("F";`market;`auctions;"opening auction print as a fraction of the day's continuous volume (0 = none)")
schema[`closeauctionpct]:("F";`market;`auctions;"closing auction print as a fraction of the day's continuous volume (0 = none)")
schema[`qtymodel]:("S";`market;`sizes;"quantity model: `mixture (round lots, blocks and irregular lots), `lognormal or `constant")
schema[`avgqty]:("J";`market;`sizes;"average trade quantity (of the irregular lots under `mixture)")
schema[`qtyvol]:("F";`market;`sizes;"quantity log volatility (lognormal and the irregular lots of the mixture)")
schema[`roundlotshare]:("F";`market;`sizes;"mixture: share of trades that are round lots")
schema[`roundlots]:("JL";`market;`sizes;"mixture: the round-lot sizes")
schema[`roundlotweights]:("FL";`market;`sizes;"mixture: the weights of the round-lot sizes (sum to 1)")
schema[`blockshare]:("F";`market;`sizes;"mixture: share of trades that are blocks")
schema[`blockqty]:("J";`market;`sizes;"mixture: median block size")
schema[`blockqtyvol]:("F";`market;`sizes;"mixture: log volatility of block sizes")
schema[`spreadticks]:("F";`market;`quotes;"mean bid-ask spread in ticks through the day, at least 1 (the spread is 1 tick plus a Poisson excess)")
schema[`spreadopenmult]:("F";`market;`quotes;"spread multiplier at the open, decaying to the midday one")
schema[`spreadmidmult]:("F";`market;`quotes;"spread multiplier through the day")
schema[`spreadclosemult]:("F";`market;`quotes;"spread multiplier at the close, reached by the same decay")
schema[`spreaddecayminutes]:("F";`market;`quotes;"minutes over which the open and close spread multipliers decay toward the midday one (e-folding time)")
schema[`spreadactivity]:("F";`market;`quotes;"exponent of local quote activity (trailing window over its expected level) multiplying the mean spread; 0 = none")
schema[`activitywindowseconds]:("F";`market;`quotes;"seconds of the trailing window that measures local quote activity")
schema[`activityclip]:("FL";`market;`quotes;"lowest and highest activity ratio applied to the spread")
schema[`avgquotesize]:("J";`market;`quotes;"average quote size")
schema[`quotesizevol]:("F";`market;`quotes;"log volatility of quote sizes (lognormal around avgquotesize)")
schema[`quotelot]:("J";`market;`quotes;"quote sizes are multiples of this lot")
schema[`imbalancesignal]:("F";`market;`quotes;"log tilt of the quote sizes toward the side of the next mid move (bid larger before a rise); 0 = none")
schema[`sidepersistence]:("F";`market;`trades;"probability a trade's aggressor side repeats the previous trade's (0.5 = independent sides)")
schema[`midpointshare]:("F";`market;`trades;"share of trades printing at the midpoint")
schema[`improvementshare]:("F";`market;`trades;"share of trades printing inside the touch (price improvement)")
schema[`improvementtick]:("F";`market;`trades;"fraction of a tick an improved print sits inside the touch")
schema[`offexchangeshare]:("F";`market;`trades;"share of trades printed off-exchange (venue TRF)")
schema[`offexchangeinside]:("F";`market;`trades;"probability a midpoint or improved print is off-exchange")
schema[`venues]:("SL";`market;`trades;"lit venues (MIC codes) trades print on")
schema[`venueshares]:("FL";`market;`trades;"their shares of on-exchange trades (sum to 1)")
schema[`primaryvenue]:("S";`market;`trades;"primary listing venue (MIC), where the auction prints are; NYSE names override it on their instrument row")
schema[`impactticks]:("F";`market;`impact;"order-flow impact: ticks an average-size trade moves the mid in its direction (0 = none), scaled by sqrt(qty / mean size)")
schema[`impacthalflifeseconds]:("F";`market;`impact;"order-flow impact: seconds over which the transient part of a trade's impact halves")
schema[`impactpermanent]:("F";`market;`impact;"order-flow impact: share of a trade's impact that never decays, between 0 and 1")
schema[`ordervenues]:("SL";`market;`orders;"di.simorder: lit venues (MIC codes) the child orders are routed to")
schema[`ordervenueshares]:("FL";`market;`orders;"di.simorder: their routing shares (sum to 1)")
schema[`latencyms]:("F";`market;`orders;"di.simorder: milliseconds from a child's send to its arrival at the market (and half of it to its ack)")
schema[`sweepticks]:("J";`market;`orders;"di.simorder: ticks beyond the touch at which the rest of an aggressive child fills once the displayed size is taken")
schema[`maxreplaces]:("J";`market;`orders;"di.simorder: how many times a passive child re-pegs to the near touch when it moves away, before resting where it is")
schema[`jitter]:("F";`market;`orders;"di.simorder: random shift of each child's time, as a share of half the gap to its neighbours, between 0 and 1 (0 = exact schedule)")
schema[`capacity]:("S";`market;`orders;"di.simorder: A (agency) or P (principal), the default of the order rows")
schema[`algos]:("SL";`market;`orders;"di.simorder: the algo menu an order flow draws from (labels)")
schema[`algopacings]:("SL";`market;`orders;"di.simorder: each algo's pacing (even, frontloaded or arrival)")
schema[`algospreadcaptures]:("FL";`market;`orders;"di.simorder: each algo's share of aggressive children, between 0 and 1")
schema[`algourgencies]:("FL";`market;`orders;"di.simorder: each algo's urgency (arrival pacing only, null otherwise)")
schema[`algomaxpcts]:("FL";`market;`orders;"di.simorder: each algo's participation cap (arrival pacing only, null otherwise)")
schema[`norders]:("J";`market;`orders;"di.simorder: orders per instrument and day of a generated flow")
schema[`accounts]:("SL";`market;`orders;"di.simorder: the accounts a generated flow draws from")
schema[`sizepct]:("FL";`market;`orders;"di.simorder: lowest and highest order size of a generated flow, as a share of the day's volume")
schema[`windowminutes]:("FL";`market;`orders;"di.simorder: shortest and longest order window of a generated flow, in minutes")
schema[`childrenperminute]:("F";`market;`orders;"di.simorder: children per minute of window of a generated order (at least 5 children)")
schema[`orderimpactmodel]:("S";`market;`orders;"di.simorder: impact model of the child executions, participation (p^beta) or sqrtlaw")
schema[`orderimpacteta]:("F";`market;`orders;"di.simorder: impact coefficient, zero or positive (0 = no impact)")
schema[`orderimpactbeta]:("F";`market;`orders;"di.simorder: participation exponent, positive (0.5 is the square-root law)")
schema[`orderimpacthalflifeseconds]:("F";`market;`orders;"di.simorder: seconds over which the transient part of an execution's impact halves")
schema[`orderimpacttaperminutes]:("F";`market;`orders;"di.simorder: minutes before the close over which the impact shift falls linearly to zero")
schema[`orderimpactpermanent]:("F";`market;`orders;"di.simorder: share of each execution's impact that stays through the day, between 0 and 1")
schema[`volmult]:("F";`scenario;`scenario;"multiplies the instrument's vol (applied once by compose, then 1)")
schema[`volumemult]:("F";`scenario;`scenario;"multiplies the instrument's tradesperday (applied once by compose, then 1)")
schema[`spreadmult]:("F";`scenario;`scenario;"multiplies the mean spread in ticks (applied once by compose, then 1); the result must stay at least 1")
schema[`pricemodel]:("S";`scenario;`scenario;"price model (`gbm or `jump)")
schema[`jumpintensity]:("F";`scenario;`scenario;"jump model: jumps per day")
schema[`jumpmean]:("F";`scenario;`scenario;"jump model: mean of the log jump size")
schema[`jumpvol]:("F";`scenario;`scenario;"jump model: standard deviation of the log jump size")
schema[`overnightshare]:("F";`scenario;`calendar;"di.simcalendar: share of a trading day's variance that occurs overnight, between 0 and 1 (1 excluded)")
schema[`gapdayweight]:("F";`scenario;`calendar;"di.simcalendar: weight of each calendar day beyond the first in an overnight gap's variance")
schema[`regimepersistence]:("F";`scenario;`calendar;"di.simcalendar: AR(1) persistence of the day-level regimes, between 0 and 1 (1 excluded)")
schema[`regimecorr]:("F";`scenario;`calendar;"di.simcalendar: correlation of the daily shocks to the volatility and volume regimes, between -1 and 1")
schema[`volregimesd]:("F";`scenario;`calendar;"di.simcalendar: log spread of the volatility multiplier across days, normalized so the mean daily variance is the configured one")
schema[`volumeregimesd]:("F";`scenario;`calendar;"di.simcalendar: log spread of the volume multiplier across days")
schema[`tradingdate]:("D";`run;`run;"the day simulated (the market file carries a default)")
schema[`seed]:("J";`run;`run;"random seed (0N = unseeded; the market file carries a default)")
schema[`generatequotes]:("B";`run;`run;"return the quotes as well as the trades (they are always generated)")
schema[`baseintensity]:("F";`derived;`arrivals;"immigrant arrival rate before the profile and the cascades (trades/sec), derived by compose from tradesperday")

files:{[]
  / the shipped layer files: the US large-cap market, the instruments and the scenarios
  `market`instruments`scenarios!simconfig.path each ("markets/us_largecap.json";"instruments.csv";"scenarios.csv")
  };

loadmarket:{[filepath] simconfig.loadmarket[.z.m.schema;filepath]};
loadinstruments:{[filepath] simconfig.loadinstruments[.z.m.schema;filepath]};
loadscenarios:{[filepath] simconfig.loadscenarios[.z.m.schema;filepath]};

shapemean:{[cfg]
  / the average of the interpolated intraday shape over the session,
  / evaluated every second as the engine applies it
  n:`long$((`timespan$cfg`closingtime)-`timespan$cfg`openingtime)%nspersec;
  avg .z.m.shape[cfg;(0.5+til n)%n]
  };

intensityfor:{[cfg]
  / baseintensity from tradesperday: the trades the jump bursts are expected
  / to add are taken out, the branching ratio's cascades are taken out, and
  / the rest is spread over the session at the profile's average level
  n:cfg[`alpha]%cfg`beta;
  burst:$[`jump=cfg`pricemodel; cfg[`jumpintensity]*cfg[`jumpburst]%1-n; 0f];
  if[burst>=cfg`tradesperday;
    '"compose: the jump bursts are expected to add ",string[`long$burst]," trades a day, more than tradesperday ",string cfg`tradesperday];
  T:((`timespan$cfg`closingtime)-`timespan$cfg`openingtime)%nspersec;
  (cfg[`tradesperday]-burst)*(1-n)%T*.z.m.shapemean cfg
  };

derive:{[cfg]
  / the scenario multipliers applied once (then set to 1, so a saved config
  / is not multiplied again) and baseintensity derived
  cfg[`vol]:cfg[`vol]*cfg`volmult;
  cfg[`tradesperday]:`long$cfg[`tradesperday]*cfg`volumemult;
  cfg[`spreadticks]:cfg[`spreadticks]*cfg`spreadmult;
  cfg[`volmult`volumemult`spreadmult]:1 1 1f;
  if[1>cfg`spreadticks; '"compose: spreadticks after spreadmult must be at least 1"];
  cfg[`baseintensity]:.z.m.intensityfor cfg;
  cfg
  };

compose:{[market;instrument;scenario;run]
  / the flat configuration of a run: the layers composed (see di.simconfig),
  / the scenario multipliers applied and baseintensity derived
  / market: a market dictionary (loadmarket)
  / instrument: an instrument row (loadinstruments[...]`NVDA) or a dictionary
  /   with sym, price, drift, vol, tradesperday and any override
  / scenario: a scenario row (loadscenarios[...]`normal)
  / run: a dictionary with any of tradingdate, seed, generatequotes; the
  /   market file's defaults apply otherwise
  .z.m.derive simconfig.compose[.z.m.schema;market;instrument;scenario;run]
  };

loadconfig:{[filepath]
  / a saved flat configuration (see saveconfig). baseintensity is recomputed
  / from tradesperday when both are present and must agree, so a hand-edited
  / tradesperday cannot be ignored; it is derived when absent
  cfg:simconfig.loadconfig[.z.m.schema;filepath];
  if[not `tradesperday in key cfg; :cfg];
  b:.z.m.intensityfor cfg;
  if[`baseintensity in key cfg;
    if[1e-6<abs (cfg[`baseintensity]-b)%b;
      '"loadconfig: baseintensity ",string[cfg`baseintensity]," disagrees with tradesperday ",string[cfg`tradesperday]," (",string[b],")"]];
  cfg[`baseintensity]:b;
  cfg
  };

saveconfig:{[filepath;cfg] simconfig.saveconfig[filepath;cfg]};

quickwith:{[sym;price;drift;vol;tradesperday;tradingdate;overrides]
  / one day of one stock on a date from the five essential values, on the
  / shipped market and the normal scenario, with the market file's run
  / defaults (seed, quotes) unless overridden
  / overrides: a run dictionary, e.g. (enlist `seed)!enlist 7
  f:.z.m.files[];
  ins:`sym`price`drift`vol`tradesperday!(sym;price;drift;vol;tradesperday);
  run:((enlist `tradingdate)!enlist tradingdate),overrides;
  cfg:.z.m.compose[.z.m.loadmarket f`market;ins;.z.m.loadscenarios[f`scenarios]`normal;run];
  .z.m.run cfg
  };

quick:{[sym;price;drift;vol;tradesperday;tradingdate]
  / simtick.quick[`NVDA;215.0;0.08;0.45;500000;2026.08.18]
  .z.m.quickwith[sym;price;drift;vol;tradesperday;tradingdate;(`symbol$())!()]
  };

describe:{[]
  / the configuration schema as a table, the essential keys first
  simconfig.describe .z.m.schema
  };

/ export public interface
export:([run;quick;quickwith;compose;loadmarket;loadinstruments;loadscenarios;loadconfig;saveconfig;files;intensityfor;shapemean;arrivals;price;describe;schema])
