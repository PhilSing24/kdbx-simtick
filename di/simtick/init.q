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
  /   open to the first point - startprice is the price AT session open, so
  /   this first interval is diffused like every other step, matching the
  /   technical paper's eq(17); run samples the path on the quote clock,
  /   whose first point is the open itself)
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

quote.generate:{[cfg;times;mids]
  / quote table from the mid path sampled on the quote clock
  / cfg: config dict with `basespread`spreadopenmult`spreadmidmult`spreadclosemult`avgquotesize`ticksize`rngmodel
  / times: quote timestamps, ascending, the first at the session open
  / mids: mid price at each time (the price path sampled on the quote clock)
  / returns: quote table `time`bid`ask`bidsize`asksize; bid and ask on the
  /   tick grid, bid < ask
  n:count times;
  ticksize:cfg`ticksize;

  / spread as a fraction of the mid, wider at open and close, with a little noise
  spreadvar:1+0.1*abs .z.m.rng.normal[n;cfg];
  spreads:cfg[`basespread]*mids*.z.m.quote.spreadmults[cfg;times]*spreadvar;

  / bid and ask on the tick grid; a spread that collapses in rounding becomes one tick
  bid:ticksize*`long$0.5+(mids-spreads%2)%ticksize;
  ask:ticksize*`long$0.5+(mids+spreads%2)%ticksize;
  ask:ask|bid+ticksize;

  bidsize:1|cfg[`avgquotesize]+`long$100*.z.m.rng.normal[n;cfg];
  asksize:1|cfg[`avgquotesize]+`long$100*.z.m.rng.normal[n;cfg];
  ([]time:times;bid:bid;ask:ask;bidsize:bidsize;asksize:asksize)
  };

trade.generate:{[cfg;times;quotes]
  / trades against the quote in force at their time: a buyer-initiated trade
  / takes the ask, a seller-initiated one the bid, the aggressor side following
  / a persistent sign process; a share of trades prints at the midpoint and a
  / share a tenth of a tick inside the touch (price improvement)
  / cfg: config dict with `sidepersistence`midpointshare`improvementshare`ticksize
  /   and the quantity model keys
  / times: trade timestamps, ascending, none before the first quote
  / quotes: quote table (see quote.generate)
  / returns: trade table `time`price`qty`aggressor, aggressor `B (buyer-
  /   initiated) or `S; prices on the tenth-of-a-tick grid
  n:count times;
  idx:quotes[`time] bin times;
  bid:quotes[`bid] idx;
  ask:quotes[`ask] idx;
  mid:0.5*bid+ask;

  / aggressor signs: a Markov chain, each sign repeating the previous one with
  / probability sidepersistence (lag-1 autocorrelation 2*sidepersistence-1)
  flips:(n?1.0)>cfg`sidepersistence;
  flips[0]:0b;
  sign:(1-2*first 1?2)*1-2*(sums flips) mod 2;

  / where the trade prints: touch, midpoint or a tenth of a tick inside the touch
  u:n?1.0;
  atmid:u<cfg`midpointshare;
  improved:(not atmid)&u<cfg[`midpointshare]+cfg`improvementshare;
  touch:?[sign>0;ask;bid];
  price:?[atmid;mid;?[improved;touch-sign*0.1*cfg`ticksize;touch]];
  grid:0.1*cfg`ticksize;
  price:grid*floor 0.5+price%grid;

  ([]time:times;price:price;qty:.z.m.qty.gen[n;cfg];aggressor:?[sign>0;`B;`S])
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
  reqkeys:`ticksize`basespread`spreadopenmult`spreadmidmult`spreadclosemult`avgquotesize;
  reqkeys,:`quotespertrade`sidepersistence`midpointshare`improvementshare;
  .z.m.val.haskeys[cfg;reqkeys;"validate"];
  if[0>=cfg`ticksize; '"validate: ticksize must be positive"];
  if[0>=cfg`quotespertrade; '"validate: quotespertrade must be positive"];
  if[not cfg[`sidepersistence] within 0 1; '"validate: sidepersistence must be between 0 and 1"];
  if[not all cfg[`midpointshare`improvementshare] within 0 1;
    '"validate: midpointshare and improvementshare must be between 0 and 1"];
  if[1<cfg[`midpointshare]+cfg`improvementshare;
    '"validate: midpointshare and improvementshare must not exceed 1 together"];
  cfg
  };


run:{[cfg]
  / main simulation entry point
  / cfg: configuration dictionary (typically loaded via loadconfig)
  / returns: trade table if generatequotes=0b, else dict with `trade`quote
  /
  / quotes come first: quote updates arrive on their own Hawkes clock at
  / quotespertrade times the trade intensity (same clustering), starting
  / with a quote at the open, and the price path is sampled on that clock
  / as the mid. Trades then arrive on the trade clock and execute against
  / the quote in force (see trade.generate), so every trade sits inside its
  / prevailing quote and carries an aggressor side
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

  / quote clock (seconds from open) and the mid path on it
  quotearrs:0f,.z.m.arrivals[@[cfg;`baseintensity;*;cfg`quotespertrade]];
  mids:.z.m.price[cfg;quotearrs];
  quotes:.z.m.quote.generate[cfg;basetime+`timespan$`long$quotearrs*nspersec;mids];

  / trade clock, then trades against the quote in force
  arrs:.z.m.arrivals[cfg];
  trades:$[count arrs;
    .z.m.trade.generate[cfg;basetime+`timespan$`long$arrs*nspersec;quotes];
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
schema[`avgquotesize]:("J";"average quote size")
schema[`ticksize]:("F";"minimum price increment; quotes are rounded to it, trades to a tenth of it (0.01 for US equities)")
schema[`quotespertrade]:("F";"quote updates per trade on average: quotes arrive on their own Hawkes clock at this multiple of the trade intensity")
schema[`sidepersistence]:("F";"probability a trade's aggressor side repeats the previous trade's (0.5 = independent sides)")
schema[`midpointshare]:("F";"share of trades printing at the midpoint")
schema[`improvementshare]:("F";"share of trades printing a tenth of a tick inside the touch")

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
