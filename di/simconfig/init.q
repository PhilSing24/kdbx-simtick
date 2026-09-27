/ di.simconfig - layered configuration for the di.* simulators

/ four layers, composed in order, a later one overriding an earlier one:
/   market     how a market works (JSON, one file per market)
/   instrument what makes a stock itself (a CSV row: sym, price, drift, vol,
/              tradesperday, and any key it overrides)
/   scenario   what makes a day type (a CSV row of multipliers, jump and
/              regime keys)
/   run        date or calendar, seed, whether to return quotes
/ compose flattens them into the flat dictionary the engines read, casting
/ every value by the schema's type, and throws on a missing key naming the
/ layer that should supply it. A module passes its own schema in.

/ a schema is a dictionary key!(type;layer;group;description):
/   type   S symbol, F float, J long, B boolean, D date, U minute,
/          P timestamp, and SL FL JL for lists of those; * keeps the value
/   layer  essential (the instrument's required keys), market, instrument,
/          scenario, run, optional (cast when present, never required)
/          or derived (computed by the module's compose); a module may
/          name layers of its own, which describe lists after these
/   group  a short label for the reference page (the column grp of describe)


layers:`essential`market`instrument`scenario`run`optional`derived;

candidate:{[relative;dir]
  / the handle of di/simconfig/<relative> under a directory of the module
  / search path (the working directory when the entry is empty)
  :hsym `$$[dir~"";"";dir,"/"],"di/simconfig/",relative;
  };

path:{[relative]
  / the first file at di/simconfig/<relative> in the module search path,
  / so the shipped market, instrument and scenario files are found from
  / any working directory; a loader takes any other path as well
  cands:.z.m.candidate[relative] each .Q.m.SP;
  found:cands where not ()~/:key each cands;
  if[0=count found; '"path: not found in the module search path - ",relative];
  :first found;
  };


/ ============================================================
/ types
/ ============================================================

parseatom:{[base;s]
  / a value from a string (a CSV cell or a JSON string) by its type code
  s:(),s;
  :$[base="S"; `$s;
    base="B"; (lower s) in ("1";"true";"yes";"y");
    base="*"; s;
    base$s];
  };

castlist:{[base;v]
  / a list value: a space-separated string, a list of strings, or a typed list
  / a space-separated string: each piece made a string (a single character
  / would otherwise come back as a char atom)
  if[10h=abs type v; v:{(),x} each " " vs (),v];
  if[(0h=type v)&10h=abs type first v; :$[base="S"; `$v; base$v]];
  :$[base="S"; $[11h=abs type v; v; `$v]; base="F"; `float$v; base="J"; `long$v; base="B"; `boolean$v; v];
  };

cast:{[t;v]
  / cast a value to the schema type t
  base:first t;
  if[base="*"; :v];
  if["L"=last t; :.z.m.castlist[base;v]];
  if[10h=abs type v; :.z.m.parseatom[base;v]];
  if[base="S"; :$[11h=abs type v; v; `$v]];
  :$[base="F"; `float$v; base="J"; `long$v; base="B"; `boolean$v;
    base="D"; `date$v; base="U"; `minute$v; base="P"; `timestamp$v; v];
  };

isnull:{[v]
  / whether a value carries nothing: a null atom, an empty string or list
  :$[0>type v; null v; 0=count v];
  };

nonnull:{[d]
  / the entries of a dictionary that carry a value (an instrument or scenario
  / row: an empty cell is no override)
  if[not 99h=type d; :(`symbol$())!()];
  k:(key d) where not .z.m.isnull each value d;
  :k!d k;
  };


/ ============================================================
/ loaders
/ ============================================================

groupkeys:{[v]
  / the keys of one top-level entry of a market file: the group's own
  / dictionary, or nothing for a scalar
  :$[99h=type v; v; (`symbol$())!()];
  };

flatten:{[d]
  / a JSON document's groups flattened into one dictionary; a top-level
  / scalar is kept as it is
  :raze .z.m.groupkeys each value d;
  };

loadmarket:{[schema;filepath]
  / the market layer: a JSON file whose groups hold the keys, flattened and
  / cast by the schema; an unknown key throws
  if[not -11h=type filepath; '"loadmarket: filepath must be a file handle"];
  d:.j.k raze read0 filepath;
  m:.z.m.flatten d;
  if[count unknown:(key m) except key schema; '"loadmarket: unknown keys - ",", " sv string unknown];
  :key[m]!.z.m.cast'[schema[key m][;0];value m];
  };

csvtype:{[schema;c]
  / the type a CSV column is read with: the name column a symbol, list
  / and starred types a string (compose casts them), the others by the
  / schema
  t:schema[c;0];
  :$[c=`name; "S"; ("L"=last t) or "*"=first t; "*"; first t];
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
  types:.z.m.csvtype[schema] each hdr;
  t:(types;enlist csv) 0: filepath;
  / keyed by a copy of the key column (id), so that a row taken by its key
  / still carries its sym or name among its values
  :`id xkey update id:t[keycol] from t;
  };

loadinstruments:{[schema;filepath]
  / the instrument layer: rows keyed by sym; sym, price, drift, vol and
  / tradesperday are required, every other column is an override
  t:.z.m.loadrows[schema;filepath;`sym];
  req:`price`drift`vol`tradesperday;
  if[count missing:req where not req in cols t; '"loadinstruments: missing columns - ",", " sv string missing];
  if[any raze null (0!t) req; '"loadinstruments: sym, price, drift, vol and tradesperday must be filled on every row"];
  :t;
  };

loadscenarios:{[schema;filepath]
  / the scenario layer: rows keyed by name
  :.z.m.loadrows[schema;filepath;`name];
  };

loadvenues:{[filepath]
  / the venue reference (venues.csv): every venue code the market file can
  / use, keyed by code, with its full name, its type (lit, dark or trf) and
  / the code the TCA application uses for it (null when it has none yet).
  / the engines never read it; exports map codes with it
  if[not -11h=type filepath; '"loadvenues: filepath must be a file handle"];
  hdr:`$csv vs first read0 filepath;
  if[not `code`name`type`tcacode~hdr; '"loadvenues: the columns must be code, name, type, tcacode"];
  t:("S*SS";enlist csv) 0: filepath;
  if[count[t]<>count distinct t`code; '"loadvenues: repeated codes"];
  if[any null t`code; '"loadvenues: every row needs a code"];
  if[not all t[`type] in `lit`dark`trf; '"loadvenues: type must be lit, dark or trf"];
  :`code xkey t;
  };


/ ============================================================
/ compose, save, reload
/ ============================================================

keywithlayer:{[schema;k]
  / a key with the layer that should supply it, for an error message
  :string[k]," (",string[schema[k;1]]," layer)";
  };

compose:{[schema;market;instrument;scenario;run]
  / the flat configuration: market, then the instrument's filled entries,
  / then the scenario's, then the run's; every value cast by the schema;
  / an unknown key throws; a missing key throws naming its layer. Keys of
  / the derived layer are left to the module's own compose, and optional
  / keys are not required. A row's name (its key in its table) is dropped
  ins:.z.m.nonnull instrument;
  sce:.z.m.nonnull scenario;
  if[`name in key ins; ins:delete name from ins];
  if[`name in key sce; sce:delete name from sce];
  cfg:(,/) (market;ins;sce;run);
  if[count unknown:(key cfg) except key schema; '"compose: unknown keys - ",", " sv string unknown];
  cfg:key[cfg]!.z.m.cast'[schema[key cfg][;0];value cfg];
  need:(key schema) where not (value[schema][;1]) in `optional`derived;
  if[count missing:need where not need in key cfg;
    '"compose: missing keys - ",", " sv .z.m.keywithlayer[schema] each missing];
  :cfg;
  };

writejson:{[filepath;cfg]
  / a configuration written as one line of JSON
  filepath 0: enlist .j.j cfg;
  :(::);
  };

caught:{[e]
  / the message of an error trapped, for the caller to signal once it has
  / restored what it changed
  :e;
  };

saveconfig:{[filepath;cfg]
  / the composed configuration as one JSON file, so a run is reproducible
  / from it alone (see loadconfig)
  if[not -11h=type filepath; '"saveconfig: filepath must be a file handle"];
  / floats written at full precision (.j.j follows \P), so the reload replays exactly
  prec:system"P";
  system"P 17";
  r:@[.z.m.writejson filepath;cfg;.z.m.caught];
  system"P ",string prec;
  if[10h=type r; 'r];
  };

loadconfig:{[schema;filepath]
  / a flat configuration from a JSON file written by saveconfig, cast by
  / the schema; an unknown key throws
  if[not -11h=type filepath; '"loadconfig: filepath must be a file handle"];
  d:.j.k raze read0 filepath;
  if[count unknown:(key d) except key schema; '"loadconfig: unknown keys - ",", " sv string unknown];
  :key[d]!.z.m.cast'[schema[key d][;0];value d];
  };

describe:{[schema]
  / the schema as a table, the essential keys first, then by layer (a
  / module's own layers after the known ones, as they appear). The
  / group's column is grp: group is a reserved word, which a query cannot
  / name
  t:([]param:key schema;typ:value[schema][;0];layer:value[schema][;1];grp:value[schema][;2];description:value[schema][;3]);
  t:update ord:.z.m.layers?layer from t;
  :delete ord from `ord xasc t;
  };

/ export public interface
export:([compose;loadmarket;loadinstruments;loadscenarios;loadvenues;loadrows;loadconfig;saveconfig;describe;cast;nonnull;path]);
