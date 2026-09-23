/ di.simtick - realistic intraday tick simulator

/ quote generation: maximum intermediate quote updates between trades
/ caps computation cost for large time gaps
maxquoteupdates:10

/ quote generation: random jitter range for initial quote offset (milliseconds)
/ adds realism by varying the pre-trade quote timing
initquotejitterms:100

/ price movement: fractional tick size for intermediate quote mid-price drift
/ controls how much the mid moves between trades (as fraction of price)
quoteticksize:0.0001

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

arrivals:{[cfg]
  / generate trade arrival times using a Hawkes process with exponential
  / kernel, simulated through its cluster representation (Hawkes and Oakes,
  / 1974): immigrants arrive as an inhomogeneous Poisson process of intensity
  / baseintensity*shape(t), and every event spawns Poisson(alpha/beta)
  / children at Exp(beta) delays, generation after generation until a
  / generation is empty. The union of all generations is the process
  / cfg: configuration dictionary
  / returns: ascending list of arrival times in seconds from session start
  /
  / This is exact: unlike Ogata thinning it needs no upper bound on the
  / intensity, so bursts are never capped (a fixed bound under-produced
  / arrivals by 5% at branching ratio 0.4 and by 3x at 0.9), and each
  / generation is a vector operation rather than a scan over candidates
  /
  / Required config keys:
  /   baseintensity, alpha, beta, openingtime, closingtime,
  /   openmult, midmult, closemult, transitionpoint

  / validate required config keys
  reqkeys:`baseintensity`alpha`beta`openingtime`closingtime;
  reqkeys,:`openmult`midmult`closemult`transitionpoint;
  .z.m.val.haskeys[cfg;reqkeys;"arrivals"];

  baseintensity:cfg`baseintensity;
  alpha:cfg`alpha;
  beta:cfg`beta;

  / session duration in seconds
  open:`timespan$cfg`openingtime;
  close:`timespan$cfg`closingtime;
  if[open>=close; '"arrivals: openingtime must be before closingtime"];
  duration:(close-open)%nspersec;

  / immigrants: a homogeneous Poisson process at the day's peak baseline,
  / thinned by shape/maxmult (exact, since shape never exceeds maxmult)
  maxmult:cfg[`openmult]|cfg[`midmult]|cfg`closemult;
  cand:.z.m.poisson[baseintensity*maxmult;duration];
  immigrants:cand where (count[cand]?1.0)<.z.m.shape[cfg;cand%duration]%maxmult;

  / offspring, generation by generation, until a generation is empty
  params:`alpha`beta`duration!(alpha;beta;duration);
  generations:.z.m.hawkes.children[params]\[{0<count x};immigrants];
  asc `float$raze generations
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

pricegbm:{[cfg;dts]
  / generate price path using geometric Brownian motion
  / cfg: config dict with `startprice`vol`drift`rngmodel
  / dts: list of time deltas in years (first element is time from session
  /   open to first trade - startprice represents the price AT session
  /   open, so this first interval is diffused like every other step,
  /   matching the technical paper's eq(17))
  / returns: list of prices corresponding to each time point
  eps:.z.m.rng.normal[count dts;cfg];
  cfg[`startprice]*prds .z.m.gbm[cfg`vol;cfg`drift;eps;dts]
  };

