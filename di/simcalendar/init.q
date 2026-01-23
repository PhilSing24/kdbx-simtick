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
  / cfg: simtick configuration (with seed:0 to prevent RNG reset)
  / date: trading date
  / returns: trades table for this day
  
  / update config for this day
  daycfg:cfg;
  daycfg[`tradingdate]:date;
  daycfg[`seed]:0;  / prevent simtick from resetting RNG
  
  / run simtick
  result:simtick.run[daycfg];
  
  / handle generatequotes case - extract trades
  $[99h=type result; result`trade; result]
  }

run:{[cfg;calendar]
  / main simulation entry point
  / cfg: simtick configuration dictionary
  / calendar: list of trading dates
  / returns: concatenated trades table across all days
  /
  / Example:
  /   simtick:use`di.simtick
  /   simcalendar:use`di.simcalendar
  /   cfg:simtick.loadconfig[`:di/simtick/presets.csv]`default
  /   calendar:simcalendar.loadcalendar[`:di/simcalendar/calendar.csv]
  /   trades:simcalendar.run[cfg;calendar]
  
  / validate calendar
  calendar:.z.m.validate[calendar];
  
  / set seed once at start - RNG flows naturally across days
  if[cfg[`seed]>0; system "S ",string cfg`seed];
  
  / initialize accumulator
  allTrades:([]time:`timestamp$();price:`float$();qty:`long$());
  currentprice:cfg`startprice;
  
  / iterate through trading days
  i:0;
  while[i<count calendar;
    / update start price for this day
    cfg[`startprice]:currentprice;
    
    / run this day
    trades:.z.m.runday[cfg;calendar i];
    
    / append trades
    allTrades,:trades;
    
    / carry forward closing price (if any trades occurred)
    if[count trades; currentprice:last trades`price];
    
    i+:1
  ];
  
  allTrades
  }

/ ============================================================
/ CALENDAR LOADING
/ ============================================================

loadcalendar:{[filepath]
  / load trading calendar from CSV file
  / filepath: file handle to CSV (e.g., `:calendar.csv)
  / returns: list of dates
  /
  / CSV format: single column named 'date' with dates
  /
  / Example:
  /   calendar:loadcalendar`:di/simcalendar/calendar.csv
  if[not -11h=type filepath; '"loadcalendar: filepath must be a file handle"];
  "D"$1_read0 filepath
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
      "Run multi-day simulation: run[cfg;calendar] -> trades table";
      "Load calendar from CSV: loadcalendar[filepath] -> date list";
      "Validate calendar: validate[calendar] -> calendar or error"
    )
  )
  }

/ export public interface
export:([run;loadcalendar;describe])
