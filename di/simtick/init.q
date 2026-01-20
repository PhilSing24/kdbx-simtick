/ di.sim - intraday tick simulator
/ Hawkes process for arrivals, GBM for price

rng.boxmuller:{
  / Box-Muller transform - requires even number of uniforms, produces 2 normals per 2 uniforms
  if[count[x] mod 2; '`length];
  x:2 0N#x;
  r:sqrt -2f*log x 0;
  theta:2f*acos[-1]*x 1;
  x:r*cos theta;
  x,:r*sin theta;
  x
  }

rng.normal:{[n;cfg]
  / dispatcher: get normal samples based on rngmodel
  model:cfg`rngmodel;
  m:2*(n+1) div 2;
  $[model=`pseudo; n#rng.boxmuller[m?1.0];
    '"Unknown rngmodel: ",string model]
  }

shape:{[cfg;progress]
  / intraday intensity multiplier using cosine interpolation
  / transitionpoint controls when to switch from open->mid to mid->close
  / 0.5 = symmetric (U-shape), 0.3 = asymmetric (J-shape)
  openmult:cfg`openmult;
  midmult:cfg`midmult;
  closemult:cfg`closemult;
  tp:cfg`transitionpoint;
  $[progress<tp;
    midmult+(openmult-midmult)*cos progress*acos[-1]%(2*tp);
    midmult+(closemult-midmult)*sin (progress-tp)*acos[-1]%(2*1-tp)]
  }

hawkes.step:{[params;state]
  / single step of Ogata thinning algorithm
  / state: `t`excitation`times
  duration:params`duration;
  lambdamax:params`lambdamax;
  baseintensity:params`baseintensity;
  alpha:params`alpha;
  beta:params`beta;
  cfg:params`cfg;

  / wait time (exponential with rate lambdamax)
  wait:neg log[first 1?1.0]%lambdamax;
  t:state[`t]+wait;

  / check if past duration
  if[t>=duration; :state,enlist[`done]!enlist 1b];

  / decay excitation
  excitation:state[`excitation]*exp neg beta*wait;

  / current intensity
  progress:t%duration;
  lambda0:baseintensity*shape[cfg;progress];
  lambda:lambda0+excitation;

  / accept/reject
  accept:(first 1?1.0)<lambda%lambdamax;
  times:$[accept; state[`times],t; state`times];
  excitation:$[accept; excitation+alpha; excitation];

  `t`excitation`times`done!(t;excitation;times;0b)
  }

arrivals:{[cfg]
  / Ogata thinning algorithm using over iterator
  / returns list of arrival times in seconds from session start
  baseintensity:cfg`baseintensity;
  alpha:cfg`alpha;
  beta:cfg`beta;

  / session duration in seconds
  open:`timespan$cfg`openingtime;
  close:`timespan$cfg`closingtime;
  duration:`long$(close-open)%1000000000;

  / upper bound for intensity (for thinning)
  maxmult:cfg[`openmult]|cfg[`midmult]|cfg`closemult;
  excitationbuffer:1+3*alpha%beta;
  lambdamax:baseintensity*maxmult*excitationbuffer;

  / params for step function
  params:`duration`lambdamax`baseintensity`alpha`beta`cfg!(duration;lambdamax;baseintensity;alpha;beta;cfg);

  / initial state
  init:`t`excitation`times`done!(0f;0f;`float$();0b);

  / run until done
  final:hawkes.step[params]/[{not x`done};init];

  final`times
  }

/ pure GBM return: vol, drift, epsilon, dt -> return factor
gbm:{[s;r;eps;t] exp (t*r-.5*s*s)+eps*s*sqrt t}

pricegbm:{[cfg;dts]
  / GBM price path
  eps:rng.normal[-1+count dts;cfg];
  cfg[`startprice]*prds 1.0,gbm[cfg`vol;cfg`drift;eps;1_ dts]
  }

pricejump:{[cfg;dts]
  / jump-diffusion (Merton): dS/S = μdt + σdW + J·dN
  n:-1+count dts;
  stepdts:1_ dts;

  / diffusion
  eps:rng.normal[n;cfg];
  diffusion:gbm[cfg`vol;cfg`drift;eps;stepdts];

  / jumps: Poisson arrivals, lognormal sizes
  dtdays:stepdts*cfg`tradingdays;
  hasjump:(n?1.0)<1-exp neg cfg[`jumpintensity]*dtdays;
  epsj:rng.normal[n;cfg];
  jumps:exp hasjump*cfg[`jumpmean]+cfg[`jumpvol]*epsj;

  cfg[`startprice]*prds 1.0,diffusion*jumps
  }

price:{[cfg;times]
  / convert times to dt in years
  open:`timespan$cfg`openingtime;
  close:`timespan$cfg`closingtime;
  secsperyear:cfg[`tradingdays]*`long$(close-open)%1000000000;
  dts:deltas[times]%secsperyear;

  $[cfg[`pricemodel]=`jump; pricejump[cfg;dts]; pricegbm[cfg;dts]]
  }

qty.constant:{[n;cfg]
  n#cfg`qty
  }

qty.lognormal:{[n;cfg]
  avgqty:cfg`avgqty;
  qtyvol:cfg`qtyvol;
  mu:log[avgqty]-0.5*qtyvol*qtyvol;
  eps:rng.normal[n;cfg];
  `long$1|floor exp mu+qtyvol*eps
  }

qty.gen:{[n;cfg]
  model:cfg`qtymodel;
  $[model=`constant;  qty.constant[n;cfg];
    model=`lognormal; qty.lognormal[n;cfg];
    '"Unknown qtymodel: ",string model]
  }

quote.generate:{[cfg;trades]
  / generate quote updates between trades
  / each trade has at least one quote before it
  n:count trades;
  if[n=0; :([]time:`timestamp$();bid:`float$();ask:`float$();bidsize:`long$();asksize:`long$())];

  tradetimes:trades`time;
  tradeprices:trades`price;

  / parameters
  basespread:cfg`basespread;
  pretradeoffset:cfg`pretradeoffset;
  quoteupdaterate:cfg`quoteupdaterate;
  avgquotesize:cfg`avgquotesize;

  / initial quote before first trade
  firsttime:tradetimes[0];
  initoffset:`timespan$`long$1000000*pretradeoffset+first 1?100;
  inittime:firsttime-initoffset;
  initprice:tradeprices[0];
  initspread:basespread*initprice*cfg`spreadopenmult;

  initbid:initprice-initspread%2;
  initask:initprice+initspread%2;

  / initial state
  init:`times`bids`asks`bidsizes`asksizes`prevtime`prevbid`prevask!(
    enlist inittime;
    enlist initbid;
    enlist initask;
    enlist avgquotesize;
    enlist avgquotesize;
    inittime;
    initbid;
    initask
  );

  / params for step function
  params:`cfg`basespread`pretradeoffset`quoteupdaterate`avgquotesize`tradetimes`tradeprices!(
    cfg;basespread;pretradeoffset;quoteupdaterate;avgquotesize;tradetimes;tradeprices
  );

  / process each trade using over
  final:quote.step[params]/[init;til n];

  / build and sort quote table
  quotes:([]time:final`times;bid:final`bids;ask:final`asks;bidsize:final`bidsizes;asksize:final`asksizes);
  quotes:update bidsize:1|bidsize, asksize:1|asksize from quotes;
  `time xasc quotes
  }

quote.step:{[params;state;i]
  / process single trade - generate quotes before it
  cfg:params`cfg;
  basespread:params`basespread;
  pretradeoffset:params`pretradeoffset;
  quoteupdaterate:params`quoteupdaterate;
  avgquotesize:params`avgquotesize;

  tradetime:params[`tradetimes][i];
  tradeprice:params[`tradeprices][i];

  prevtime:state`prevtime;
  prevbid:state`prevbid;
  prevask:state`prevask;

  / time gap in ms
  gap:`long$(tradetime-prevtime)%1000000;

  / number of intermediate updates
  nupdates:`long$floor quoteupdaterate*gap%1000;
  nupdates:nupdates&10;

  / generate intermediate quotes (vectorized)
  state:$[nupdates>0;
    quote.intermediate[params;state;tradetime;tradeprice;gap;nupdates];
    state
  ];

  / quote just before trade
  randoffset:first 1?pretradeoffset;
  pretime:tradetime-`timespan$`long$(pretradeoffset+randoffset)*1000000;

  spread:basespread*tradeprice*quote.spreadmult[cfg;tradetime];
  bid:tradeprice-spread%2;
  ask:tradeprice+spread%2;
  bidsize:avgquotesize+`long$100*first rng.boxmuller[2?1.0];
  asksize:avgquotesize+`long$100*first rng.boxmuller[2?1.0];

  / append and update state
  state[`times],:pretime;
  state[`bids],:bid;
  state[`asks],:ask;
  state[`bidsizes],:bidsize;
  state[`asksizes],:asksize;
  state[`prevtime]:pretime;
  state[`prevbid]:bid;
  state[`prevask]:ask;
  state
  }

quote.intermediate:{[params;state;tradetime;tradeprice;gap;nupdates]
  / generate intermediate quote updates (vectorized)
  basespread:params`basespread;
  pretradeoffset:params`pretradeoffset;
  avgquotesize:params`avgquotesize;
  cfg:params`cfg;

  prevtime:state`prevtime;
  prevbid:state`prevbid;
  prevask:state`prevask;

  / candidate times
  updatetimes:prevtime+`timespan$`long$(1+til nupdates)*1000000*gap%nupdates+1;

  / filter times before trade offset
  cutoff:tradetime-`timespan$`long$pretradeoffset*1000000;
  mask:updatetimes<cutoff;
  validtimes:updatetimes where mask;
  nvalid:count validtimes;

  if[nvalid=0; :state];

  / generate random movements
  eps:rng.normal[nvalid;cfg];
  midmove:0.0001*tradeprice*sums eps;
  spreadvar:1+0.1*abs rng.normal[nvalid;cfg];

  / compute quotes vectorized
  mids:(prevbid+prevask)%2+midmove;
  sps:basespread*mids*spreadvar;
  bids:mids-sps%2;
  asks:mids+sps%2;

  / sizes
  epssize:rng.normal[2*nvalid;cfg];
  bidsizes:avgquotesize+`long$100*nvalid#epssize;
  asksizes:avgquotesize+`long$100*nvalid _ epssize;

  / append to state
  state[`times],:validtimes;
  state[`bids],:bids;
  state[`asks],:asks;
  state[`bidsizes],:bidsizes;
  state[`asksizes],:asksizes;
  state[`prevbid]:last bids;
  state[`prevask]:last asks;
  state
  }

quote.spreadmult:{[cfg;t]
  / spread multiplier based on time of day
  opentime:`timespan$cfg`openingtime;
  closetime:`timespan$cfg`closingtime;
  duration:closetime-opentime;

  / get time portion of timestamp as timespan
  timeofday:t-`timestamp$`date$t;  / nanoseconds since midnight

  progress:(timeofday-opentime)%duration;
  progress:0f|progress&1f;

  $[progress<0.5;
    cfg[`spreadopenmult]+(cfg[`spreadmidmult]-cfg`spreadopenmult)*2*progress;
    cfg[`spreadmidmult]+(cfg[`spreadclosemult]-cfg`spreadmidmult)*2*(progress-0.5)]
  }

validate:{[cfg]
  / validate config
  / check stability
  if[cfg[`alpha]>=cfg`beta; '"Hawkes unstable: alpha must be < beta"];
  / check multipliers positive
  if[0>=min[cfg`openmult`midmult`closemult]; '"Multipliers must be positive"];
  / check base intensity
  if[0>=cfg`baseintensity; '"baseintensity must be positive"];
  cfg
  }

run:{[cfg]
  / main simulation entry point
  cfg:validate[cfg];

  / set seed for reproducibility
  if[cfg[`seed]>0; system "S ",string cfg`seed];

  / generate arrival times (seconds from open)
  arrs:arrivals[cfg];
  n:count arrs;

  if[n=0;
    trades:([]time:`timestamp$();price:`float$();qty:`long$());
    :$[cfg`generatequotes;
      `trade`quote!(trades;([]time:`timestamp$();bid:`float$();ask:`float$();bidsize:`long$();asksize:`long$()));
      trades]
  ];

  / convert to timestamps
  basetime:cfg[`tradingdate]+`timespan$cfg`openingtime;
  times:basetime+`timespan$`long$arrs*1000000000;

  / generate prices
  prices:price[cfg;arrs];

  / generate quantities
  qtys:qty.gen[n;cfg];

  trades:([]time:times;price:prices;qty:qtys);

  / return trades only or dictionary with quotes
  $[cfg`generatequotes;
    `trade`quote!(trades;quote.generate[cfg;trades]);
    trades]
  }

/ CSV type string for config file
csvtypes:"SDUUFJSFFJSFFFFFFFFFFSJFBFFFFJFJ"

loadconfig:{[filepath]
  / load config CSV as keyed table
  1!(csvtypes;enlist csv) 0: filepath
  }

/ export public interface
export:([run;arrivals;price;loadconfig])
