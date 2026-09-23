/ di.simcalendar - multi-day tick simulation over a trading calendar
/ Runs di.simtick day after day: each day opens at the previous close moved
/ by an overnight return, and the days are summarized in a table

/ load simtick module
simtick:use`di.simtick


val.haskeys:{[cfg;reqkeys;fn]
  / check config dictionary has all required keys
  / cfg: configuration dictionary
  / reqkeys: symbol list of required keys
  / fn: function name string for error context
  if[count missing:reqkeys where not reqkeys in key cfg;
    '"(",fn,"): missing config keys - ",", " sv string missing];
  };

rng.normal:{[n]
  / n standard normal variates (Box-Muller), from the process's seeded stream
  m:2*(n+1) div 2;
  u:2 0N#1-m?1.0;
  r:sqrt -2f*log u 0;
  theta:2f*acos[-1]*u 1;
  n#(r*cos theta),r*sin theta
  };


/ ============================================================
/ VALIDATION
/ ============================================================

validate:{[calendar]
  / validate calendar input
  / calendar: list of dates
  / returns: calendar if valid, throws error otherwise
  if[not 14h=type calendar; '"validate: calendar must be a date list"];
  if[0=count calendar; '"validate: calendar cannot be empty"];
  if[count[calendar]<>count distinct calendar; '"validate: calendar contains duplicates"];
  if[not calendar~asc calendar; '"validate: calendar must be sorted ascending"];
  calendar
  };

validatecfg:{[cfg]
  / validate the calendar keys of a configuration (a simtick config joined
  / with a row of this module's presets, see loadconfig)
  / cfg: configuration dictionary
  / returns: cfg if valid, throws error otherwise
  .z.m.val.haskeys[cfg;`overnightshare`gapdayweight`vol`tradingdays`startprice`seed;"validatecfg"];
  if[not (0<=cfg`overnightshare)&1>cfg`overnightshare; '"validatecfg: overnightshare must be between 0 and 1, 1 excluded"];
  if[0>cfg`gapdayweight; '"validatecfg: gapdayweight must be zero or positive"];
  cfg
  };


/ ============================================================
/ OVERNIGHT GAP
/ ============================================================

