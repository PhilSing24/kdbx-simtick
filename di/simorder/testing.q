/ testing.q - quick manual test script for di.simorder
/ Run with: q di/simorder/testing.q   (from the kdbx-modules root, with QPATH set)

simtick:use`di.simtick
simorder:use`di.simorder

/ generate one day of market data (generatequotes defaults to 1 as of presets.csv update)
tickcfgs:simtick.loadconfig`:di/simtick/presets.csv
tickcfg:tickcfgs`nvda_default
result:simtick.run[tickcfg]
trades:result`trade
quotes:result`quote

-1"trades: ",string[count trades]," rows, quotes: ",string[count quotes]," rows";

/ load good/bad order presets
ordcfgs:simorder.loadconfig`:di/simorder/presets.csv
ordresult:simorder.run[ordcfgs`good;trades;quotes]
badresult:simorder.run[ordcfgs`bad;trades;quotes]

/ sanity checks
-1"good qty total: ",string sum ordresult[`executions]`qty;
-1"bad  qty total: ",string sum badresult[`executions]`qty;

vwap:{[e](sum e[`price]*e[`qty])%sum e`qty};
goodvwap:vwap ordresult`executions;
badvwap:vwap badresult`executions;
arrival:first ordresult[`order]`arrivalprice;

-1"arrival price: ",string arrival;
-1"good VWAP: ",string[goodvwap]," (",string[10000*(goodvwap-arrival)%arrival]," bps)";
-1"bad  VWAP: ",string[badvwap]," (",string[10000*(badvwap-arrival)%arrival]," bps)";
-1"gap (bad-good): ",string[10000*(badvwap-goodvwap)%arrival]," bps";
