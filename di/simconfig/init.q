/ di.simconfig - layered configuration for the di.* simulators

/ Four layers, composed in order, a later one overriding an earlier one:
/   market     how a market works (JSON, one file per market)
/   instrument what makes a stock itself (a CSV row: sym, price, drift, vol,
/              tradesperday, and any key it overrides)
/   scenario   what makes a day type (a CSV row of multipliers, jump and
/              regime keys)
/   run        date or calendar, seed, whether to return quotes
/ compose flattens them into the flat dictionary the engines read, casting
/ every value by the schema's type, and throws on a missing key naming the
/ layer that should supply it. A module passes its own schema in.

/ A schema is a dictionary key!(type;layer;group;description):
/   type   S symbol, F float, J long, B boolean, D date, U minute,
/          P timestamp, and SL FL JL for lists of those; * keeps the value
/   layer  essential (the instrument's required keys), market, instrument,
/          scenario, run or derived (computed by the module's compose)
/   group  a short label for the reference page


layers:`essential`market`instrument`scenario`run`derived

path:{[relative]
  / the first file at di/simconfig/<relative> in the module search path,
  / so the shipped market, instrument and scenario files are found from
  / any working directory; a loader takes any other path as well
  cands:{[r;p] hsym `$$[p~"";"";p,"/"],"di/simconfig/",r}[relative] each .Q.m.SP;
  found:cands where not ()~/:key each cands;
  if[0=count found; '"path: not found in the module search path - ",relative];
  first found
  };


/ ============================================================
/ TYPES
/ ============================================================

parseatom:{[base;s]
  / a value from a string (a CSV cell or a JSON string) by its type code
  s:(),s;
  $[base="S"; `$s;
    base="B"; (lower s) in ("1";"true";"yes";"y");
    base="*"; s;
    base$s]
  };

castlist:{[base;v]
  / a list value: a space-separated string, a list of strings, or a typed list
  / a space-separated string: each piece made a string (a single character
  / would otherwise come back as a char atom)
  if[10h=abs type v; v:{(),x} each " " vs (),v];
  if[(0h=type v)&10h=abs type first v; :$[base="S"; `$v; base$v]];
  $[base="S"; $[11h=abs type v; v; `$v]; base="F"; `float$v; base="J"; `long$v; base="B"; `boolean$v; v]
  };

cast:{[t;v]
  / cast a value to the schema type t
  base:first t;
  if[base="*"; :v];
  if["L"=last t; :.z.m.castlist[base;v]];
  if[10h=abs type v; :.z.m.parseatom[base;v]];
  if[base="S"; :$[11h=abs type v; v; `$v]];
  $[base="F"; `float$v; base="J"; `long$v; base="B"; `boolean$v;
    base="D"; `date$v; base="U"; `minute$v; base="P"; `timestamp$v; v]
  };

isnull:{[v]
  / whether a value carries nothing: a null atom, an empty string or list
  $[0>type v; null v; 0=count v]
  };

nonnull:{[d]
  / the entries of a dictionary that carry a value (an instrument or scenario
  / row: an empty cell is no override)
  if[not 99h=type d; :(`symbol$())!()];
  k:(key d) where not .z.m.isnull each value d;
  k!d k
  };


/ ============================================================
/ LOADERS
/ ============================================================

flatten:{[d]
  / a JSON document's groups flattened into one dictionary; a top-level
  / scalar is kept as it is
  raze {[v] $[99h=type v; v; (`symbol$())!()]} each value d
  };

