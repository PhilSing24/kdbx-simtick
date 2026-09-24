/ di.simmarket - multi-day tick simulation over a trading calendar
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
  / validate the calendar keys of a configuration (a composed simtick
  / config: the calendar keys are the scenario layer's, see compose)
  / cfg: configuration dictionary
  / returns: cfg if valid, throws error otherwise
  reqkeys:`overnightshare`gapdayweight`regimepersistence`regimecorr`volregimesd`volumeregimesd;
  reqkeys,:`vol`tradingdays`price`seed`sym`tradesperday`jumpintensity`openingtime`closingtime;
  .z.m.val.haskeys[cfg;reqkeys;"validatecfg"];
  if[not (0<=cfg`overnightshare)&1>cfg`overnightshare; '"validatecfg: overnightshare must be between 0 and 1, 1 excluded"];
  if[0>cfg`gapdayweight; '"validatecfg: gapdayweight must be zero or positive"];
  if[not (0<=cfg`regimepersistence)&1>cfg`regimepersistence; '"validatecfg: regimepersistence must be between 0 and 1, 1 excluded"];
  if[0>min cfg`volregimesd`volumeregimesd; '"validatecfg: volregimesd and volumeregimesd must be zero or positive"];
  if[not cfg[`regimecorr] within -1 1; '"validatecfg: regimecorr must be between -1 and 1"];
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
  / two standard normals from the stream seeded by seed (no reseed when
  / null): the day's volatility and volume shocks before their correlation
  if[not null seed; system "S ",string seed];
  .z.m.rng.normal 2
  };

ar1:{[phi;eps]
  / a standardized AR(1) path (persistence phi, unit stationary variance)
  / driven by the standard normal innovations eps, started at the first
  / innovation. The state carried through the scan is (phi;x), since a
  / scan over a projection with a float atom as initial value is refused by q
  (first eps),last each {[st;e] (st 0;(st[0]*st 1)+e*sqrt 1-st[0]*st 0)}\[(phi;first eps);1_eps]
  };

regimes:{[cfg;calendar]
  / the day-level regime of each calendar day: two standardized AR(1)
  / states (persistence regimepersistence, unit stationary variance), one
  / for volatility and one for volume, driven by shocks with correlation
  / regimecorr, both drawn from the per-date regime seeds, so a date's
  / shocks are the same in any calendar that contains it; the volatility
  / and volume multipliers come from their states times the calendar's
  / own. The volume multiplier is exp(sd*y-sd^2/2), mean 1; the volatility
  / multiplier is exp(sd*x-sd^2), whose square has mean 1, since volatility
  / enters the day as variance: the close-to-close variance then averages
  / the configured vol^2/tradingdays instead of exceeding it by exp(sd^2).
  / Volume and volatility move together at regimecorr, as they do in
  / markets, without being one thing
  / cfg: config dict (see validatecfg)
  / calendar: a calendar (see validate)
  / returns: the calendar table with `regimeseed`dayseed`gapseed`volstate
  /   `volumestate and `volmult`volumemult resolved (never null),
  /   `closingtime and `jumpintensity resolved to the config's value where null
  calendar:.z.m.validate calendar;
  sd:.z.m.seeds[cfg;calendar`date];
  eps:.z.m.innovation each sd`regimeseed;
  phi:cfg`regimepersistence;
  rho:cfg`regimecorr;
  ev:eps[;0];
  eq:(rho*ev)+eps[;1]*sqrt 1-rho*rho;
  x:.z.m.ar1[phi;ev];
  y:.z.m.ar1[phi;eq];
  volsd:cfg`volregimesd;
  volumesd:cfg`volumeregimesd;
  r:calendar,'sd;
  r:update volstate:x,volumestate:y,volmult:(1f^volmult)*exp (volsd*x)-volsd*volsd,volumemult:(1f^volumemult)*exp (volumesd*y)-0.5*volumesd*volumesd from r;
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

daycfg:{[cfg;day;price]
  / the simtick config for one day: its date, closing time and open price,
  / the intraday vol reduced to the share left after the overnight one (so
  / the close-to-close vol is the configured vol) times the day's volatility
  / multiplier, the trades per day times its volume multiplier and the
  / share of the full session it is open (a half day trades about half),
  / its jump intensity (a positive one selects the jump model), the base
  / intensity derived from those as compose does, and its own seed, so the
  / day is regenerated exactly from its row of the days table:
  /   simtick.run daycfg[cfg;days d;days[d]`open]
  / cfg: configuration dictionary
  / day: a row of the regimes or days table (`date`closingtime`volmult`volumemult`jumpintensity`dayseed)
  / price: price at the open
  / returns: config dict for simtick.run
  dc:cfg;
  dc[`tradingdate]:day`date;
  dc[`closingtime]:day`closingtime;
  dc[`price]:price;
  dc[`vol]:cfg[`vol]*day[`volmult]*sqrt 1-cfg`overnightshare;
  session:(day[`closingtime]-cfg`openingtime)%cfg[`closingtime]-cfg`openingtime;
  dc[`tradesperday]:`long$cfg[`tradesperday]*day[`volumemult]*session;
  dc[`jumpintensity]:day`jumpintensity;
  if[0<day`jumpintensity; dc[`pricemodel]:`jump];
  dc[`baseintensity]:simtick.intensityfor dc;
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
  / cfg: a composed simtick configuration (its scenario layer carries the
  /   calendar keys, see compose)
  / calendar: list of trading dates, or a calendar table (see validate)
  / dbpath: file handle for disk persistence (e.g. `:/tmp/mydb), or (::) for in-memory
  / returns: in memory, a dict `trade`days (and `quote when generatequotes
  /   is set): the tables of all days and one row per day (the regimes
  /   table's columns, then open, close, overnightret, trades, volume);
  /   on disk, dbpath, with trade and quote written per date partition and
  /   days as a splayed table at the root
  /
  / Example (in-memory):
  /   cfg:simtick.compose[market;instruments`NVDA;scenarios`normal;(enlist `seed)!enlist 42]
  /   result:simmarket.run[cfg;calendar;(::)]
  /   result`days
  /
  / Example (persist to disk):
  /   simmarket.run[cfg;calendar;`:/tmp/mydb]
  cfg:.z.m.validatecfg cfg;
  reg:.z.m.regimes[cfg;calendar];
  topersist:not (::)~dbpath;
  dst:$[topersist; hsym`$string dbpath; (::)];

  / every day draws from its own seeds (see seeds); none when the config has no seed
  init:`prevdate`price`trade`quote`days!(0Nd;`float$cfg`price;();();());
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

savecalendar:{[filepath;calendar]
  / write a calendar table to a CSV file that loadcalendar reads back
  / filepath: file handle
  / calendar: a calendar (see validate)
  / returns: filepath
  if[not -11h=type filepath; '"savecalendar: filepath must be a file handle"];
  filepath 0: csv 0: .z.m.validate calendar
  };


/ ============================================================
/ NYSE CALENDAR
/ ============================================================
/ q dates count from 2000.01.01, a Saturday: d mod 7 is 0 Saturday, 1 Sunday, 2 Monday ... 6 Friday

nyse.ymd:{[y;m;d]
  / the date of a year, month and day
  (`date$`month$(12*y-2000)+m-1)+d-1
  };

nyse.easter:{[y]
  / Easter Sunday of a year (anonymous Gregorian algorithm)
  / the sums are spelled out with neg: q evaluates right to left, so a
  / chain like b-f+1 is b-(f+1)
  a:y mod 19; b:y div 100; c:y mod 100; d:b div 4; e:b mod 4;
  f:(b+8) div 25;
  g:(sum (b;1;neg f)) div 3;
  h:(sum (19*a;b;15;neg d;neg g)) mod 30;
  i:c div 4; k:c mod 4;
  l:(sum (32;2*e;2*i;neg h;neg k)) mod 7;
  m:(sum (a;11*h;22*l)) div 451;
  n:sum (h;l;114;neg 7*m);
  .z.m.nyse.ymd[y;n div 31;1+n mod 31]
  };

nyse.nthweekday:{[y;m;wd;n]
  / the nth weekday wd (2 Monday ... 5 Thursday) of month m of year y
  d0:.z.m.nyse.ymd[y;m;1];
  d0+(7*n-1)+(wd-d0 mod 7) mod 7
  };

nyse.lastweekday:{[y;m;wd]
  / the last weekday wd of month m of year y
  dl:.z.m.nyse.ymd[y;m+1;1]-1;
  dl-((dl mod 7)-wd) mod 7
  };

nyse.observed:{[d]
  / the weekday on which a holiday falling on d is observed: Friday before a
  / Saturday, Monday after a Sunday
  $[0=d mod 7; d-1; 1=d mod 7; d+1; d]
  };

nyse.holidays:{[y]
  / the NYSE full-day holidays of a year: New Year's Day (not observed on the
  / Friday when it falls on a Saturday), Martin Luther King Jr. Day,
  / Presidents' Day, Good Friday, Memorial Day, Juneteenth (from 2022),
  / Independence Day, Labor Day, Thanksgiving and Christmas. Special
  / closures (days of mourning, disasters) are not modelled
  ny:.z.m.nyse.ymd[y;1;1];
  ny:$[1=ny mod 7; ny+1; ny];
  h:ny,.z.m.nyse.nthweekday[y;1;2;3],.z.m.nyse.nthweekday[y;2;2;3],.z.m.nyse.easter[y]-2;
  h,:.z.m.nyse.lastweekday[y;5;2];
  if[y>=2022; h,:.z.m.nyse.observed .z.m.nyse.ymd[y;6;19]];
  h,:.z.m.nyse.observed .z.m.nyse.ymd[y;7;4];
  h,:.z.m.nyse.nthweekday[y;9;2;1],.z.m.nyse.nthweekday[y;11;5;4];
  h,:.z.m.nyse.observed .z.m.nyse.ymd[y;12;25];
  asc h where not (h mod 7) in 0 1
  };

nyse.halfdays:{[y]
  / the NYSE early closes (13:00) of a year: the day after Thanksgiving,
  / July 3 and Christmas Eve when they are trading days
  hol:.z.m.nyse.holidays y;
  h:(1+.z.m.nyse.nthweekday[y;11;5;4]),.z.m.nyse.ymd[y;7;3],.z.m.nyse.ymd[y;12;24];
  asc h where (not (h mod 7) in 0 1)&not h in hol
  };

nysecalendar:{[from;to]
  / the NYSE trading calendar between two dates: weekdays that are not
  / holidays, with the closing time 13:00 on early-close days and 16:00
  / otherwise, the other columns null (the config's values). Rules as of
  / 2024; check special closures against the official calendar
  / from: first date
  / to: last date, at or after from
  / returns: calendar table (see validate)
  if[not (-14h=type from)&-14h=type to; '"nysecalendar: from and to must be dates"];
  if[from>to; '"nysecalendar: from must be at or before to"];
  years:(`year$from)+til 1+(`year$to)-`year$from;
  hol:raze .z.m.nyse.holidays each years;
  half:raze .z.m.nyse.halfdays each years;
  d:from+til 1+to-from;
  d:d where (not (d mod 7) in 0 1)&not d in hol;
  .z.m.validate ([]date:d;closingtime:?[d in half;13:00;16:00])
  };


/ ============================================================
/ SEVERAL INSTRUMENTS
/ ============================================================

compose:{[market;instruments;scenarios;scenario;run]
  / the configuration of each instrument of a multi-instrument run, one
  / scenario for all or one per instrument
  / market: a market dictionary (simtick.loadmarket)
  / instruments: the instrument table (simtick.loadinstruments)
  / scenarios: the scenario table (simtick.loadscenarios)
  / scenario: a scenario name for every instrument of the table, or a
  /   dictionary sym!scenario name for the instruments it names
  / run: the run dictionary (date or calendar aside: seed, generatequotes)
  / returns: dictionary sym!composed configuration (see simtick.compose)
  if[-11h=type scenario; scenario:(exec sym from instruments)!(count instruments)#scenario];
  if[not 99h=type scenario; '"compose: scenario must be a name or a dictionary sym!name"];
  syms:key scenario;
  if[count missing:syms where not syms in exec sym from instruments;
    '"compose: instruments not in the instrument table - ",", " sv string missing];
  if[count unknown:(distinct value scenario) where not (distinct value scenario) in exec name from scenarios;
    '"compose: scenarios not in the scenario table - ",", " sv string unknown];
  syms!{[m;i;s;r;sym;sce] simtick.compose[m;i sym;s sce;r]}[market;instruments;scenarios;run]'[syms;value scenario]
  };

persistmany:{[dst;merged]
  / write a merged multi-instrument result: trade and quote per date
  / partition (sorted by sym then time, sym parted), days at the root
  dates:distinct `date$merged[`trade]`time;
  {[dst;merged;d]
    daypath:hsym`$string[dst],"/",string d;
    {[dst;daypath;merged;d;name]
      if[not name in key merged; :(::)];
      t:select from merged name where d=`date$time;
      .Q.dd[daypath;`$string[name],"/"] set .Q.en[dst] update `p#sym from `sym`time xasc t}[dst;daypath;merged;d] each `trade`quote;
    }[dst;merged] each dates;
  .Q.dd[dst;`$"days/"] set .Q.en[dst] merged`days;
  dst
  };

runmany:{[cfgs;calendar;dbpath]
  / run several instruments over the same calendar (see compose): the
  / regime seed of a date is shared, so the instruments live the same
  / market days; each has its own tape and gaps
  / cfgs: dictionary sym!configuration (compose)
  / calendar: a list of trading dates, or a calendar table (see validate)
  / dbpath: file handle for disk persistence, or (::) for in-memory
  / returns: in memory, a dict `trade`days (and `quote when the configs
  /   return quotes), the tables of every instrument and day, sorted by
  /   time, and the days table with a sym column; on disk, dbpath
  if[not 99h=type cfgs; '"runmany: cfgs must be a dictionary sym!configuration"];
  rs:.z.m.run[;calendar;(::)] each cfgs;
  merged:(`symbol$())!();
  merged[`trade]:`time`sym xasc raze rs[;`trade];
  if[all `quote in/: key each rs; merged[`quote]:`time`sym xasc raze rs[;`quote]];
  merged[`days]:`sym`date xasc raze {[sym;r] `sym xcols update sym:sym from r`days}'[key rs;value rs];
  $[(::)~dbpath; merged; .z.m.persistmany[hsym`$string dbpath;merged]]
  };

describe:{[]
  / the calendar keys of the configuration schema (the scenario layer's
  / calendar group), with their types and descriptions
  ?[simtick.describe[];enlist (=;`group;enlist `calendar);0b;()]
  };

/ export public interface
export:([run;runmany;compose;runstep;daycfg;overnight;seeds;regimes;loadcalendar;savecalendar;nysecalendar;validate;validatecfg;describe])
