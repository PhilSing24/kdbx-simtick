/ di.simcalendar - multi-day tick simulation over trading calendar

/ load simtick module
simtick:use`di.simtick

/ ============================================================
/ VALIDATION
/ ============================================================

validate:{[calendar]
  / validate calendar input
  / calendar: list of dates
  / returns: calendar if valid, throws error otherwise

  / must be date list
  if[not 14h=type calendar; '"validate: calendar must be a date list"];

  / non-empty
  if[0=count calendar; '"validate: calendar cannot be empty"];

  / no duplicates
  if[count[calendar]<>count distinct calendar; '"validate: calendar contains duplicates"];

  / sorted ascending
  if[not calendar~asc calendar; '"validate: calendar must be sorted ascending"];

  calendar
  }

/ ============================================================
/ CORE SIMULATION
/ ============================================================

runday:{[cfg;date]
  / run single day simulation
  / cfg: simtick configuration (with seed:0N to prevent RNG reset)
  / date: trading date
  / returns: trade table, or dict with `trade`quote if generatequotes=1b

  / update config for this day
  daycfg:cfg;
  daycfg[`tradingdate]:date;
  daycfg[`seed]:0N;  / prevent simtick from resetting RNG (0N = no seed)

  / run simtick - return full result (trade only or trade+quote dict)
  simtick.run[daycfg]
  }

persist:{[dst;date;result]
  daypath:hsym`$string[dst],"/",string date;

  $[99h=type result;
    [
      .Q.dd[daypath;`$"trade/"] set .Q.en[dst] result`trade;
      .Q.dd[daypath;`$"quote/"] set .Q.en[dst] result`quote
    ];
    .Q.dd[daypath;`$"trade/"] set .Q.en[dst] result
  ]
  }

  
run:{[cfg;calendar;dbpath]
  / main simulation entry point
  / cfg: simtick configuration dictionary
  / calendar: list of trading dates
  / dbpath: file handle for disk persistence (e.g. `:/tmp/mydb), or (::) for in-memory
  / returns: trades table if in-memory, dbpath if persisting to disk
  /
  / Example (in-memory):
  /   trades:simcalendar.run[cfg;calendar;(::)]
  /
  / Example (persist to disk):
  /   simcalendar.run[cfg;calendar;`:/tmp/mydb]

  / validate calendar
  calendar:.z.m.validate[calendar];

  / resolve whether to persist
  topersist:not (::)~dbpath;
  dst:$[topersist; hsym`$string dbpath; (::)];

  / set seed once at start - RNG flows naturally across days (0N = no seed)
  if[not null cfg`seed; system "S ",string cfg`seed];

  / initialize in-memory accumulators (only used if not persisting)
  / collect daily tables as a list, raze once at end to avoid O(n^2) row copies
  allTradesList:();
  allQuotesList:();
  currentprice:cfg`startprice;

  / iterate through trading days
  i:0;
  while[i<count calendar;
    / update start price for this day
    cfg[`startprice]:currentprice;

    / run this day
    result:.z.m.runday[cfg;calendar i];

    / extract trades for price carry-forward
    trades:$[99h=type result; result`trade; result];

    $[topersist;
      / write to disk
      .z.m.persist[dst;calendar i;result];
      / accumulate in memory
      [
        allTradesList,:enlist trades;
        if[99h=type result; allQuotesList,:enlist result`quote]
      ]
    ];

    / carry forward closing price (if any trades occurred)
    if[count trades; currentprice:last trades`price];

    i+:1
  ];

  / return dbpath or in-memory result
  $[topersist;
    dbpath;
    $[cfg`generatequotes;
      `trade`quote!(raze allTradesList;raze allQuotesList);
      raze allTradesList]
  ]
  }

/ ============================================================
/ CALENDAR LOADING
/ ============================================================

loadcalendar:{[filepath]
  / load trading calendar from CSV file
  / filepath: file handle to CSV (e.g., `:calendar.csv)
  / returns: validated list of dates (errors on malformed input)
  /
  / CSV format: single column named 'date' with dates
  /
  / Example:
  /   calendar:loadcalendar`:di/simcalendar/calendar.csv
  if[not -11h=type filepath; '"loadcalendar: filepath must be a file handle"];
  .z.m.validate "D"$1_read0 filepath
  }

/ ============================================================
/ INTROSPECTION
/ ============================================================

describe:{[]
  / return module description
  / Example:
  /   simcalendar.describe[]
  ([]
    function:`run`loadcalendar`validate;
    description:(
      "Run multi-day simulation: run[cfg;calendar;dbpath] -> trades table or dbpath";
      "Load calendar from CSV: loadcalendar[filepath] -> date list";
      "Validate calendar: validate[calendar] -> calendar or error"
    )
  )
  }

/ export public interface
export:([run;loadcalendar;describe;validate])