loadmarket:{[schema;filepath]
  / the market layer: a JSON file whose groups hold the keys, flattened and
  / cast by the schema; an unknown key throws
  if[not -11h=type filepath; '"loadmarket: filepath must be a file handle"];
  d:.j.k raze read0 filepath;
  m:.z.m.flatten d;
  if[count unknown:(key m) except key schema; '"loadmarket: unknown keys - ",", " sv string unknown];
  key[m]!.z.m.cast'[schema[key m][;0];value m]
  };

loadrows:{[schema;filepath;keycol]
  / a CSV of rows keyed by keycol (instruments by sym, scenarios by name):
  / columns are typed by the schema, list and starred types read as strings
  / that compose casts, and an empty cell is no override. The table is
  / keyed by a copy of the key column, so instruments`NVDA is the whole row
  if[not -11h=type filepath; '"loadrows: filepath must be a file handle"];
  hdr:`$csv vs first read0 filepath;
  if[not keycol in hdr; '"loadrows: the CSV must have a ",string[keycol]," column"];
  if[count unknown:hdr except keycol,key schema; '"loadrows: unknown columns - ",", " sv string unknown];
  types:{[schema;c] t:schema[c;0]; $[c=`name; "S"; ("L"=last t) or "*"=first t; "*"; first t]}[schema] each hdr;
  t:(types;enlist csv) 0: filepath;
  / keyed by a copy of the key column (id), so that a row taken by its key
  / still carries its sym or name among its values
  `id xkey update id:t[keycol] from t
  };

loadinstruments:{[schema;filepath]
  / the instrument layer: rows keyed by sym; sym, price, drift, vol and
  / tradesperday are required, every other column is an override
  t:.z.m.loadrows[schema;filepath;`sym];
  req:`price`drift`vol`tradesperday;
  if[count missing:req where not req in cols t; '"loadinstruments: missing columns - ",", " sv string missing];
  if[any raze null (0!t) req; '"loadinstruments: sym, price, drift, vol and tradesperday must be filled on every row"];
  t
  };

loadscenarios:{[schema;filepath]
  / the scenario layer: rows keyed by name
  .z.m.loadrows[schema;filepath;`name]
  };


/ ============================================================
/ COMPOSE, SAVE, RELOAD
/ ============================================================

compose:{[schema;market;instrument;scenario;run]
  / the flat configuration: market, then the instrument's filled entries,
  / then the scenario's, then the run's; every value cast by the schema;
  / an unknown key throws; a missing key throws naming its layer. Keys of
  / the derived layer are left to the module's own compose
  ins:.z.m.nonnull instrument;
  sce:.z.m.nonnull scenario;
  if[`name in key sce; sce:delete name from sce];
  cfg:(,/) (market;ins;sce;run);
  if[count unknown:(key cfg) except key schema; '"compose: unknown keys - ",", " sv string unknown];
  cfg:key[cfg]!.z.m.cast'[schema[key cfg][;0];value cfg];
  need:(key schema) where not (value[schema][;1]) in `derived;
  if[count missing:need where not need in key cfg;
    '"compose: missing keys - ",", " sv {[schema;k] string[k]," (",string[schema[k;1]]," layer)"}[schema] each missing];
  cfg
  };

saveconfig:{[filepath;cfg]
  / the composed configuration as one JSON file, so a run is reproducible
  / from it alone (see loadconfig)
  if[not -11h=type filepath; '"saveconfig: filepath must be a file handle"];
  filepath 0: enlist .j.j cfg
  };

loadconfig:{[schema;filepath]
  / a flat configuration from a JSON file written by saveconfig, cast by
  / the schema; an unknown key throws
  if[not -11h=type filepath; '"loadconfig: filepath must be a file handle"];
  d:.j.k raze read0 filepath;
  if[count unknown:(key d) except key schema; '"loadconfig: unknown keys - ",", " sv string unknown];
  key[d]!.z.m.cast'[schema[key d][;0];value d]
  };

describe:{[schema]
  / the schema as a table, the essential keys first, then by layer
  / group is a q keyword, so the column is built under another name and renamed
  t:([]param:key schema;typ:value[schema][;0];layer:value[schema][;1];grp:value[schema][;2];description:value[schema][;3]);
  t:update ord:(`essential`market`instrument`scenario`run`derived)?layer from t;
  `param`typ`layer`group`description xcol delete ord from `ord xasc t
  };

/ export public interface
export:([compose;loadmarket;loadinstruments;loadscenarios;loadrows;loadconfig;saveconfig;describe;cast;nonnull;path])