pricejump:{[cfg;dts]
  / generate price path using Merton jump-diffusion model
  / dS/S = μdt + σdW + J·dN where J is lognormal, N is Poisson
  / cfg: config dict with `startprice`vol`drift`tradingdays`jumpintensity`jumpmean`jumpvol`rngmodel
  / dts: list of time deltas in years (first element is time from session
  /   open to first trade - startprice represents the price AT session
  /   open, so this first interval is diffused/jumped like every other
  /   step, matching the technical paper's eq(17) treatment of GBM)
  / returns: list of prices corresponding to each time point
  n:count dts;

  / diffusion component
  eps:.z.m.rng.normal[n;cfg];
  diffusion:.z.m.gbm[cfg`vol;cfg`drift;eps;dts];

  / jump component: Poisson arrivals with lognormal sizes
  dtdays:dts*cfg`tradingdays;
  hasjump:(n?1.0)<1-exp neg cfg[`jumpintensity]*dtdays;
  epsj:.z.m.rng.normal[n;cfg];
  jumps:exp hasjump*(cfg[`jumpmean]+cfg[`jumpvol]*epsj);

  cfg[`startprice]*prds diffusion*jumps
  };

price:{[cfg;times]
  / generate prices for given arrival times
  / cfg: configuration dictionary
  / times: list of arrival times in seconds from session start
  / returns: list of prices corresponding to each arrival time
  /
  / Required config keys:
  /   openingtime, closingtime, tradingdays, pricemodel, startprice, vol, drift
  /   For jump model: jumpintensity, jumpmean, jumpvol

  / validate inputs
  .z.m.val.nonempty[times;"times";"price"];
  if[any times<0; '"price: times must be non-negative"];

  reqkeys:`openingtime`closingtime`tradingdays`pricemodel`startprice`vol`drift;
  .z.m.val.haskeys[cfg;reqkeys;"price"];

  / convert times to dt in years
  open:`timespan$cfg`openingtime;
  close:`timespan$cfg`closingtime;
  secsperyear:cfg[`tradingdays]*`long$(close-open)%nspersec;
  dts:deltas[times]%secsperyear;

  $[cfg[`pricemodel]=`jump; .z.m.pricejump[cfg;dts]; .z.m.pricegbm[cfg;dts]]
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

quote.generate:{[cfg;trades]
  / generate quote updates for trades (fully vectorized)
  / cfg: configuration dictionary
  / trades: trade table with `time`price columns
  / returns: quote table with `time`bid`ask`bidsize`asksize

  / validate inputs
  .z.m.val.hascols[trades;`time`price;"quote.generate"];

  n:count trades;
  if[n=0; :([]time:`timestamp$();bid:`float$();ask:`float$();bidsize:`long$();asksize:`long$())];

  tradetimes:trades`time;
  tradeprices:trades`price;

  / parameters
  basespread:cfg`basespread;
  pretradeoffset:cfg`pretradeoffset;
  quoteupdaterate:cfg`quoteupdaterate;
  avgquotesize:cfg`avgquotesize;

  / === 1. initial quote (before first trade) ===
  initoffset:`timespan$`long$nsperms*pretradeoffset+first 1?initquotejitterms;
  inittime:tradetimes[0]-initoffset;
  initprice:tradeprices[0];
  initspread:basespread*initprice*cfg`spreadopenmult;

  / === 2. pre-trade quotes (one per trade, vectorized) ===
  / times: random offset before each trade
  randoffsets:n?pretradeoffset;
  pretimes:tradetimes-`timespan$`long$(pretradeoffset+randoffsets)*nsperms;

  / clip: a pre-trade quote must never precede the PREVIOUS trade's own
  / execution. Without this, during tight Hawkes-clustered bursts (two
  / trades firing within ~pretradeoffset of each other), independent
  / per-trade random jitter can cause trade i+1's pre-trade quote
  / (centered on trade i+1's price) to land chronologically before
  / trade i even executes - corrupting the nearest-preceding-quote
  / lookup for trade i with a neighboring trade's price. Since
  / tradetimes is strictly ascending, clipping to the immediately
  / prior trade's time transitively guarantees this quote can never
  / precede ANY earlier trade, not just the adjacent one.
  / strict inequality: a non-strict clip (>=) can leave the quote
  / tied EXACTLY at the previous trade's timestamp, which still lets
  / ASOF-style nearest-quote lookups mismatch it to the wrong trade.
  / +1 nanosecond guarantees genuine ordering, not just a tie.
  prevtradetimes:(first tradetimes),-1_tradetimes;
  pretimes:pretimes|(prevtradetimes+`timespan$1);

  / spreads based on time of day (vectorized)
  / use pretimes (actual quote timestamps) not tradetimes - spread is evaluated
  / when the quote is posted, which is pretradeoffset ms before the trade
  prespreadmults:.z.m.quote.spreadmults[cfg;pretimes];
  prespreads:basespread*tradeprices*prespreadmults;
  prebids:tradeprices-prespreads%2;
  preasks:tradeprices+prespreads%2;

  / sizes (vectorized)
  prebidsizes:avgquotesize+`long$100*.z.m.rng.normal[n;cfg];
  preasksizes:avgquotesize+`long$100*.z.m.rng.normal[n;cfg];

  / === 3. intermediate quotes (vectorized) ===
  / only if we have at least 2 trades
  intresult:$[n>1;
    .z.m.quote.intermediates[cfg;tradetimes;tradeprices;basespread;pretradeoffset;quoteupdaterate;avgquotesize];
    `times`bids`asks`bidsizes`asksizes!5#enlist`float$()
  ];

  / === 4. combine all quotes ===
  alltimes:(enlist inittime),intresult[`times],pretimes;
  allbids:(enlist initprice-initspread%2),intresult[`bids],prebids;
  allasks:(enlist initprice+initspread%2),intresult[`asks],preasks;
  allbidsizes:(enlist avgquotesize),intresult[`bidsizes],prebidsizes;
  allasksizes:(enlist avgquotesize),intresult[`asksizes],preasksizes;

  / build table, enforce minimum size of 1, sort by time
  / round bid/ask to nearest cent consistent with trade price rounding
  / enforce bid < ask after rounding - tight spreads can collapse to bid=ask
  quotes:([]time:alltimes;bid:allbids;ask:allasks;bidsize:allbidsizes;asksize:allasksizes);
  quotes:update bidsize:1|bidsize,asksize:1|asksize,
    bid:0.01*`long$0.5+bid%0.01,
    ask:0.01*`long$0.5+ask%0.01 from quotes;
  quotes:update ask:bid+0.01 from quotes where bid>=ask;
  `time xasc quotes
  };

quote.intermediates:{[cfg;tradetimes;tradeprices;basespread;pretradeoffset;quoteupdaterate;avgquotesize]
  / generate all intermediate quotes across all gaps (fully vectorized)
  / returns dict with `times`bids`asks`bidsizes`asksizes
  n:count tradetimes;
  empty:`times`bids`asks`bidsizes`asksizes!5#enlist`float$();

  / gap times in ms between consecutive trades
  prevtimes:tradetimes til n-1;
  nexttimes:tradetimes 1+til n-1;
  prevprices:tradeprices til n-1;
  nextprices:tradeprices 1+til n-1;
  gaps:`long$(nexttimes-prevtimes)%nsperms;

  / number of intermediate quotes per gap (capped)
  nupdates:maxquoteupdates&`long$floor quoteupdaterate*gaps%1000;

  / filter gaps that are too short (need room for quotes before pretradeoffset)
  mingap:2*pretradeoffset;
  nupdates:nupdates*gaps>mingap;

  totint:sum nupdates;
  if[totint=0; :empty];

  / expand gap indices: create nupdates[i] copies of index i for each gap
  / e.g., if nupdates=(0 2 0 3), gapidx=(1 1 3 3 3)
  gapidx:raze {x#y}'[nupdates; til count nupdates];

  / position within each gap (0, 1, 2, ... for each gap)
  / e.g., if nupdates=(0 2 0 3), positions=(0 1 0 1 2)
  positions:raze til each nupdates;

  / gap-specific values expanded to each intermediate quote
  gapnupdates:nupdates gapidx;
  gapprevtimes:prevtimes gapidx;
  gapnexttimes:nexttimes gapidx;
  gapprevprices:prevprices gapidx;
  gapnextprices:nextprices gapidx;

  / times: evenly spaced within [prevtime, nexttime - pretradeoffset]
  availdurations:gapnexttimes-gapprevtimes-`timespan$`long$pretradeoffset*nsperms;
  fractions:(1+positions)%1+gapnupdates;
  inttimes:gapprevtimes+`timespan$`long$fractions*`long$availdurations;

  / prices: interpolate from prev toward next trade price, plus noise
  midprices:gapprevprices+fractions*(gapnextprices-gapprevprices);
  noise:quoteticksize*midprices*.z.m.rng.normal[totint;cfg];
  midprices+:noise;

  / spreads (vectorized across all intermediate quotes)
  intspreadmults:.z.m.quote.spreadmults[cfg;inttimes];
  spreadvar:1+0.1*abs .z.m.rng.normal[totint;cfg];
  intspreads:basespread*midprices*intspreadmults*spreadvar;
  intbids:midprices-intspreads%2;
  intasks:midprices+intspreads%2;

  / sizes
  intbidsizes:avgquotesize+`long$100*.z.m.rng.normal[totint;cfg];
  intasksizes:avgquotesize+`long$100*.z.m.rng.normal[totint;cfg];

  `times`bids`asks`bidsizes`asksizes!(inttimes;intbids;intasks;intbidsizes;intasksizes)
  };

quote.spreadmults:{[cfg;times]
  / spread multiplier based on time of day (vectorized)
  / cfg: config dict with spread parameters
  / times: list of timestamps
  / returns: list of spread multipliers (wider at open/close, tighter at midday)
  opentime:`timespan$cfg`openingtime;
  closetime:`timespan$cfg`closingtime;
  duration:closetime-opentime;

  / time of day as timespan
  timeofday:times-`timestamp$`date$times;

  / progress through trading day (0 to 1)
  progress:(timeofday-opentime)%duration;
  progress:0f|progress&1f;

  / vectorized conditional: early part vs late part of day
  earlyvals:cfg[`spreadopenmult]+(cfg[`spreadmidmult]-cfg`spreadopenmult)*2*progress;
  latevals:cfg[`spreadmidmult]+(cfg[`spreadclosemult]-cfg`spreadmidmult)*2*progress-0.5;
  early:progress<0.5;
  (early*earlyvals)+(not early)*latevals
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
  cfg
  };


run:{[cfg]
  / main simulation entry point
  / cfg: configuration dictionary (typically loaded via loadconfig)
  / returns: trade table if generatequotes=0b, else dict with `trade`quote
  /
  / Example:
  /   cfg:first loadconfig`:presets.csv
  /   trades:run[cfg]
  /   cfg[`generatequotes]:1b
  /   result:run[cfg]  / result`trade, result`quote
  cfg:.z.m.validate[cfg];

  / set seed for reproducibility (0N = no seed)
  if[not null cfg`seed; system "S ",string cfg`seed];

  / generate arrival times (seconds from open)
  arrs:.z.m.arrivals[cfg];
  n:count arrs;

  if[n=0;
    trades:([]sym:`symbol$();time:`timestamp$();price:`float$();qty:`long$());
    :$[cfg`generatequotes;
      `trade`quote!(trades;([]sym:`symbol$();time:`timestamp$();bid:`float$();ask:`float$();bidsize:`long$();asksize:`long$()));
      trades]
  ];

  / convert to timestamps
  basetime:cfg[`tradingdate]+`timespan$cfg`openingtime;
  times:basetime+`timespan$`long$arrs*nspersec;

  / generate prices and round to nearest cent (US equity tick size)
  prices:.z.m.price[cfg;arrs];
  prices:0.01*`long$0.5+prices%0.01;

  / generate quantities
  qtys:.z.m.qty.gen[n;cfg];

  trades:([]time:times;price:prices;qty:qtys);
  trades:`sym`time xcols update sym:cfg`sym from trades;
  trades:update `p#sym from trades;

  $[cfg`generatequotes;
    `trade`quote!(trades; 
      {[s;t] update `p#sym from `sym`time xcols update sym:s from t}[cfg`sym;.z.m.quote.generate[cfg;trades]]);
    trades]
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
schema[`basespread]:("F";"base bid-ask spread (fraction of price)")
schema[`spreadopenmult]:("F";"spread multiplier at open")
schema[`spreadmidmult]:("F";"spread multiplier at midday")
schema[`spreadclosemult]:("F";"spread multiplier at close")
schema[`pretradeoffset]:("J";"min ms before trade for quote")
schema[`quoteupdaterate]:("F";"quote updates per second")
schema[`avgquotesize]:("J";"average quote size")

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
  1!(.z.m.csvtypes;enlist csv) 0: filepath
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
