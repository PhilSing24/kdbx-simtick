/ === di.simbook ===
/ L2 Order Book Simulator — Gillespie-based event-driven simulation
/ Produces 5-level depth book data from bottom-up order flow

/ Philosophy: Unlike simtick (top-down, trades first, quotes derived),
/ this module simulates individual order flow and the book state
/ emerges from it. Based on Cont, Stoikov & Talreja (2010).

/ --- Module exports ---
export:`describe`initbook`computeRates`gillespie`applyEvent;

/ --- Module description ---
describe:{[]
  `name`version`description`author!(
    `di.simbook;
    "0.1.0";
    "L2 order book simulator using Gillespie algorithm";
    "PhilSing24"
  )
 };

/ ============================================================
/ BOOK STATE
/ ============================================================
/ The book is a dictionary with two sides.
/ Each side is a dictionary: price -> size
/ This is the entire simulation state.

initbook:{[mid;ticksz;nlevels]
  askpx:mid + ticksz * 1 + til nlevels;
  bidpx:mid - ticksz * 1 + til nlevels;
  / Starting sizes: simple random, 100-lot rounded
  asksz:{100 * 1 + rand 5} each til nlevels;
  bidsz:{100 * 1 + rand 5} each til nlevels;
  `mid`ticksz`nlevels`ask`bid!(
    mid;
    ticksz;
    nlevels;
    askpx!asksz;
    bidpx!bidsz
  )
 };

/ ============================================================
/ PARAMETERS
/ ============================================================
/ Default parameters — these control the book dynamics
/ lambda: limit order arrival base rate
/ kappa:  arrival decay rate (controls how fast arrivals drop off away from BBO)
/ theta:  cancellation rate coefficient (proportional to queue depth)
/ mu:     market order arrival rate (per side)

defaultparams:{[]
  `lambda`kappa`theta`mu`lotsz!(
    1.5;    / limit order arrivals per level per unit time
    0.5;    / exponential decay for arrivals away from mid
    0.6;    / cancellation rate per unit of resting size
    0.3;    / market order rate per side
    100     / lot size for arrivals
  )
 };

/ ============================================================
/ RATE COMPUTATION
/ ============================================================
/ Heart of Gillespie: compute rate for every possible event.
/ With 5 levels per side we have:
/   5 limit arrivals ask + 5 limit arrivals bid
/   + 5 cancellations ask + 5 cancellations bid
/   + 1 market buy + 1 market sell
/   = 22 possible events

/ Layout of the flat rate vector:
/   [0..n-1]     limit arrival ask (level 0 = BBO)
/   [n..2n-1]    limit arrival bid
/   [2n..3n-1]   cancellation ask
/   [3n..4n-1]   cancellation bid
/   [4n]         market buy  (hits best ask)
/   [4n+1]       market sell (hits best bid)

computeRates:{[book;params]
  n:book`nlevels;

  / Limit arrivals: exponential decay away from BBO
  decay:exp neg params[`kappa] * til n;
  limitAsk:params[`lambda] * decay;
  limitBid:params[`lambda] * decay;

  / Cancellations: proportional to queue depth
  / Zero rate where no size is resting
  cancelAsk:params[`theta] * 0f | "f"$value book`ask;
  cancelBid:params[`theta] * 0f | "f"$value book`bid;

  / Market orders: flat rate per side
  mktBuy:enlist params`mu;
  mktSell:enlist params`mu;

  / One flat vector
  limitAsk,limitBid,cancelAsk,cancelBid,mktBuy,mktSell
 };

/ ============================================================
/ GILLESPIE STEP
/ ============================================================
/ Pure function: takes rate vector, returns (dt; eventIndex)
/ Does not touch book state — keeps selection logic testable

gillespie:{[rates]
  totalRate:sum rates;
  / Time to next event: exponential draw
  dt:neg (log 1 - first 1?1f) % totalRate;
  / Which event: weighted draw via cumulative rates
  cumrates:sums rates % totalRate;
  eventix:cumrates binr first 1?1f;
  (dt;eventix)
 };

/ ============================================================
/ EVENT APPLICATION
/ ============================================================
/ Takes book + event index, returns updated book
/ This is where the level-shift logic lives

applyEvent:{[book;params;eventix]
  n:book`nlevels;

  / Decode event type from index position
  / 0..n-1:     limit ask
  / n..2n-1:    limit bid
  / 2n..3n-1:   cancel ask
  / 3n..4n-1:   cancel bid
  / 4n:         market buy
  / 4n+1:       market sell

  $[
    / --- Limit order arrivals ---
    eventix < n;
      addLimit[book;`ask;eventix;params`lotsz];
    eventix < 2*n;
      addLimit[book;`bid;eventix - n;params`lotsz];

    / --- Cancellations ---
    eventix < 3*n;
      cancelOrder[book;`ask;eventix - 2*n];
    eventix < 4*n;
      cancelOrder[book;`bid;eventix - 3*n];

    / --- Market orders ---
    eventix = 4*n;
      marketOrder[book;`ask];   / market buy hits ask
    / else: market sell hits bid
      marketOrder[book;`bid]
  ]
 };

/ --- Add limit order at given level ---
addLimit:{[book;side;levelix;lotsz]
  px:key[book side] levelix;
  book[side;px]+:lotsz;
  book
 };

/ --- Cancel order at given level ---
/ Removes one lot, floor at zero
cancelOrder:{[book;side;levelix]
  px:key[book side] levelix;
  book[side;px]:0| book[side;px] - 100;
  book
 };

/ --- Market order hits best level ---
/ Consumes one lot from level 0 (BBO)
/ If depleted: shift book, spawn new far level
marketOrder:{[book;side]
  px:first key book side;
  book[side;px]:book[side;px] - 100;

  / If BBO depleted, shift the book
  if[0 >= book[side;px];
    book:shiftBook[book;side]
  ];
  book
 };

/ --- Shift book when BBO is depleted ---
/ Remove empty level, add new level at far end
shiftBook:{[book;side]
  ticksz:book`ticksz;

  / Remove the depleted BBO
  book[side]:1 _ book side;

  / Spawn a new level at the far end
  prices:key book side;
  newpx:$[side=`ask;
    last[prices] + ticksz;           / extend ask upward
    first[prices] - ticksz            / extend bid downward — note: bid prices stored high-to-low
  ];
  newsz:100 * 1 + rand 5;
  book[side;newpx]:newsz;

  / Update mid: midpoint between best bid and best ask
  book[`mid]:0.5 * (first key book`ask) + first key book`bid;

  book
 };

/ ============================================================
/ MAIN SIMULATION LOOP (placeholder)
/ ============================================================
/ TODO: wrap gillespie + applyEvent in a loop
/ TODO: accumulate event log as a table
/ TODO: derive L2 snapshots, trades, BBO from event log
/ TODO: add seed management (as per simtick pattern)
/ TODO: add intraday volume profile (as per simtick pattern)

/ Usage:
/   book:initbook[100.0;0.01;5]
/   params:defaultparams[]
/   rates:computeRates[book;params]
/   gillespie[rates]