overnight:{[cfg;ndays]
  / the log return between a close and the next open, over a gap of ndays
  / calendar days: normal, with variance overnightshare of one trading day's
  / (vol^2/tradingdays) times 1+gapdayweight*(ndays-1), so a weekend adds
  / less than three nights' worth, and mean minus half the variance (no
  / drift overnight, the open is a martingale of the close)
  / cfg: config dict with `overnightshare`gapdayweight`vol`tradingdays
  / ndays: calendar days from the previous trading day, at least 1
  / returns: float log return
  v:cfg[`overnightshare]*(cfg[`vol]*cfg`vol)%cfg`tradingdays;
  v*:1+cfg[`gapdayweight]*ndays-1;
  (neg 0.5*v)+sqrt[v]*first .z.m.rng.normal 1
  };


/ ============================================================
/ CORE SIMULATION
/ ============================================================

daycfg:{[cfg;date;startprice]
  / the simtick config for one day: its date and open price, the intraday
  / vol reduced to the share left after the overnight one, so the
  / close-to-close vol is the configured vol, and no reseed (the random
  / stream flows across the days from the seed set once in run)
  / cfg: configuration dictionary
  / date: trading date
  / startprice: price at the open
  / returns: config dict for simtick.run
  dc:cfg;
  dc[`tradingdate]:date;
  dc[`startprice]:startprice;
  dc[`vol]:cfg[`vol]*sqrt 1-cfg`overnightshare;
  dc[`seed]:0N;
  dc
  };

persist:{[dst;date;result]
  / write one day's tables to the date partition of dst
  daypath:hsym`$string[dst],"/",string date;
  $[99h=type result;
    [
      .Q.dd[daypath;`$"trade/"] set .Q.en[dst] result`trade;
      .Q.dd[daypath;`$"quote/"] set .Q.en[dst] result`quote
    ];
    .Q.dd[daypath;`$"trade/"] set .Q.en[dst] result
  ]
  };

runstep:{[cfg;dst;state;date]
  / one day of the run: the overnight gap from the previous close, the day's
  / simulation, its row of the days table, and the tables kept or written
  / cfg: configuration dictionary
  / dst: destination handle, or (::) to keep the tables in memory
  / state: dict `prevdate`price`trade`quote`days
  / date: trading date
  / returns: the updated state
  gap:$[null state`prevdate; 0f; .z.m.overnight[cfg;date-state`prevdate]];
  open:state[`price]*exp gap;
  result:simtick.run .z.m.daycfg[cfg;date;open];
  trades:$[99h=type result; result`trade; result];
  close:$[count trades; last trades`price; open];
  day:([]date:enlist date;open:enlist open;close:enlist close;overnightret:enlist gap;
    trades:enlist count trades;volume:enlist sum trades`qty);
  $[(::)~dst;
    [state[`trade],:enlist trades; if[99h=type result; state[`quote],:enlist result`quote]];
    .z.m.persist[dst;date;result]];
  state[`days],:enlist day;
  state[`prevdate]:date;
  state[`price]:close;
  state
  };

run:{[cfg;calendar;dbpath]
  / main simulation entry point
  / cfg: simtick configuration joined with this module's calendar keys
  /   (overnightshare, gapdayweight; see loadconfig)
  / calendar: list of trading dates
  / dbpath: file handle for disk persistence (e.g. `:/tmp/mydb), or (::) for in-memory
  / returns: in memory, a dict `trade`days (and `quote when generatequotes
  /   is set): the tables of all days and one row per day (date, open,
  /   close, overnightret, trades, volume); on disk, dbpath, with trade and
  /   quote written per date partition and days as a splayed table at the root
  /
  / Example (in-memory):
  /   cfg:tickcfg,simcalendar.loadconfig[`:di/simcalendar/presets.csv]`default
  /   result:simcalendar.run[cfg;calendar;(::)]
  /   result`days
  /
  / Example (persist to disk):
  /   simcalendar.run[cfg;calendar;`:/tmp/mydb]
  cfg:.z.m.validatecfg cfg;
  calendar:.z.m.validate calendar;
  topersist:not (::)~dbpath;
  dst:$[topersist; hsym`$string dbpath; (::)];

  / set seed once at start - the random stream flows across the days (0N = no seed)
  if[not null cfg`seed; system "S ",string cfg`seed];

  init:`prevdate`price`trade`quote`days!(0Nd;`float$cfg`startprice;();();());
  state:.z.m.runstep[cfg;dst]/[init;calendar];
  days:raze state`days;
  $[topersist;
    [.Q.dd[dst;`$"days/"] set .Q.en[dst] days; dbpath];
    $[cfg`generatequotes;
      `trade`quote`days!(raze state`trade;raze state`quote;days);
      `trade`days!(raze state`trade;days)]]
  };


/ ============================================================
/ CALENDAR AND CONFIG LOADING
/ ============================================================

loadcalendar:{[filepath]
  / load trading calendar from CSV file
  / filepath: file handle to CSV (e.g., `:calendar.csv)
  / returns: validated list of dates (errors on malformed input)
  /
  / CSV format: single column named 'date' with dates
  if[not -11h=type filepath; '"loadcalendar: filepath must be a file handle"];
  .z.m.validate "D"$1_read0 filepath
  };

/ configuration schema: column name -> (type; description)
schema:()!()
schema[`name]:("S";"preset name (key)")
schema[`overnightshare]:("F";"share of a trading day's variance that occurs overnight, between 0 and 1 (1 excluded); the intraday vol is reduced to the rest so the close-to-close vol stays the configured vol")
schema[`gapdayweight]:("F";"weight of each calendar day beyond the first in an overnight gap's variance (0.25: a weekend carries 1.5 nights' worth)")

csvtypes:raze first each value schema

loadconfig:{[filepath]
  / load the calendar presets from CSV file; a row is joined onto a simtick
  / config: cfg:tickcfg,loadconfig[`:presets.csv]`default
  / filepath: file handle to CSV
  / returns: keyed table with preset name as key
  if[not -11h=type filepath; '"loadconfig: filepath must be a file handle"];
  hdr:`$csv vs first read0 filepath;
  expected:key .z.m.schema;
  if[count missing:expected except hdr; '"loadconfig: missing columns - ",", " sv string missing];
  if[count unknown:hdr except expected; '"loadconfig: unknown columns - ",", " sv string unknown];
  if[count[hdr]<>count distinct hdr; '"loadconfig: repeated columns"];
  types:raze first each .z.m.schema hdr;
  1!expected xcols (types;enlist csv) 0: filepath
  };

describe:{[]
  / return the calendar configuration schema as a table
  ([]param:key .z.m.schema;typ:first each value .z.m.schema;description:last each value .z.m.schema)
  };

/ export public interface
export:([run;runstep;daycfg;overnight;loadcalendar;loadconfig;validate;validatecfg;describe])
