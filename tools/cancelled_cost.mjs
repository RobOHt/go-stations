// How much reading GO's cancellations costs the Worker: the GTFS trip updates
// (about 700 KB) and the train exceptions parsed and gone through, as
// cancelledTrains() in worker/src/index.js does on every look. The Workers free
// plan allows 10 ms of CPU a request. Run by the probe workflow (cancellations).
import { cancellations } from "../worker/src/live.js";

const key = process.env.METROLINX_API_KEY;
const base = "https://api.openmetrolinx.com/OpenDataAPI/api/V1";

async function get(path) {
  const response = await fetch(`${base}${path}?key=${encodeURIComponent(key)}`, { headers: { Accept: "application/json" } });
  return response.text();
}

const [exceptions, updates] = await Promise.all([get("/ServiceUpdate/Exceptions/Train"), get("/Gtfs/Feed/TripUpdates")]);
for (let look = 1; look <= 3; look++) {
  const start = process.cpuUsage();
  const trips = cancellations(JSON.parse(exceptions), JSON.parse(updates));
  const used = process.cpuUsage(start);
  const ms = (used.user + used.system) / 1000;
  console.log(`Look ${look}: ${Math.round((exceptions.length + updates.length) / 1024)} KB read in ${ms.toFixed(1)} ms of CPU,`,
              `${trips.length} trains cancelled or skipping stations`);
}
