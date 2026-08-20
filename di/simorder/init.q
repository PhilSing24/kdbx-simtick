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
  if[0>=cfg`orderqty; '"validate: orderqty must be positive"];
  if[0>=cfg`numfills; '"validate: numfills must be positive"];
  if[not cfg[`side] in `BUY`SELL; '"validate: side must be BUY or SELL"];
  if[not cfg[`pacing] in `even`frontloaded; '"validate: pacing must be even or frontloaded"];
  if[not cfg[`spreadcapture] within 0 1; '"validate: spreadcapture must be between 0 and 1 (0=mid, 1=far touch)"];
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
  start:cfg`starttime;
  end:cfg`endtime;
  n:cfg`numfills;
  dur:`long$end-start;

  / fractions strictly between 0 and 1, evenly spaced
  fracs:(1+til n)%n+1;

  fracs:$[cfg[`pacing]=`even; fracs;
    cfg[`pacing]=`frontloaded; fracs xexp 3;
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

run:{[cfg;trades;quotes]
  / main simulation entry point
  / cfg: order configuration dictionary (typically loaded via loadconfig)
  / trades: market trades table for the day (from di.simtick/di.simcalendar)
  / quotes: market quotes table for the day (from di.simtick/di.simcalendar, generatequotes:1b)
  / returns: dict with `order`executions
  /
  / Example:
  /   cfg:first loadconfig`:presets.csv
  /   result:di.simtick.run[tickcfg]  / with generatequotes:1b
  /   ordresult:run[cfg;result`trade;result`quote]
  /   ordresult`order  / 1-row order table
  /   ordresult`executions  / child executions table
  cfg:.z.m.validate[cfg];
  .z.m.val.hascols[trades;`time`price`qty;"run"];
  .z.m.val.hascols[quotes;`time`bid`ask;"run"];

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
schema[`pacing]:          ("S";"fill scheduling: `even (patient) or `frontloaded (rushed)")
schema[`spreadcapture]:   ("F";"0=fills at mid (best), 1=fills at far touch (worst)")
schema[`seed]:            ("J";"random seed (0N = no seed)")

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
export:([run;schedule;sizing;pricing;buildorder;buildexecutions;loadconfig;describe])
