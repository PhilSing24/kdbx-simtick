/ di.simorder - order execution simulator for TCA demo
/ Generates a parent order + child fills against an existing trades/quotes
/ market (from di.simtick / di.simcalendar), with configurable execution
/ quality (pacing, spread capture) to demonstrate good vs. bad execution.


val.haskeys:{[cfg;reqkeys;fn]
  / check config dictionary has all required keys
  / cfg: configuration dictionary
  / reqkeys: symbol list of required keys
  / fn: function name string for error context
  if[count missing:reqkeys where not reqkeys in key cfg;
    '"(",fn,"): missing config keys - ",", " sv string missing];
  };

val.hascols:{[t;reqcols;fn]
  / check table has required columns
  / t: table to check
  / reqcols: symbol list of required columns
  / fn: function name string for error context
  if[not all reqcols in cols t;
    '"(",fn,"): table missing columns - ",", " sv string reqcols where not reqcols in cols t];
  };


/ ============================================================
/ VALIDATION
/ ============================================================

validate:{[cfg]
  / validate order configuration dictionary
  / cfg: configuration dictionary
  / returns: cfg if valid, throws error otherwise

  reqkeys:`orderid`sym`side`orderqty`starttime`endtime;
  reqkeys,:`numfills`pacing`spreadcapture`seed;
  .z.m.val.haskeys[cfg;reqkeys;"validate"];

  if[cfg[`starttime]>=cfg`endtime; '"validate: starttime must be before endtime"];
  if[(`date$cfg`starttime)<>`date$cfg`endtime; '"validate: starttime and endtime must fall on the same day"];
  if[0>=cfg`orderqty; '"validate: orderqty must be positive"];
  if[0>=cfg`numfills; '"validate: numfills must be positive"];
  if[not cfg[`side] in `BUY`SELL; '"validate: side must be BUY or SELL"];
  if[not cfg[`pacing] in `even`frontloaded`arrival; '"validate: pacing must be even, frontloaded or arrival"];
  if[not cfg[`spreadcapture] within 0 1; '"validate: spreadcapture must be between 0 and 1 (0=mid, 1=far touch)"];
  if[`arrival=cfg`pacing;
    .z.m.val.haskeys[cfg;`urgency`maxpct;"validate"];
    if[not 0<cfg`urgency; '"validate: urgency must be positive for arrival pacing"];
    if[not (0<cfg`maxpct)&1>cfg`maxpct; '"validate: maxpct must be between 0 and 1, both excluded, for arrival pacing"]];
  cfg
  };


/ ============================================================
/ SCHEDULING - when each child fill happens
/ ============================================================

schedule:{[cfg]
  / generate fill timestamps within [starttime,endtime)
  / cfg: config dict with `starttime`endtime`numfills`pacing
  / returns: list of nanosecond-precision timestamps, ascending
  /
  / pacing `even: uniformly spaced (patient, low-impact execution)
  / pacing `frontloaded: skewed toward starttime (rushed, high-impact execution)
  / pacing `arrival: one child per equal interval of the window, at the interval's midpoint; the urgency
  /   shows in the sizes (see .z.m.arrivalsizes), as a slicing algo sends a child every interval
  start:cfg`starttime;
  end:cfg`endtime;
  n:cfg`numfills;
  dur:`long$end-start;

  / fractions strictly between 0 and 1, evenly spaced
  fracs:(1+til n)%n+1;

  fracs:$[cfg[`pacing]=`even; fracs;
    cfg[`pacing]=`frontloaded; fracs xexp 3;
    cfg[`pacing]=`arrival; (0.5+til n)%n;
    '"schedule: unknown pacing - ",string cfg`pacing];

  start+`timespan$`long$fracs*dur
  };


/ ============================================================
/ SIZING - how big each child fill is
/ ============================================================

sizing:{[cfg;trades;filltimes]
  / size each fill according to the order's pacing style, normalized to
  / sum exactly to orderqty
  / cfg: config dict with `orderqty`starttime`pacing
  / trades: market trades table (time-sorted) for the day
  / filltimes: scheduled fill timestamps from .z.m.schedule
  / returns: list of fill quantities (long), same length as filltimes, sums to orderqty
  /
  / pacing `even: proportional to real market volume in each fill's bucket
  /   (patient participation - trade more when the market is trading more)
  / pacing `frontloaded: weighted toward the earliest fills regardless of
  /   market volume (urgency - dump size early, ignoring available liquidity;
  /   this is what actually makes frontloaded pacing costly, not just timing)
  qty:cfg`orderqty;
  n:count filltimes;

  weights:$[cfg[`pacing]=`even;
    [
      bucketstarts:(enlist cfg`starttime),-1_filltimes;
      bucketends:filltimes;
      ttimes:trades`time;
      tqty:`float$trades`qty;
      csum:sums tqty;
      / cumulative market volume traded at/before time x
      volat:{[ttimes;csum;x] i:ttimes bin x; $[i<0; 0f; csum i]};
      bucketvol:volat[ttimes;csum] each bucketends;
      bucketvol-:volat[ttimes;csum] each bucketstarts;
      bucketvol:0f|bucketvol;  / guard against edge-case negatives
      $[0=sum bucketvol; n#1f; bucketvol]  / fallback to even split if no volume
    ];
    cfg[`pacing]=`frontloaded;
      / decreasing weights: first fill weighted heaviest, last fill lightest
      (n-til n) xexp 2;
    cfg[`pacing]=`arrival;
      / quantities, not weights: the urgency's trajectory under the participation cap
      .z.m.arrivalsizes[cfg;trades;n];
    '"sizing: unknown pacing - ",string cfg`pacing
  ];

  raw:qty*weights%sum weights;
  sizes:1|`long$0.5+raw;  / round, then enforce minimum size of 1 per fill

  / floor may have pushed the total off orderqty (e.g. a tiny tail weight
  / rounds to 0 then gets floored to 1) - fix by dumping the residual onto
  / whichever fill has the most weight/room to absorb it, so the total is
  / guaranteed to equal orderqty exactly regardless of pacing/weights
  resid:qty-sum sizes;
  sizes[first idesc weights]+:resid;
  1|sizes
  };


/ ============================================================
/ ARRIVAL PACING - an implementation shortfall trajectory under a participation cap
/ ============================================================

trajectory:{[urgency;n]
  / share of the order still to trade at each boundary of n equal intervals of the window, from the
  / Almgren-Chriss solution sinh(k(1-t))/sinh(k), k the urgency (kappa x horizon): trading faster early
  / lowers timing risk at the cost of impact. At urgency 1 half the order is done at 44% of the window,
  / at 2 at 32%, at 3 at 23%; as urgency tends to 0 the trajectory is a straight line
  / urgency: positive float
  / n: number of intervals
  / returns: n+1 floats, from 1 at starttime down to 0 at endtime
  t:(til n+1)%n;
  sinh:{0.5*(exp x)-exp neg x};
  $[urgency<1e-6; 1-t; sinh[urgency*1-t]%sinh urgency]
  };

capped:{[want;cap]
  / quantity per interval under a cap: each interval takes what it wants plus any shortfall carried from
  / earlier intervals, up to its cap, and carries the rest forward (an algo behind schedule catches up
  / when liquidity allows). What is still left at the end goes into earlier intervals' unused capacity;
  / only when the window's whole capacity is too small for the order is the cap exceeded, every interval
  / taking the excess in proportion to its capacity
  / want: wanted quantity per interval (floats)
  / cap: capacity per interval (floats)
  / returns: quantity per interval (floats), summing to sum want
  step:{[st;wc] w:st[1]+wc 0; t:w&wc 1; (t;w-t)};
  r:step\[(0f;0f);flip (want;cap)];
  x:r[;0];
  left:last r[;1];
  room:cap-x;
  if[(left>0)&0<sum room; add:left&sum room; x+:add*room%sum room; left-:add];
  if[left>0; x+:left*$[0<sum cap; cap%sum cap; (count x)#1%count x]];
  x
  };

arrivalsizes:{[cfg;trades;n]
  / child quantities for arrival pacing: the order follows its urgency's trajectory over n equal intervals
  / of the window, and its share of each interval's volume, own / (own + market), stays within maxpct
  / cfg: config dict with `orderqty`starttime`endtime`urgency`maxpct
  / trades: market trades table (time-sorted) for the day
  / n: number of intervals, one child each (numfills)
  / returns: float quantities per interval, summing to orderqty
  start:cfg`starttime;
  dur:`long$cfg[`endtime]-start;
  bounds:start+`timespan$`long$dur*(til n+1)%n;
  ttimes:trades`time;
  csum:sums `float$trades`qty;
  volat:{[ttimes;csum;x] i:ttimes bin x; $[i<0; 0f; csum i]};
  vol:0f|1_deltas volat[ttimes;csum] each bounds;
  want:cfg[`orderqty]*neg 1_deltas .z.m.trajectory[cfg`urgency;n];
  m:cfg`maxpct;
  .z.m.capped[want;vol*m%1-m]
  };


/ ============================================================
/ MARKET IMPACT - transient impact of executions on the market they trade in
/ ============================================================

validateimpact:{[icfg]
  / validate a market impact configuration dictionary
  / icfg: `eta`beta`halflife`taper`closetime (see impact)
  / returns: icfg if valid, throws error otherwise
  .z.m.val.haskeys[icfg;`eta`beta`halflife`taper`closetime;"validateimpact"];
  if[not 0<=icfg`eta; '"validateimpact: eta must be zero or positive"];
  if[not 0<icfg`beta; '"validateimpact: beta must be positive"];
  if[not -16h=type icfg`halflife; '"validateimpact: halflife must be a timespan"];
  if[not 0D<icfg`halflife; '"validateimpact: halflife must be positive"];
  if[not -16h=type icfg`taper; '"validateimpact: taper must be a timespan"];
  if[0D>icfg`taper; '"validateimpact: taper must be zero or positive"];
  if[not -16h=type icfg`closetime; '"validateimpact: closetime must be a timespan (time of day)"];
  icfg
  };

dailyvol:{[quotes]
  / daily volatility of the mid as a fraction, from the returns of the last mid in each 5-minute bucket
  / quotes: one day's quotes for one instrument, `time`bid`ask
  / returns: float
  m:value exec last 0.5*bid+ask by 5 xbar time.minute from quotes;
  r:1_ -1+ratios m;
  $[1<count r; (dev r)*sqrt count r; 0f]
  };

childimpact:{[icfg;execs;trades;sigma]
  / temporary impact of each child execution, as a fraction of the price: eta x sigma x p^beta, with p the
  / child's participation, own / (own + market), in the market volume of an interval of the child's length
  / centred on its time (for arrival pacing, the interval the child was sized in)
  / execs: `time`qty`interval, interval a timespan
  / trades: the day's trades for the instrument, `time`qty, time-sorted
  / sigma: daily volatility as a fraction (see dailyvol)
  / returns: float fraction per execution
  csum:0f,sums `float$trades`qty;
  half:`timespan$(`long$execs`interval) div 2;
  vol:(csum trades[`time] binr execs[`time]+half)-csum trades[`time] binr execs[`time]-half;
  own:`float$execs`qty;
  p:0f^own%own+vol;
  icfg[`eta]*sigma*xexp[p;icfg`beta]
  };

shiftat:{[icfg;times;moves]
  / the market's price shift in currency at each of times (ascending, one day): the sum of every earlier or
  / simultaneous child's signed impact, each halving every halflife and ignored after 20 halflives (below a
  / millionth of it), tapered linearly to zero over the taper before closetime and rounded to whole cents,
  / so bid and ask move by the same tick and nothing is left at the close
  / icfg: impact configuration (see validateimpact)
  / times: ascending timestamps of one day
  / moves: `time`amount, amount in currency, positive pushing the price up
  / returns: float shift per time
  n:count times;
  if[0=n; :`float$()];
  h:`float$`long$icfg`halflife;
  add:{[times;h;d;t;a]
    j:(times binr t)_til times binr t+`timespan$`long$20*h;
    @[d;j;+;a*xexp[0.5;(`float$`long$times[j]-t)%h]]};
  d:add[times;h]/[n#0f;moves`time;moves`amount];
  close:(`date$first times)+icfg`closetime;
  w:$[0D<icfg`taper; 0f|1f&(`float$`long$close-times)%`float$`long$icfg`taper; `float$times<close];
  0.01*`long$w*d%0.01
  };

impact:{[icfg;execs;trades;quotes]
  / the market after the transient impact of child executions, for one instrument and one day. Quotes and
  / prints move together by the shift in force (see shiftat), and a quote is added at each execution time,
  / a copy of the quote in force then carrying the moved level, so an execution priced against the quote
  / at its time sits inside it. Volumes, sizes and the order of events are unchanged; with eta 0 or no
  / executions the market is returned as it is.
  / icfg: impact configuration (see validateimpact)
  / execs: `time`side`qty`interval, every child execution of every order in the instrument that day
  / trades: `time`price`qty and any other columns (kept), time-sorted
  / quotes: `time`bid`ask and any other columns (kept), time-sorted
  / returns: `trades`quotes!(trades; quotes with the added rows)
  icfg:.z.m.validateimpact icfg;
  .z.m.val.hascols[execs;`time`side`qty`interval;"impact"];
  if[(0=count execs) or 0=icfg`eta; :`trades`quotes!(trades;quotes)];
  sigma:.z.m.dailyvol quotes;
  frac:.z.m.childimpact[icfg;execs;trades;sigma];
  q0:aj[`time;([] time:execs`time);quotes];
  f:`time xasc ([] time:execs`time; amount:frac*(0.5*q0[`bid]+q0`ask)*?[execs[`side]=`BUY;1f;-1f]);
  / a quote at each execution time, a copy of the one in force, placed after any quote at the same time
  added:(cols quotes)#aj[`time;([] time:distinct f`time);quotes];
  q:`time`isadded xasc (update isadded:0b from quotes),update isadded:1b from added;
  dq:.z.m.shiftat[icfg;q`time;f];
  q:delete isadded from update bid:bid+dq, ask:ask+dq from q;
  / each print moves with the quote in force at its time, so it keeps its place inside that quote
  t:aj[`time;trades;([] time:q`time; shift:dq)];
  t:delete shift from update price:price+0f^shift from t;
  `trades`quotes!(t;q)
  };


/ ============================================================
/ PRICING - where each child fill happens vs. the spread
/ ============================================================

pricing:{[cfg;quotes;filltimes]
  / price each fill relative to the prevailing quote at fill time
  / cfg: config dict with `side`spreadcapture
  / quotes: market quotes table (time-sorted) for the day
  / filltimes: scheduled fill timestamps from .z.m.schedule
  / returns: list of fill prices, rounded to nearest cent
  /
  / spreadcapture 0 = fills at mid (best possible, no spread cost)
  / spreadcapture 1 = fills at the far touch (worst - fully crosses the spread)
  qtimes:quotes`time;
  idx:0|qtimes bin filltimes;

  bid:quotes[`bid] idx;
  ask:quotes[`ask] idx;
  mid:0.5*bid+ask;
  cap:cfg`spreadcapture;

  prices:$[cfg[`side]=`BUY; mid+cap*ask-mid;
    cfg[`side]=`SELL; mid-cap*mid-bid;
    '"pricing: unknown side - ",string cfg`side];

  0.01*`long$0.5+prices%0.01
  };


/ ============================================================
/ ASSEMBLY
/ ============================================================

buildorder:{[cfg;quotes]
  / build the single-row parent order table, including arrival price
  / cfg: order config dict
  / quotes: market quotes table for the day
  / returns: 1-row order table
  qtimes:quotes`time;
  idx:0|qtimes bin cfg`starttime;
  bid:quotes[`bid] idx;
  ask:quotes[`ask] idx;
  arrivalprice:0.5*bid+ask;

  ([]orderid:enlist cfg`orderid;
    sym:enlist cfg`sym;
    side:enlist cfg`side;
    orderqty:enlist cfg`orderqty;
    starttime:enlist cfg`starttime;
    endtime:enlist cfg`endtime;
    arrivalprice:enlist arrivalprice)
  };

buildexecutions:{[cfg;trades;quotes]
  / build the child fills table
  / cfg: order config dict
  / trades: market trades table for the day
  / quotes: market quotes table for the day
  / returns: fills table, one row per child fill
  filltimes:.z.m.schedule[cfg];
  sizes:.z.m.sizing[cfg;trades;filltimes];
  prices:.z.m.pricing[cfg;quotes;filltimes];

  ([]orderid:cfg[`orderid];
    execid:1+til count filltimes;
    sym:cfg[`sym];
    side:cfg[`side];
    time:filltimes;
    price:prices;
    qty:sizes)
  };


/ ============================================================
/ MAIN ENTRY POINT
/ ============================================================

marketday:{[cfg;t;name]
  / the rows of a market table for the order's instrument and day
  / cfg: order config dict with `sym`starttime
  / t: trades or quotes table with `sym`time
  / name: table name for error context
  / returns: rows for cfg`sym on the day of starttime, time-sorted; throws if none
  d:`date$cfg`starttime;
  r:`time xasc select from t where sym=cfg`sym,d=`date$time;
  if[0=count r;
    '"run: no ",name," for ",string[cfg`sym]," on ",string[d]," (",name," cover ",
      (", " sv string distinct t`sym)," on ",(", " sv string distinct `date$t`time),")"];
  r
  };


run:{[cfg;trades;quotes]
  / main simulation entry point
  / cfg: order configuration dictionary (typically loaded via loadconfig)
  / trades: market trades table with `sym`time`price`qty (from di.simtick/di.simcalendar)
  / quotes: market quotes table with `sym`time`bid`ask (from di.simtick/di.simcalendar, generatequotes:1b)
  /   both may hold other instruments and days; only the order's are used
  / returns: dict with `order`executions
  /
  / throws when the tables have no rows for the order's sym on the day of
  / starttime, or when starttime precedes the first quote of that day (no
  / quote in force for the arrival price). Without these checks an order on
  / another day was priced silently off the first or last quote of the day.
  /
  / Example:
  /   cfg:first loadconfig`:presets.csv
  /   result:di.simtick.run[tickcfg]  / with generatequotes:1b
  /   ordresult:run[cfg;result`trade;result`quote]
  /   ordresult`order  / 1-row order table
  /   ordresult`executions  / child executions table
  cfg:.z.m.validate[cfg];
  .z.m.val.hascols[trades;`sym`time`price`qty;"run"];
  .z.m.val.hascols[quotes;`sym`time`bid`ask;"run"];

  / keep only the order's instrument and day, so tables holding several
  / instruments or days (di.simcalendar in memory, di.simbasket) can be
  / passed whole, and throw when the market does not cover the order
  trades:.z.m.marketday[cfg;trades;"trades"];
  quotes:.z.m.marketday[cfg;quotes;"quotes"];
  if[cfg[`starttime]<first quotes`time;
    '"run: starttime ",string[cfg`starttime]," is before the first quote at ",string first quotes`time];

  if[not null cfg`seed; system "S ",string cfg`seed];

  order:.z.m.buildorder[cfg;quotes];
  executions:.z.m.buildexecutions[cfg;trades;quotes];
  `order`executions!(order;executions)
  };


/ ============================================================
/ CONFIGURATION SCHEMA
/ ============================================================

/ configuration schema: column name -> (type; description)
/ type codes: S=symbol, P=timestamp, F=float, J=long, B=boolean
schema:()!()
schema[`name]:            ("S";"preset name (key)")
schema[`orderid]:         ("S";"unique order identifier")
schema[`sym]:             ("S";"ticker symbol - must match the trades/quotes tables")
schema[`side]:            ("S";"BUY or SELL")
schema[`orderqty]:        ("J";"total order quantity")
schema[`starttime]:       ("P";"execution window start (timestamp, matches trades/quotes date)")
schema[`endtime]:         ("P";"execution window end (timestamp)")
schema[`numfills]:        ("J";"number of child fills to generate")
schema[`pacing]:          ("S";"fill scheduling: `even (patient), `frontloaded (rushed) or `arrival (urgency trajectory under a participation cap)")
schema[`spreadcapture]:   ("F";"0=fills at mid (best), 1=fills at far touch (worst)")
schema[`seed]:            ("J";"random seed (0N = no seed)")
schema[`urgency]:         ("F";"arrival pacing only: Almgren-Chriss urgency (kappa x horizon), positive; higher trades earlier")
schema[`maxpct]:          ("F";"arrival pacing only: participation cap per interval, own/(own+market), between 0 and 1")

/ derive type string from schema
csvtypes:raze first each value schema

loadconfig:{[filepath]
  / load preset order configurations from CSV file
  / filepath: file handle to CSV (e.g., `:presets.csv)
  / returns: keyed table with preset name as key
  /
  / Example:
  /   cfgs:loadconfig`:di/simorder/presets.csv
  /   cfg:cfgs`good
  /   run[cfg;trades;quotes]
  if[not -11h=type filepath; '"loadconfig: filepath must be a file handle"];
  1!(.z.m.csvtypes;enlist csv) 0: filepath
  };

describe:{[]
  / return configuration schema as a table
  / Example:
  /   simorder.describe[]
  ([]param:key .z.m.schema;typ:first each value .z.m.schema;description:last each value .z.m.schema)
  };

/ export public interface
export:([run;marketday;schedule;sizing;trajectory;capped;validateimpact;dailyvol;childimpact;shiftat;impact;pricing;buildorder;buildexecutions;loadconfig;describe])
