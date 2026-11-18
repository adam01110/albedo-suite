import { createRequire } from "node:module";
import readline from "node:readline";
import { Worker } from "node:worker_threads";
const { FileFinder } = createRequire(import.meta.url)("@ff-labs/fff-node");
if (process.argv[2] !== "--stdio")
  throw new Error("FFF requires daemon-owned --stdio transport");
const roots = new Map();
let watchdogDeadline = null;
const unwrap = (r) => {
  if (!r.ok) throw new Error(r.error);
  return r.value;
};
async function finder(root) {
  let f = roots.get(root);
  if (!f) {
    if (roots.size >= 4) {
      const key = roots.keys().next().value;
      roots.get(key).destroy();
      roots.delete(key);
    }
    f = unwrap(
      FileFinder.create({
        basePath: root,
        disableWatch: true,
        disableMmapCache: true,
        disableContentIndexing: true,
        aiMode: true,
      }),
    );
    roots.set(root, f);
  } else unwrap(f.scanFiles());
  // Preserve the SDK readiness barrier without its fixed 50-ms poll delay.
  const deadline = Date.now() + 20000;
  while (true) {
    const progress = unwrap(f.getScanProgress());
    if (!progress.isScanning && progress.isWarmupComplete) break;
    if (Date.now() >= deadline) throw new Error("FFF scan timed out");
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  return f;
}
async function request(q) {
  if (q.protocol !== 1)
    throw new Error("FFF protocol mismatch: expected version 1");
  if (!["find", "paths", "fuzzy", "close"].includes(q.op))
    throw new Error("Unknown FFF operation");
  if (q.op === "close") {
    setImmediate(shutdown);
    return {};
  }
  const f = await finder(q.root);
  if (q.file) {
    let page = 0,
      present = false,
      count;
    do {
      const listed = unwrap(
        f.glob(q.fileGlob || "**/*", { pageIndex: page, pageSize: 1000 }),
      );
      count = listed.items.length;
      // FFF 0.11 uses an item offset, despite naming this option pageIndex.
      page += count;
      present = listed.items.some((item) => item.relativePath === q.file);
    } while (!present && count === 1000);
    if (!present)
      throw new Error(
        "Explicit file is excluded from the FFF index (hidden/ignored/unsupported file): " +
          q.file,
      );
  }
  const filters = q.filters.map((g) => ({
    regex: new RegExp(g.regex),
    include: g.include,
  }));
  const eligible = (p) => {
    if (
      (q.file && p !== q.file) ||
      (!q.hidden && p.split("/").some((s) => s.startsWith(".")))
    )
      return false;
    let allowed = !filters.some((g) => g.include);
    for (const g of filters) if (g.regex.test(p)) allowed = g.include;
    return allowed;
  };
  const items = [];
  let total = 0;
  let searched = 0;
  if (q.op === "find") {
    let cursor = null;
    do {
      const r = unwrap(
        f.grep(q.query, {
          mode: "regex",
          smartCase: false,
          maxFileSize: 1073741824,
          maxMatchesPerFile: q.limit + 1,
          pageSize: q.limit + 1,
          beforeContext: q.context,
          afterContext: q.context,
          cursor,
        }),
      );
      if (r.regexFallbackError)
        throw new Error("Unsupported regex: " + r.regexFallbackError);
      searched += r.totalFilesSearched;
      for (const item of r.items)
        if (eligible(item.relativePath)) {
          total++;
          if (items.length < q.limit + 1)
            items.push({
              relativePath: item.relativePath,
              lineNumber: item.lineNumber,
              lineContent: item.lineContent.slice(0, 640),
              contextBefore: (item.contextBefore || []).map((s) =>
                s.slice(0, 640),
              ),
              contextAfter: (item.contextAfter || []).map((s) =>
                s.slice(0, 640),
              ),
            });
        }
      cursor = r.nextCursor;
    } while (cursor && total <= q.limit);
  } else {
    let pageIndex = 0;
    let count;
    do {
      const r = unwrap(
        q.op === "fuzzy"
          ? f.fileSearch(q.query, { pageIndex, pageSize: 1000 })
          : f.glob(q.nativeGlob || "**/*", { pageIndex, pageSize: 1000 }),
      );
      count = r.items.length;
      for (const item of r.items)
        if (
          eligible(item.relativePath) &&
          (!q.name ||
            new RegExp(q.name, "i").test(
              q.nameBase ? item.fileName : item.relativePath,
            ))
        ) {
          total++;
          if (items.length < q.limit + 1) items.push(item);
        }
      // Advance by returned items: pageIndex is a native item offset.
      pageIndex += count;
    } while (count === 1000 && total <= q.limit);
  }
  return {
    workerPid: process.pid,
    items,
    total,
    searched,
    freshness: "rescan barrier; concurrent filesystem changes are not atomic",
  };
}
let queue = Promise.resolve();
function shutdown() {
  if (watchdogDeadline)
    Atomics.store(watchdogDeadline, 0, BigInt(Date.now() + 2000));
  for (const f of roots.values()) f.destroy();
  roots.clear();
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
// A separate thread bounds native calls even while the main event loop is blocked.
const deadline = (watchdogDeadline = new BigInt64Array(
  new SharedArrayBuffer(8),
));
new Worker(
  `
    const { workerData } = require('node:worker_threads');
    const deadline = new BigInt64Array(workerData);
    setInterval(() => {
      const until = Atomics.load(deadline, 0);
      if (until && BigInt(Date.now()) >= until) process.kill(process.pid, 'SIGKILL');
    }, 100).unref();
    require('node:worker_threads').parentPort.on('message', () => {});
  `,
  { eval: true, workerData: deadline.buffer },
).unref();
let idle = setTimeout(shutdown, 60000);
const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  clearTimeout(idle);
  queue = queue.then(async () => {
    Atomics.store(deadline, 0, BigInt(Date.now() + 30000));
    try {
      if (Buffer.byteLength(line) > 1048576)
        throw new Error("FFF request exceeds 1 MiB bound");
      const reply = JSON.stringify({
        protocol: 1,
        ok: true,
        value: await request(JSON.parse(line)),
      });
      if (Buffer.byteLength(reply) > 8 * 1024 * 1024)
        throw new Error("FFF response exceeds 8 MiB bound; narrow the search");
      process.stdout.write(reply + "\n");
    } catch (e) {
      process.stdout.write(
        JSON.stringify({ protocol: 1, ok: false, error: String(e.message) }) +
          "\n",
      );
    } finally {
      Atomics.store(deadline, 0, 0n);
      idle = setTimeout(shutdown, 60000);
    }
  });
});
input.on("close", shutdown);
