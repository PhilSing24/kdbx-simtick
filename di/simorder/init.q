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
  reqkeys,:`numfills`pacing`spreadcapture`ticksize`jitter`seed;
  reqkeys,:`account`algo`capacity`latencyms`maxreplaces;
  .z.m.val.haskeys[cfg;reqkeys;"validate"];

  if[cfg[`starttime]>=cfg`endtime; '"validate: starttime must be before endtime"];
  if[(`date$cfg`starttime)<>`date$cfg`endtime; '"validate: starttime and endtime must fall on the same day"];
  if[0>=cfg`orderqty; '"validate: orderqty must be positive"];
  if[0>=cfg`numfills; '"validate: numfills must be positive"];
  if[not cfg[`side] in `BUY`SELL; '"validate: side must be BUY or SELL"];
  if[not cfg[`pacing] in `even`frontloaded`arrival; '"validate: pacing must be even, frontloaded or arrival"];
  if[not cfg[`spreadcapture] within 0 1; '"validate: spreadcapture must be between 0 and 1 (0=mid, 1=far touch)"];
  if[0>=cfg`ticksize; '"validate: ticksize must be positive"];
  if[not cfg[`jitter] within 0 1; '"validate: jitter must be between 0 and 1"];
  if[not cfg[`capacity] in `A`P; '"validate: capacity must be A (agency) or P (principal)"];
  if[0>cfg`latencyms; '"validate: latencyms must be zero or positive"];
  if[0>cfg`maxreplaces; '"validate: maxreplaces must be zero or positive"];
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

jittered:{[cfg;scheduled]
  / the scheduled child times moved by a uniform jitter of up to jitter
  / times the gap to the neighbouring child, drawn from the seeded stream,
  / so children do not land on exact fractions of the window; the order
  / of the children and the window are kept
  / cfg: config dict with `jitter`starttime`endtime
  / scheduled: ascending timestamps from schedule
  / returns: ascending timestamps inside the window
  n:count scheduled;
  gaps:`float$`long$(scheduled,cfg`endtime)-(cfg`starttime),scheduled;
  room:0.5*gaps[til n]&gaps 1+til n;
  shift:`timespan$`long$room*cfg[`jitter]*-1+2*n?1.0;
  scheduled+shift
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
  sizes:1|floor 0.5+raw;  / round to nearest, then enforce minimum size of 1 per fill

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
  / validate a market impact configuration dictionary, filling the optional
  / keys: permanent (0) and model (`participation)
  / icfg: `eta`beta`halflife`taper`closetime and optionally `permanent`model (see impact)
  / returns: icfg with the optional keys filled if valid, throws error otherwise
  .z.m.val.haskeys[icfg;`eta`beta`halflife`taper`closetime;"validateimpact"];
  icfg:(`permanent`model!(0f;`participation)),icfg;
  if[not icfg[`permanent] within 0 1; '"validateimpact: permanent must be between 0 and 1"];
  if[not icfg[`model] in `participation`sqrtlaw; '"validateimpact: model must be participation or sqrtlaw"];
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
  / impact of each child execution, as a fraction of the price
  / model `participation: eta x sigma x p^beta, with p the child's participation, own / (own + market),
  /   in the market volume of an interval of the child's length centred on its time (for arrival
  /   pacing, the interval the child was sized in)
  / model `sqrtlaw: eta x sigma x sqrt(own / daily volume), the square-root law on the child's size
  /   against the day's volume
  / icfg: impact configuration (see validateimpact); a missing model means participation
  / execs: `time`qty`interval, interval a timespan
  / trades: the day's trades for the instrument, `time`qty, time-sorted
  / sigma: daily volatility as a fraction (see dailyvol)
  / returns: float fraction per execution
  own:`float$execs`qty;
  if[`sqrtlaw=$[`model in key icfg;icfg`model;`participation]; :icfg[`eta]*sigma*sqrt own%sum `float$trades`qty];
  csum:0f,sums `float$trades`qty;
  half:`timespan$(`long$execs`interval) div 2;
  vol:(csum trades[`time] binr execs[`time]+half)-csum trades[`time] binr execs[`time]-half;
  p:0f^own%own+vol;
  icfg[`eta]*sigma*xexp[p;icfg`beta]
  };

shiftat:{[icfg;times;moves]
  / the market's price shift in currency at each of times (ascending, one day): the sum of every earlier or
  / simultaneous child's signed impact, a share permanent of which stays through the day while the rest
  / halves every halflife and is ignored after 20 halflives (below a millionth of it); the sum is tapered
  / linearly to zero over the taper before closetime (so the close, and the next day di.simcalendar starts
  / from it, are unmoved: the permanent share is permanent within the day) and rounded to whole cents, so
  / bid and ask move by the same tick
  / icfg: impact configuration (see validateimpact); a missing permanent share means 0
  / times: ascending timestamps of one day
  / moves: `time`amount, amount in currency, positive pushing the price up
  / returns: float shift per time
  n:count times;
  if[0=n; :`float$()];
  h:`float$`long$icfg`halflife;
  perm:$[`permanent in key icfg;icfg`permanent;0f];
  add:{[times;h;d;t;a]
    j:(times binr t)_til times binr t+`timespan$`long$20*h;
    @[d;j;+;a*xexp[0.5;(`float$`long$times[j]-t)%h]]};
  d:add[times;h]/[n#0f;moves`time;(1-perm)*moves`amount];
  moves:`time xasc moves;
  d+:0f^(sums perm*moves`amount) moves[`time] bin times;
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
/ EXECUTION - children against the tape
/ ============================================================

/ lit venues a child is routed to, by share
venues:([]venue:`XNAS`ARCX`BATS`EDGX;share:0.4 0.2 0.2 0.2)

quoteat:{[quotes;t]
  / the quote in force at t (the first quote when t precedes all)
  quotes 0|quotes[`time] bin t
  };

aggressivefills:{[cfg;quotes;t;qty]
  / the fills of an aggressive child of qty sent at t: after latencyms,
  / what the far touch displays fills there and the rest one tick beyond
  / (the book beyond the touch is not modelled: it is taken to hold the
  / rest), both removing liquidity at the same instant, as a sweep does
  / cfg: config dict with `side`latencyms`ticksize
  / quotes: the day's quotes
  / t: send time
  / qty: quantity
  / returns: table `time`price`qty`liquidity
  lat:`timespan$`long$1000000*cfg`latencyms;
  q:.z.m.quoteat[quotes;t+lat];
  buy:cfg[`side]=`BUY;
  touch:$[buy;q`ask;q`bid];
  disp:$[buy;q`asksize;q`bidsize];
  f1:qty&disp;
  f2:qty-f1;
  r:([]time:enlist t+lat;price:enlist touch;qty:enlist f1;liquidity:enlist `R);
  if[f2>0; r,:([]time:enlist t+lat;price:enlist touch+cfg[`ticksize]*$[buy;1;-1];qty:enlist f2;liquidity:enlist `R)];
  select from r where qty>0
  };

passivefills:{[cfg;trades;quotes;t;expiry;qty]
  / a passive child: a limit at the near touch in force after latencyms,
  / behind the size displayed there (its queue). It fills at its limit when
  / prints by the opposite aggressor at or through the limit reach it: each
  / such print takes from the queue first, then from the child. When the
  / near touch moves away from the limit the algo re-pegs, a replace to the
  / new touch behind its displayed size, up to maxreplaces times; after that
  / the child rests where it is. What is left at expiry is cancelled (it
  / rolls into the next child)
  / cfg: config dict with `side`latencyms`maxreplaces
  / trades, quotes: the day's tables
  / t: send time
  / expiry: when the child is cancelled
  / qty: quantity
  / returns: dict `fills (table time price qty liquidity), `events (table
  /   time event qty price leavesqty), `leaves, `replaces, `limit
  lat:`timespan$`long$1000000*cfg`latencyms;
  buy:cfg[`side]=`BUY;
  qt:quotes`time;
  tt:trades`time;
  s:t+lat;
  q0:.z.m.quoteat[quotes;s];
  L:$[buy;q0`bid;q0`ask];
  Q:`float$$[buy;q0`bidsize;q0`asksize];
  leaves:qty;
  replaces:0;
  pegging:1b;
  fls:([]time:`timestamp$();price:`float$();qty:`long$();liquidity:`symbol$());
  events:([]time:t,t+`timespan$`long$500000*cfg`latencyms;event:`new`ack;qty:2#qty;price:2#L;leavesqty:2#qty);
  while[(leaves>0)&s<expiry;
    / the segment ends at the next re-peg (the first later quote whose near
    / touch has moved away from the limit) or at expiry
    segend:expiry;
    repeg:0b;
    if[pegging;
      j:1+qt bin s;
      jend:1+qt bin expiry;
      if[j<jend;
        later:j+til jend-j;
        moved:$[buy;(quotes[`bid] later)>L;(quotes[`ask] later)<L];
        k:first where moved;
        if[not null k; if[qt[later k]<expiry; segend:qt later k; repeg:1b]]]];
    / prints in (s;segend] by the opposite aggressor at or through the limit
    i0:1+tt bin s;
    i1:tt bin segend;
    if[i1>=i0;
      pr:trades i0+til 1+i1-i0;
      w:$[buy;(pr[`aggressor]=`S)&pr[`price]<=L;(pr[`aggressor]=`B)&pr[`price]>=L];
      pr:pr where w;
      if[count pr;
        c:sums `float$pr`qty;
        cum:leaves&`long$0f|c-Q;
        f:deltas cum;
        w:where f>0;
        if[count w;
          fls,:([]time:pr[`time] w;price:count[w]#L;qty:f w;liquidity:count[w]#`A);
          events,:([]time:pr[`time] w;event:count[w]#`fill;qty:f w;price:count[w]#L;leavesqty:leaves-cum w);
          leaves:leaves-last cum];
        Q:0f|Q-last c]];
    s:segend;
    if[(leaves>0)&repeg;
      $[replaces<cfg`maxreplaces;
        [qn:.z.m.quoteat[quotes;s];
         L:$[buy;qn`bid;qn`ask];
         Q:`float$$[buy;qn`bidsize;qn`asksize];
         replaces+:1;
         events,:([]time:enlist s;event:enlist `replace;qty:enlist leaves;price:enlist L;leavesqty:enlist leaves)];
        pegging:0b]]];
  if[0=leaves; events,:([]time:enlist last fls`time;event:enlist `done;qty:enlist 0;price:enlist L;leavesqty:enlist 0)];
  if[leaves>0; events,:([]time:enlist expiry;event:enlist `cancel;qty:enlist leaves;price:enlist L;leavesqty:enlist leaves)];
  `fills`events`leaves`replaces`limit!(fls;events;leaves;replaces;L)
  };

child:{[cfg;trades;quotes;spec]
  / one child order and what became of it
  / cfg: order config dict
  / trades, quotes: the day's tables
  / spec: dict `id`t`expiry`qty`aggressive`venue`interval: the child's id,
  /   send time, expiry, quantity, whether it is aggressive, its venue and
  /   the interval it was sized against
  / returns: dict `children (1-row table) `events (table with childid) `fills (table with childid)
  id:spec`id; t:spec`t; expiry:spec`expiry; qty:spec`qty;
  aggressive:spec`aggressive; venue:spec`venue; interval:spec`interval;
  r:$[aggressive;
    [f:.z.m.aggressivefills[cfg;quotes;t;qty];
     lim:first f`price;
     ev:([]time:t,t+`timespan$`long$500000*cfg`latencyms;event:`new`ack;qty:2#qty;price:2#lim;leavesqty:2#qty);
     ev,:([]time:f`time;event:count[f]#`fill;qty:f`qty;price:f`price;leavesqty:qty-sums f`qty);
     ev,:([]time:enlist last f`time;event:enlist `done;qty:enlist 0;price:enlist lim;leavesqty:enlist 0);
     `fills`events`leaves`replaces`limit!(f;ev;0;0;0n)];
    .z.m.passivefills[cfg;trades;quotes;t;expiry;qty]];
  f:r`fills;
  filled:sum f`qty;
  row:([]childid:enlist id;orderid:enlist cfg`orderid;sym:enlist cfg`sym;side:enlist cfg`side;
    qty:enlist qty;ordtype:enlist $[aggressive;`MKT;`LMT];limitprice:enlist r`limit;venue:enlist venue;
    sendtime:enlist t;expiry:enlist expiry;filledqty:enlist filled;
    status:enlist $[filled=qty;`filled;`cancelled];replaces:enlist r`replaces;interval:enlist interval);
  `children`events`fills!(row;update childid:id from r`events;update childid:id,venue:venue,interval:interval from f)
  };

execute:{[cfg;trades;quotes]
  / the order's children against the tape: one child per scheduled time
  / (jittered), sized by the pacing plus what the previous child left,
  / aggressive with probability spreadcapture and passive otherwise, each
  / routed to a lit venue by share; then a final aggressive child before
  / endtime for whatever is left, so the order completes
  / cfg: order config dict
  / trades, quotes: the day's tables
  / returns: dict `children`events`executions
  sched:.z.m.jittered[cfg;.z.m.schedule cfg];
  n:count sched;
  expiries:(1_sched),cfg`endtime;
  targets:.z.m.sizing[cfg;trades;sched];
  ivals:.z.m.intervals[cfg;sched];
  aggressive:(n?1.0)<cfg`spreadcapture;
  vens:venues[`venue] (sums venues`share) binr n?1.0;
  lat:`timespan$`long$1000000*cfg`latencyms;
  parts:();
  rolled:0;
  i:0;
  while[i<n;
    spec:`id`t`expiry`qty`aggressive`venue`interval!(i+1;sched i;expiries i;rolled+targets i;aggressive i;vens i;ivals i);
    r:.z.m.child[cfg;trades;quotes;spec];
    parts,:enlist r;
    rolled:(rolled+targets i)-sum r[`fills]`qty;
    i+:1];
  if[rolled>0;
    spec:`id`t`expiry`qty`aggressive`venue`interval!(n+1;cfg[`endtime]-2*lat;cfg`endtime;rolled;1b;vens n-1;last ivals);
    r:.z.m.child[cfg;trades;quotes;spec];
    parts,:enlist r];
  children:raze parts[;`children];
  events:`orderid`childid`time xcols update orderid:cfg`orderid from `time xasc raze parts[;`events];
  fls:`time xasc raze parts[;`fills];
  / fill prices on the half-tick grid: on the tick, or exactly at the
  / midpoint (a lit venue cannot print elsewhere)
  grid:0.5*cfg`ticksize;
  fls:update price:grid*floor 0.5+price%grid from fls;
  execs:([]execid:1+til count fls;orderid:count[fls]#cfg`orderid;childid:fls`childid;sym:count[fls]#cfg`sym;
    side:count[fls]#cfg`side;time:fls`time;price:fls`price;qty:fls`qty;venue:fls`venue;
    liquidity:fls`liquidity;capacity:count[fls]#cfg`capacity;interval:fls`interval);
  `children`events`executions!(children;events;execs)
  };


/ ============================================================
/ ASSEMBLY
/ ============================================================

buildorder:{[cfg;quotes;executions]
  / the parent order: an algo order with its arrival price (the mid at
  / starttime), what it filled and its average price
  / cfg: order config dict
  / quotes: the day's quotes
  / executions: its executions
  / returns: 1-row order table
  q:.z.m.quoteat[quotes;cfg`starttime];
  filled:sum executions`qty;
  ([]orderid:enlist cfg`orderid;account:enlist cfg`account;algo:enlist cfg`algo;
    sym:enlist cfg`sym;side:enlist cfg`side;orderqty:enlist cfg`orderqty;
    ordtype:enlist `ALGO;limitprice:enlist 0n;capacity:enlist cfg`capacity;
    starttime:enlist cfg`starttime;endtime:enlist cfg`endtime;
    arrivalprice:enlist 0.5*q[`bid]+q`ask;
    filledqty:enlist filled;
    avgpx:enlist $[filled>0;(sum executions[`price]*executions`qty)%filled;0n];
    status:enlist $[filled=cfg`orderqty;`filled;`partial])
  };

intervals:{[cfg;filltimes]
  / the length of market the child was sized against, one timespan per fill,
  / which impact reads as the interval centred on the child (execs column
  / `interval, see childimpact)
  / cfg: config dict with `starttime`endtime`numfills`pacing
  / filltimes: scheduled fill timestamps from .z.m.schedule
  / returns: timespan per fill
  /
  / pacing `even: the schedule's spacing, window/(numfills+1)
  / pacing `arrival: the sizing interval, window/numfills
  / pacing `frontloaded: each child's bucket, from the previous fill (or
  /   starttime) to its own time
  dur:cfg[`endtime]-cfg`starttime;
  n:count filltimes;
  $[cfg[`pacing]=`even; n#`timespan$`long$dur%n+1;
    cfg[`pacing]=`arrival; n#`timespan$`long$dur%n;
    cfg[`pacing]=`frontloaded; filltimes-(enlist cfg`starttime),-1_filltimes;
    '"intervals: unknown pacing - ",string cfg`pacing]
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
  / returns: dict `orders (the parent, 1 row), `children (one row per
  /   child order), `events (the order's lifecycle: new, ack, replace,
  /   cancel, fill, done) and `executions (the fills)
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
  /   ordresult`orders  / 1-row parent order table
  /   ordresult`executions  / fills
  cfg:.z.m.validate[cfg];
  .z.m.val.hascols[trades;`sym`time`price`qty;"run"];
  .z.m.val.hascols[quotes;`sym`time`bid`ask;"run"];

  / keep only the order's instrument and day, so tables holding several
  / instruments or days (di.simcalendar in memory) can be
  / passed whole, and throw when the market does not cover the order
  trades:.z.m.marketday[cfg;trades;"trades"];
  quotes:.z.m.marketday[cfg;quotes;"quotes"];
  if[cfg[`starttime]<first quotes`time;
    '"run: starttime ",string[cfg`starttime]," is before the first quote at ",string first quotes`time];

  if[not null cfg`seed; system "S ",string cfg`seed];

  r:.z.m.execute[cfg;trades;quotes];
  `orders`children`events`executions!(.z.m.buildorder[cfg;quotes;r`executions];r`children;r`events;r`executions)
  };


/ ============================================================
/ MANY ORDERS - an order flow over instruments and days
/ ============================================================

/ the menu of algorithms generate draws from: the pacing and aggression
/ each stands for, and the arrival-pacing keys where they apply
algos:([algo:`VWAP`IS`AGGRESSIVE`PASSIVE]pacing:`even`arrival`frontloaded`even;spreadcapture:0.1 0.35 0.9 0f;urgency:0n 2 0n 0n;maxpct:0n 0.2 0n 0n)

flowdefaults:`norders`accounts`algos`sizepct`windowminutes`seed`ticksize`jitter`latencyms`maxreplaces`capacity!(5;`ACC1`ACC2`ACC3;`VWAP`IS`AGGRESSIVE`PASSIVE;0.005 0.05;10 60;0N;0.01;0.3;2.0;20;`A)

generate:{[spec;trades;quotes]
  / an order flow: norders orders for every instrument and day in the
  / market, each with a random side, account and algo (from the menu
  / algos, which sets its pacing and aggression), a window of a random
  / length inside the session, a size that is a random share of the day's
  / volume in round lots, one child every 30 seconds, and its own seed
  / spec: dict with any of `norders`accounts`algos`sizepct`windowminutes`seed`ticksize`jitter`latencyms`maxreplaces`capacity
  /   (see flowdefaults for the rest): sizepct and windowminutes are (low;high) ranges,
  /   seed seeds the draws and gives every order its own seed (0N: unseeded)
  / trades, quotes: the market, any instruments and days (`sym`time`qty and `sym`time)
  / returns: a table of order configs, one row per order, the schema's keys
  spec:flowdefaults,spec;
  if[not null spec`seed; system "S ",string spec`seed];
  / one row per instrument and day: the session from the quotes, the volume from the trades
  sessions:select open:first time,close:last time by sym,date:`date$time from `sym`time xasc quotes;
  volumes:select volume:sum qty by sym,date:`date$time from trades;
  days:0!sessions lj volumes;
  n:spec`norders;
  m:n*count days;
  d:days (til m) div n;
  w:`timespan$`long$60000000000*spec[`windowminutes][0]+m?1+spec[`windowminutes][1]-spec[`windowminutes][0];
  room:(d[`close]-d`open)-w+`timespan$0D00:10;
  start:d[`open]+`timespan$0D00:05+`timespan$`long$(m?1.0)*`long$0|room;
  pct:spec[`sizepct][0]+(m?1.0)*spec[`sizepct][1]-spec[`sizepct][0];
  qty:100*1|floor 0.5+(pct*d`volume)%100;
  algo:spec[`algos] m?count spec`algos;
  menu:algos ([]algo:algo);
  seeds:$[null spec`seed; m#0N; 1+(til[m]+7919*spec`seed) mod 2147483647];
  (1_key .z.m.schema) xcols ([]orderid:`$"ORD",/:-4#'"0000",/:string 1+til m;
    sym:d`sym;side:`BUY`SELL m?2;orderqty:qty;starttime:start;endtime:start+w;
    numfills:5|`long$2*w%0D00:01;
    pacing:menu`pacing;spreadcapture:menu`spreadcapture;ticksize:m#spec`ticksize;jitter:m#spec`jitter;
    account:spec[`accounts] m?count spec`accounts;algo:algo;capacity:m#spec`capacity;
    latencyms:m#spec`latencyms;maxreplaces:m#spec`maxreplaces;seed:seeds;
    urgency:menu`urgency;maxpct:menu`maxpct)
  };

runmany:{[cfgs;trades;quotes]
  / run every order of a table of configs (see generate) against the
  / market, each on its own instrument and day, and gather the results;
  / execids are renumbered across the orders
  / cfgs: table of order configs, one row per order
  / trades, quotes: the market, any instruments and days
  / returns: dict `orders`children`events`executions over all the orders
  rs:{[t;q;c] .z.m.run[c;t;q]}[trades;quotes] each cfgs;
  r:`orders`children`events`executions!{[rs;k] raze rs[;k]}[rs] each `orders`children`events`executions;
  r[`executions]:update execid:1+til count r`executions from r`executions;
  r
  };

runflow:{[spec;trades;quotes]
  / generate an order flow over the market and run it
  / spec: see generate
  / trades, quotes: the market, any instruments and days (di.simcalendar's
  /   in-memory result, or its database's tables, serve as they are)
  / returns: dict `configs (the generated order configs) and the tables of runmany
  cfgs:.z.m.generate[spec;trades;quotes];
  (enlist[`configs]!enlist cfgs),.z.m.runmany[cfgs;trades;quotes]
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
schema[`spreadcapture]:   ("F";"probability a child is aggressive (a marketable order crossing the spread) rather than passive (a limit at the near touch): 0=best, 1=worst")
schema[`account]:         ("S";"the account the order is for")
schema[`algo]:            ("S";"the algorithm working the order (a label: VWAP, IS, ...)")
schema[`capacity]:        ("S";"A (agency) or P (principal)")
schema[`latencyms]:       ("F";"milliseconds from a child's send to its arrival at the market (and half of it to its ack)")
schema[`maxreplaces]:     ("J";"how many times a passive child re-pegs to the near touch when it moves away, before resting where it is")
schema[`jitter]:          ("F";"random shift of each child's time, as a share of half the gap to its neighbours, between 0 and 1 (0 = exact schedule)")
schema[`ticksize]:        ("F";"minimum price increment (0.01 for US equities); fill prices sit on the tick or exactly at the midpoint (half ticks)")
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
  / Example:
  /   simorder.describe[]
  ([]param:key .z.m.schema;typ:first each value .z.m.schema;description:last each value .z.m.schema)
  };

/ export public interface
export:([run;runmany;runflow;generate;marketday;schedule;jittered;sizing;intervals;trajectory;capped;validateimpact;dailyvol;childimpact;shiftat;impact;quoteat;aggressivefills;passivefills;child;execute;buildorder;loadconfig;describe])
