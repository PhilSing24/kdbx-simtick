/ hashes of a set of generated outputs, one line per output: name and md5
/ used to show that a change which must not alter behaviour did not: take
/ the hashes of a reference (tools/baseline.sh), then compare the working
/ tree with them (tools/compare.sh)
/ usage: q tools/hashes.q -q          (HASHTMP names a scratch directory, default /tmp)
/ covers di.simtick, di.simtick.config and di.simmarket; the modules are
/ found on QPATH, so the first root on QPATH is the code that is hashed

simtick:use`di.simtick;
simmarket:use`di.simmarket;
simconfig:use`di.simtick.config;

/ a silent logger where the module asks for one (a reference older than init has none)
quiet:{[ctx;msg]};
if[`init in key simmarket; simmarket.init[(enlist `log)!enlist `info`warn`error!(quiet;quiet;quiet)]];

h:{[name;x] -1 name," ",raze string md5 raze string -8!x;};
tmp:{[name] hsym `$$[count d:getenv `HASHTMP;d;"/tmp"],"/",name};

/ one day: di.simtick
f:simtick.files[];
market:simtick.loadmarket f`market;
ins:simtick.loadinstruments f`instruments;
sce:simtick.loadscenarios f`scenarios;
run:`seed`generatequotes!(42;1b);
small:update jumpburst:100 from update tradesperday:20000 from ins;
c1:simtick.compose[market;small`NVDA;sce`normal;run];
h["compose NVDA normal";c1];
h["run NVDA normal";simtick.run c1];
h["run XOM volatile";simtick.run simtick.compose[market;small`XOM;sce`volatile;run]];
h["run PG jumpy";simtick.run simtick.compose[market;small`PG;sce`jumpy;run]];
h["run bare five values";simtick.run simtick.compose[market;`sym`price`drift`vol`tradesperday!(`ACME;100.0;0.05;0.3;20000);sce`normal;run]];
h["run calendar clock lognormal";simtick.run c1 upsert `clock`qtymodel!`calendar`lognormal];
h["arrivals";{system "S 7"; simtick.arrivals x} c1];
h["price";{system "S 7"; simtick.price[x;100*til 200]} c1];
sgx:simtick.loadmarket simconfig.path "markets/sgx.json";
sgi:simtick.loadinstruments simconfig.path "instruments_sg.csv";
h["run SGX D05";simtick.run simtick.compose[sgx;sgi`D05;sce`normal;run]];
hk:simtick.loadmarket simconfig.path "markets/hkex.json";
hki:simtick.loadinstruments simconfig.path "instruments_hk.csv";
h["run HKEX 0005";simtick.run simtick.compose[hk;(hki`0005) upsert `tradesperday`jumpburst!(20000;100);sce`normal;run]];
h["describe simtick";simtick.describe[]];
h["describe simmarket";simmarket.describe[]];
h["factorday";simtick.factorday c1];
h["saved config";{[x] j:tmp "hashes_cfg.json"; simtick.saveconfig[j;x]; simtick.loadconfig j} c1];

/ several days and stocks: di.simmarket, in memory
thin:update jumpburst:30 from update tradesperday:5000 from ins;
cfgs:simmarket.compose[market;thin;sce;`NVDA`XOM`PG`MSFT!`normal`normal`volatile`normal;run];
cal:simmarket.loadcalendar hsym `$(.Q.m.mp `di.simmarket),"/calendar.csv";
h["runmany memory";simmarket.runmany[cfgs;cal;(::)]];
h["run memory PG";simmarket.run[cfgs`PG;cal;(::)]];
h["regimes";simmarket.regimes[cfgs`NVDA;cal]];
h["correlations";simmarket.correlations cfgs];
h["nysecalendar 2026";simmarket.nysecalendar[2026.01.01;2026.12.31]];
halfday:([]date:2026.08.18 2026.08.19;closingtime:12:00 17:00);
h["sgx runmany half day";simmarket.runmany[simmarket.compose[sgx;sgi;sce;`normal;`seed`generatequotes!(42;0b)];halfday;(::)]];

/ the database: two dates written, then resumed on the full calendar
db:tmp "hashes_hdb";
system "rm -rf ",1_string db;
simmarket.writehdb[cfgs;2#cal;db;(`symbol$())!()];
simmarket.writehdb[cfgs;cal;db;(`symbol$())!()];
/ a partition read into memory, its enumerated columns as symbols, so the hash
/ does not depend on where the database sits
part:{[db;d;t]
  s:get .Q.dd[db;`sym];
  x:get .Q.dd[.Q.par[db;d;t];`];
  :flip cols[x]!{[s;v] $[type[v] within 20 76h;s `long$v;v til count v]}[s] each x cols x;
  };
h["hdb trade 08.19";part[db;2026.08.19;`trade]];
h["hdb days 08.20";part[db;2026.08.20;`days]];
h["hdb quote 08.20";part[db;2026.08.20;`quote]];
h["loadrun";`commit _ simmarket.loadrun db];
system "rm -rf ",(1_string db)," ",1_string tmp "hashes_cfg.json";
exit 0
