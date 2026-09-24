/ di.simmarket - multi-day tick simulation over a trading calendar
/ Runs di.simtick day after day: each day opens at the previous close moved
/ by an overnight return, has its own volatility and volume regime, closing
/ time and jump intensity, and its own seed, and the days are summarized
/ in a table from which any day can be regenerated alone

/ load simtick module
simtick:use`di.simtick
simconfig:use`di.simconfig


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

simday:{[cfg;day;price]
  / one stock's day: the day simulated from its row of the regimes table
  / opening at price, and the row of the days table it makes
  / cfg: configuration dictionary
  / day: a row of the regimes table
  / price: the day's open
  / returns: dict `trade`quote`day (quote empty when the config does not
  /   return quotes), `close
  result:simtick.run .z.m.daycfg[cfg;day;price];
  trades:$[99h=type result; result`trade; result];
  quotes:$[99h=type result; result`quote; ()];
  close:$[count trades; last trades`price; price];
  row:(enlist day),'([]open:enlist price;close:enlist close;overnightret:enlist 0f;
    trades:enlist count trades;volume:enlist sum trades`qty);
  `trade`quote`day`close!(trades;quotes;row;close)
  };

runstep:{[cfg;state;day]
  / one day of an in-memory run: the overnight gap from the previous close
  / (drawn from the day's gap seed), the day's simulation, its row of the
  / days table, and the tables kept
  / cfg: configuration dictionary
  / state: dict `prevdate`price`trade`quote`days
  / day: a row of the regimes table
  / returns: the updated state
  date:day`date;
  if[not null day`gapseed; system "S ",string day`gapseed];
  gap:$[null state`prevdate; 0f; .z.m.overnight[cfg;date-state`prevdate]];
  open:state[`price]*exp gap;
  r:.z.m.simday[cfg;day;open];
  state[`trade],:enlist r`trade;
  if[cfg`generatequotes; state[`quote],:enlist r`quote];
  state[`days],:enlist update overnightret:gap from r`day;
  state[`prevdate]:date;
  state[`price]:r`close;
  state
  };

run:{[cfg;calendar;dbpath]
  / main simulation entry point for one stock
  / cfg: a composed simtick configuration (its scenario layer carries the
  /   days keys, see compose)
  / calendar: list of trading dates, or a calendar table (see validate)
  / dbpath: file handle for disk persistence (e.g. `:/tmp/mydb), or (::) for in-memory
  / returns: in memory, a dict `trade`days (and `quote when generatequotes
  /   is set): the tables of all days and one row per day (the regimes
  /   table's columns, then open, close, overnightret, trades, volume);
  /   on disk, dbpath: the standard date-partitioned database of writehdb,
  /   with this one stock
  /
  / Example (in-memory):
  /   cfg:simtick.compose[market;instruments`NVDA;scenarios`normal;(enlist `seed)!enlist 42]
  /   result:simmarket.run[cfg;calendar;(::)]
  /   result`days
  /
  / Example (persist to disk):
  /   simmarket.run[cfg;calendar;`:/tmp/mydb]
  cfg:.z.m.validatecfg cfg;
  if[not (::)~dbpath; :.z.m.writehdb[(enlist cfg`sym)!enlist cfg;calendar;dbpath;(`symbol$())!()]];
  reg:.z.m.regimes[cfg;calendar];
  / every day draws from its own seeds (see seeds); none when the config has no seed
  init:`prevdate`price`trade`quote`days!(0Nd;`float$cfg`price;();();());
  state:.z.m.runstep[cfg]/[init;reg];
  days:raze state`days;
  $[cfg`generatequotes;
    `trade`quote`days!(raze state`trade;raze state`quote;days);
    `trade`days!(raze state`trade;days)]
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

runmany:{[cfgs;calendar;dbpath]
  / run several instruments over the same calendar (see compose): the
  / regime seed of a date is shared, so the instruments live the same
  / market days; each has its own tape and gaps
  / cfgs: dictionary sym!configuration (compose)
  / calendar: a list of trading dates, or a calendar table (see validate)
  / dbpath: file handle for disk persistence, or (::) for in-memory
  / returns: in memory, a dict `trade`days (and `quote when the configs
  /   return quotes), the tables of every instrument and day, sorted by
  /   time, and the days table with a sym column; on disk, dbpath: the
  /   standard date-partitioned database of writehdb with its defaults
  if[not 99h=type cfgs; '"runmany: cfgs must be a dictionary sym!configuration"];
  if[not (::)~dbpath; :.z.m.writehdb[cfgs;calendar;dbpath;(`symbol$())!()]];
  rs:.z.m.run[;calendar;(::)] each cfgs;
  merged:(`symbol$())!();
  merged[`trade]:`time`sym xasc raze rs[;`trade];
  if[all `quote in/: key each rs; merged[`quote]:`time`sym xasc raze rs[;`quote]];
  merged[`days]:`sym`date xasc raze {[sym;r] `sym xcols update sym:sym from r`days}'[key rs;value rs];
  merged
  };


/ ============================================================
/ THE OUTPUT DATABASE: ONE DAY OF ALL STOCKS AT A TIME
/ ============================================================
/ writehdb writes a standard compressed date-partitioned kdb+ database:
/   dbpath/sym            the symbol enumeration shared by all partitions
/   dbpath/config         the run, a q dictionary: every stock's composed
/                         configuration, the calendar, the tables written,
/                         the compression and the version of the code (a
/                         kdb+ root holds q objects only: \l loads it as
/                         the variable config; .j.j gives the JSON)
/   dbpath/<date>/trade   all stocks that day, sorted by sym then time, `p#sym
/   dbpath/<date>/quote   the same, when requested
/   dbpath/<date>/days    one row per stock: regime, open, close, gap, trades, volume
/ Every partition holds every requested table; days is written last, so a
/ crash cannot leave a date looking complete. A complete date is skipped on
/ a rerun (its closes carried forward), an incomplete one is rewritten from
/ scratch, and a database built with another configuration is refused

hdbdefaults:`tables`compression!(`trade`quote;17 5 3)

version:{[]
  / the git commit of the code (with -dirty when the modules have
  / uncommitted changes), or `unknown outside a checkout; the same
  / configuration and seeds reproduce a database only with the same code
  roots:.Q.m.SP where not ()~/:key each hsym each `$.Q.m.SP,\:"/di/simmarket/init.q";
  if[0=count roots; :`unknown];
  root:first roots;
  h:@[system;"git -C ",root," rev-parse --short HEAD 2>/dev/null";()];
  if[not count h; :`unknown];
  dirty:count @[system;"git -C ",root," status --porcelain di/simtick di/simmarket di/simconfig 2>/dev/null";()];
  `$first[h],$[dirty;"-dirty";""]
  };

hdbopts:{[opts]
  / the writer's options filled with their defaults and checked
  / tables: `trade`quote (default) or `trade; compression: the (logical
  / block size;algorithm;level) triple for every column, 17 5 3 by default
  / (128 KB blocks, zstd level 3), () for uncompressed
  if[not 99h=type opts; '"writehdb: opts must be a dictionary"];
  if[count unknown:(key opts) except key .z.m.hdbdefaults; '"writehdb: unknown options - ",", " sv string unknown];
  o:.z.m.hdbdefaults,opts;
  o[`tables]:(),o`tables;
  if[not (`trade in o`tables)&all o[`tables] in `trade`quote; '"writehdb: tables must be `trade`quote or `trade"];
  if[not ()~o`compression; o[`compression]:`long$(),o`compression];
  if[not (()~o`compression)|3=count o`compression;
    '"writehdb: compression must be (logical block size;algorithm;level) or ()"];
  o
  };

saverun:{[dst;runcfg]
  / config: the run as one q object file at the root
  .Q.dd[dst;`config] set runcfg;
  };

loadrun:{[dbpath]
  / the run that wrote a database, from its config file: `configs (sym!
  / configuration), `calendar, `opts (tables and compression) and
  / `version; writehdb[r`configs;r`calendar;path;r`opts] reproduces the
  / database with the same code. A warning is printed when the code that
  / wrote it differs from the code running
  if[not -11h=type dbpath; '"loadrun: dbpath must be a file handle"];
  f:.Q.dd[hsym`$string dbpath;`config];
  if[()~key f; '"loadrun: no config at ",string dbpath];
  d:get f;
  opts:`tables`compression!(d`tables;d`compression);
  ver:d`version;
  now:.z.m.version[];
  if[not ver=now; -1 "loadrun: the database was written by version ",string[ver],", the code running is ",string[now],": the same configuration and seeds reproduce it only with the same code"];
  `configs`calendar`opts`version!(d`configs;.z.m.validate d`calendar;opts;ver)
  };

symfile:{[dst]
  / the enumeration domain of a database as a symbol list (empty when new)
  f:.Q.dd[dst;`sym];
  $[()~key f; `symbol$(); get f]
  };

complete:{[dst;date;names;syms]
  / whether a date's partition is complete: every requested table and days
  / are there with their .d file, and days holds one row per stock
  / returns: the days rows (with syms resolved) when complete, () otherwise
  dir:.Q.par[dst;date;`];
  if[()~key dir; :()];
  ok:all {[dst;date;name] `.d in key .Q.par[dst;date;name]}[dst;date] each names,`days;
  if[not ok; :()];
  days:@[get;.Q.par[dst;date;`days];()];
  if[not 98h=type days; :()];
  if[not `sym in cols days; :()];
  s:.z.m.symfile dst;
  days:update sym:s `long$sym from days;
  if[not (asc syms)~asc distinct days`sym; :()];
  days
  };

writetable:{[dst;date;name;t;compression;sortcols]
  / one table into a date partition: sorted, `p#sym, enumerated against
  / the database's sym file, every column compressed by the triple. The
  / session's compression setting is restored afterwards, on error too
  t:update `p#sym from sortcols xasc t;
  t:.Q.en[dst] t;
  path:.Q.par[dst;date;name];
  zdbefore:@[value;`.z.zd;`unset];
  if[count compression; `.z.zd set compression];
  r:@[{[p;t] .Q.dd[p;`] set t; ::}[path];t;{[e] e}];
  $[`unset~zdbefore; if[count compression; system "x .z.zd"]; `.z.zd set zdbefore];
  if[10h=type r; 'r];
  };

writeday:{[cfgs;regs;dst;o;state;i]
  / one date of the database: skipped when complete (the closes carried
  / forward from its days rows), otherwise every stock simulated for the
  / date, the tables joined and written, days last, and the day's tables
  / dropped before the next date
  / state: dict `prevdate`price (price a dict sym!close)
  date:first (regs first key regs)[i]`date;
  syms:key cfgs;
  done:.z.m.complete[dst;date;o`tables;syms];
  if[count done;
    state[`price]:syms!(exec sym!close from done) syms;
    state[`prevdate]:date;
    :state];
  system "rm -rf ",1_string .Q.par[dst;date;`];
  one:{[cfgs;regs;o;state;date;i;sym]
    cfg:cfgs sym; day:regs[sym] i;
    if[not null day`gapseed; system "S ",string day`gapseed];
    gap:$[null state`prevdate; 0f; .z.m.overnight[cfg;date-state`prevdate]];
    open:state[`price;sym]*exp gap;
    cfg[`generatequotes]:`quote in o`tables;
    r:.z.m.simday[cfg;day;open];
    r[`day]:`sym xcols update sym:sym,overnightret:gap from r`day;
    r}[cfgs;regs;o;state;date;i];
  rs:syms!one each syms;
  trade:raze rs[;`trade];
  .z.m.writetable[dst;date;`trade;trade;o`compression;`sym`time];
  if[`quote in o`tables; .z.m.writetable[dst;date;`quote;raze rs[;`quote];o`compression;`sym`time]];
  .z.m.writetable[dst;date;`days;delete date from raze rs[;`day];o`compression;enlist `sym];
  state[`price]:syms!rs[;`close] syms;
  state[`prevdate]:date;
  state
  };

writehdb:{[cfgs;calendar;dbpath;opts]
  / several stocks over a calendar written as a standard compressed
  / date-partitioned kdb+ database, one day of all stocks at a time (see
  / the layout above); loadable with \l
  / cfgs: dictionary sym!configuration (compose)
  / calendar: a list of trading dates, or a calendar table (see validate)
  / dbpath: file handle of the database root
  / opts: dictionary with any of `tables (`trade`quote by default, or
  /   `trade; days is always written) and `compression (17 5 3 by default:
  /   128 KB blocks, zstd level 3; () for uncompressed; 17 2 6 for gzip,
  /   readable by kdb+ before 4.1)
  / returns: dbpath. A complete date is skipped, so an interrupted run
  /   continues where it stopped and equals a full run; the config file
  /   at the root replays the run (see loadrun); a database built with
  /   another configuration, other than a shorter calendar, is refused
  if[not 99h=type cfgs; '"writehdb: cfgs must be a dictionary sym!configuration"];
  if[not -11h=type dbpath; '"writehdb: dbpath must be a file handle"];
  cfgs:.z.m.validatecfg each cfgs;
  if[not (key cfgs)~value[cfgs][;`sym]; '"writehdb: the keys of cfgs must be their configurations' sym"];
  o:.z.m.hdbopts opts;
  calendar:.z.m.validate calendar;
  dst:hsym`$string dbpath;
  runcfg:`configs`calendar`tables`compression`version!(cfgs;0!calendar;o`tables;o`compression;.z.m.version[]);
  if[not ()~key .Q.dd[dst;`config];
    old:.z.m.loadrun dst;
    same:{[a;b] (asc[key a]#a)~asc[key b]#b};
    if[not all same'[old`configs;cfgs]; '"writehdb: ",string[dbpath]," holds a database built with a different configuration"];
    if[not (asc key old`configs)~asc key cfgs; '"writehdb: ",string[dbpath]," holds a database built for other instruments"];
    if[not old[`opts]~o; '"writehdb: ",string[dbpath]," holds a database written with other tables or compression"];
    if[not (old`calendar)~(count old`calendar)#calendar; '"writehdb: ",string[dbpath]," holds a database built on another calendar (a calendar can only be extended)"]];
  system "mkdir -p ",1_string dst;
  .z.m.saverun[dst;runcfg];
  regs:.z.m.regimes[;calendar] each cfgs;
  init:`prevdate`price!(0Nd;key[cfgs]!`float$value[cfgs][;`price]);
  .z.m.writeday[cfgs;regs;dst;o]/[init;til count calendar];
  dbpath
  };

describe:{[]
  / the calendar keys of the configuration schema (the scenario layer's
  / days group), with their types and descriptions
  ?[simtick.describe[];enlist (=;`group;enlist `days);0b;()]
  };

/ export public interface
export:([run;runmany;writehdb;loadrun;version;complete;writetable;writeday;hdbopts;saverun;symfile;compose;runstep;simday;daycfg;overnight;seeds;regimes;loadcalendar;savecalendar;nysecalendar;validate;validatecfg;describe])
