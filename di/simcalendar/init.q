/ di.simcalendar - multi-day tick simulation over a trading calendar
/ Runs di.simtick day after day: each day opens at the previous close moved
/ by an overnight return, has its own volatility and volume regime, closing
/ time and jump intensity, and its own seed, and the days are summarized
/ in a table from which any day can be regenerated alone

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

/ modulus of the per-day seeds (a prime below 2^31)
seedmod:2147483647

/ optional calendar columns, their CSV types and their meaning when null
calcols:`closingtime`volmult`volumemult`jumpintensity
calctypes:"UFFF"


/ ============================================================
/ VALIDATION
/ ============================================================

validate:{[calendar]
  / validate a calendar and return it as a table
  / calendar: a list of dates, or a table with a date column and any of the
  /   optional columns closingtime (minute), volmult, volumemult and
  /   jumpintensity (floats); a null means the config's value (1 for the
  /   multipliers)
  / returns: table `date`closingtime`volmult`volumemult`jumpintensity, ascending
  if[14h=type calendar; calendar:([]date:calendar)];
  if[not 98h=type calendar; '"validate: calendar must be a date list or a table with a date column"];
  if[not `date in cols calendar; '"validate: calendar table must have a date column"];
  if[count unknown:(cols calendar) except `date,calcols; '"validate: unknown calendar columns - ",", " sv string unknown];
  dates:calendar`date;
  if[not 14h=type dates; '"validate: date column must be dates"];
  if[0=count dates; '"validate: calendar cannot be empty"];
  if[count[dates]<>count distinct dates; '"validate: calendar contains duplicates"];
  if[not dates~asc dates; '"validate: calendar must be sorted ascending"];
  n:count dates;
  missing:calcols where not calcols in cols calendar;
  filled:calendar;
  if[count missing; filled:calendar,'flip missing!{[n;t] n#$[t="U";0Nu;0n]}[n] each calctypes calcols?missing];
  (`date,calcols) xcols filled
  };

validatecfg:{[cfg]
  / validate the calendar keys of a configuration (a simtick config joined
  / with a row of this module's presets, see loadconfig)
  / cfg: configuration dictionary
  / returns: cfg if valid, throws error otherwise
  reqkeys:`overnightshare`gapdayweight`regimepersistence`volregimesd`volumeregimesd;
  reqkeys,:`vol`tradingdays`startprice`seed`sym`baseintensity`jumpintensity;
  .z.m.val.haskeys[cfg;reqkeys;"validatecfg"];
  if[not (0<=cfg`overnightshare)&1>cfg`overnightshare; '"validatecfg: overnightshare must be between 0 and 1, 1 excluded"];
  if[0>cfg`gapdayweight; '"validatecfg: gapdayweight must be zero or positive"];
  if[not (0<=cfg`regimepersistence)&1>cfg`regimepersistence; '"validatecfg: regimepersistence must be between 0 and 1, 1 excluded"];
  if[0>min cfg`volregimesd`volumeregimesd; '"validatecfg: volregimesd and volumeregimesd must be zero or positive"];
  cfg
  };


/ ============================================================
/ SEEDS AND REGIMES
/ ============================================================

seeds:{[cfg;dates]
  / the per-day seeds: a regime seed per date, shared by every instrument
  / (the market's day), and from it the instrument's day seed and gap seed;
  / all null when the config has no seed
  / cfg: config dict with `seed`sym
  / dates: list of dates
  / returns: table `date`regimeseed`dayseed`gapseed
  n:count dates;
  if[null cfg`seed; :([]date:dates;regimeseed:n#0N;dayseed:n#0N;gapseed:n#0N)];
  regimeseed:1+(("j"$dates)+7919*cfg`seed) mod seedmod;
  symhash:sum ("j"$string cfg`sym)*1+til count string cfg`sym;
  dayseed:1+(symhash+31*regimeseed) mod seedmod;
  gapseed:1+(3+17*dayseed) mod seedmod;
  ([]date:dates;regimeseed:regimeseed;dayseed:dayseed;gapseed:gapseed)
  };

innovation:{[seed]
  / one standard normal from the stream seeded by seed (no reseed when null)
  if[not null seed; system "S ",string seed];
  first .z.m.rng.normal 1
  };

regimes:{[cfg;calendar]
  / the day-level regime of each calendar day: a standardized AR(1) state
  / x (persistence regimepersistence, unit stationary variance) whose
  / innovations are drawn from the per-date regime seeds, so a date's
  / innovation is the same in any calendar that contains it, and the
  / volatility and volume multipliers exp(sd*x-sd^2/2) times the calendar's
  / own; volume and volatility move together, as they do in markets
  / cfg: config dict (see validatecfg)
  / calendar: a calendar (see validate)
  / returns: the calendar table with `regimeseed`dayseed`gapseed`x and
  /   `volmult`volumemult resolved (never null), `closingtime and
  /   `jumpintensity resolved to the config's value where null
  calendar:.z.m.validate calendar;
  sd:.z.m.seeds[cfg;calendar`date];
  eps:.z.m.innovation each sd`regimeseed;
  phi:cfg`regimepersistence;
  / the state carried through the scan is (phi; x), since a scan over a
  / projection with a float atom as initial value is refused by q
  x:(first eps),last each {[st;e] (st 0;(st[0]*st 1)+e*sqrt 1-st[0]*st 0)}\[(phi;first eps);1_eps];
  volsd:cfg`volregimesd;
  volumesd:cfg`volumeregimesd;
  r:calendar,'sd;
  r:update x:x,volmult:(1f^volmult)*exp (volsd*x)-0.5*volsd*volsd,volumemult:(1f^volumemult)*exp (volumesd*x)-0.5*volumesd*volumesd from r;
  update closingtime:cfg[`closingtime]^closingtime,jumpintensity:cfg[`jumpintensity]^jumpintensity from r
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

daycfg:{[cfg;day;startprice]
  / the simtick config for one day: its date, closing time and open price,
  / the intraday vol reduced to the share left after the overnight one (so
  / the close-to-close vol is the configured vol) times the day's volatility
  / multiplier, the base intensity times its volume multiplier, its jump
  / intensity (a positive one selects the jump model), and its own seed, so
  / the day is regenerated exactly from its row of the days table:
  /   simtick.run daycfg[cfg;days d;days[d]`open]
  / cfg: configuration dictionary
  / day: a row of the regimes or days table (`date`closingtime`volmult`volumemult`jumpintensity`dayseed)
  / startprice: price at the open
  / returns: config dict for simtick.run
  dc:cfg;
  dc[`tradingdate]:day`date;
  dc[`closingtime]:day`closingtime;
  dc[`startprice]:startprice;
  dc[`vol]:cfg[`vol]*day[`volmult]*sqrt 1-cfg`overnightshare;
  dc[`baseintensity]:cfg[`baseintensity]*day`volumemult;
  dc[`jumpintensity]:day`jumpintensity;
  if[0<day`jumpintensity; dc[`pricemodel]:`jump];
  dc[`seed]:day`dayseed;
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

runstep:{[cfg;dst;state;day]
  / one day of the run: the overnight gap from the previous close (drawn
  / from the day's gap seed), the day's simulation, its row of the days
  / table, and the tables kept or written
  / cfg: configuration dictionary
  / dst: destination handle, or (::) to keep the tables in memory
  / state: dict `prevdate`price`trade`quote`days
  / day: a row of the regimes table
  / returns: the updated state
  date:day`date;
  if[not null day`gapseed; system "S ",string day`gapseed];
  gap:$[null state`prevdate; 0f; .z.m.overnight[cfg;date-state`prevdate]];
  open:state[`price]*exp gap;
  result:simtick.run .z.m.daycfg[cfg;day;open];
  trades:$[99h=type result; result`trade; result];
  close:$[count trades; last trades`price; open];
  day:(enlist day),'([]open:enlist open;close:enlist close;overnightret:enlist gap;
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
  /   (see loadconfig)
  / calendar: list of trading dates, or a calendar table (see validate)
  / dbpath: file handle for disk persistence (e.g. `:/tmp/mydb), or (::) for in-memory
  / returns: in memory, a dict `trade`days (and `quote when generatequotes
  /   is set): the tables of all days and one row per day (the regimes
  /   table's columns, then open, close, overnightret, trades, volume);
  /   on disk, dbpath, with trade and quote written per date partition and
  /   days as a splayed table at the root
  /
  / Example (in-memory):
  /   cfg:tickcfg,simcalendar.loadconfig[`:di/simcalendar/presets.csv]`default
  /   result:simcalendar.run[cfg;calendar;(::)]
  /   result`days
  /
  / Example (persist to disk):
  /   simcalendar.run[cfg;calendar;`:/tmp/mydb]
  cfg:.z.m.validatecfg cfg;
  reg:.z.m.regimes[cfg;calendar];
  topersist:not (::)~dbpath;
  dst:$[topersist; hsym`$string dbpath; (::)];

  / every day draws from its own seeds (see seeds); none when the config has no seed
  init:`prevdate`price`trade`quote`days!(0Nd;`float$cfg`startprice;();();());
  state:.z.m.runstep[cfg;dst]/[init;reg];
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
  / load a trading calendar from a CSV file
  / filepath: file handle to CSV (e.g., `:calendar.csv)
  / returns: validated calendar table (see validate)
  /
  / CSV format: a date column, and any of closingtime (minute), volmult,
  / volumemult and jumpintensity; an empty cell means the config's value
  if[not -11h=type filepath; '"loadcalendar: filepath must be a file handle"];
  hdr:`$csv vs first read0 filepath;
  if[not `date in hdr; '"loadcalendar: the CSV must have a date column"];
  if[count unknown:hdr except `date,calcols; '"loadcalendar: unknown columns - ",", " sv string unknown];
  types:(`date,calcols)!"D",calctypes;
  .z.m.validate (types hdr;enlist csv) 0: filepath
  };

/ configuration schema: column name -> (type; description)
schema:()!()
schema[`name]:("S";"preset name (key)")
schema[`overnightshare]:("F";"share of a trading day's variance that occurs overnight, between 0 and 1 (1 excluded); the intraday vol is reduced to the rest so the close-to-close vol stays the configured vol")
schema[`gapdayweight]:("F";"weight of each calendar day beyond the first in an overnight gap's variance (0.25: a weekend carries 1.5 nights' worth)")
schema[`regimepersistence]:("F";"AR(1) persistence of the day-level regime, between 0 and 1 (1 excluded): 0 = independent days, 0.7 = quiet and busy spells of a few days")
schema[`volregimesd]:("F";"standard deviation of the log volatility multiplier across days (0 = every day at the configured vol)")
schema[`volumeregimesd]:("F";"standard deviation of the log volume multiplier across days, driven by the same regime as the volatility (0 = every day at the configured intensity)")

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
export:([run;runstep;daycfg;overnight;seeds;regimes;loadcalendar;loadconfig;validate;validatecfg;describe])
