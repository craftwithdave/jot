// Between the Swift phases: the Node reference client reads Swift's notes, writes its own, edits + deletes.
import { Client } from "/spec/client.mjs";
const c = new Client(process.argv[2], "node");
await c.unlock("swift ✓ pass"); await c.sync();
const bodies = c.live().map((n) => n.body);
if (!bodies.includes("From Swift\nlinks to [[From Node]] #mac")) { console.log("node: swift note missing", bodies); process.exit(1); }
c.edit("nodenote-aaaaaaaaaaaaa", "From Node\nhello from node, see [[From Swift]]");
c.edit("doomed-aaaaaaaaaaaaaaa", "Doomed\nwill be deleted"); await c.sync();
c.remove("doomed-aaaaaaaaaaaaaaa");
c.edit("shared-aaaaaaaaaaaaaaa", "Shared\nv2 node edit (later)", 3000);
await c.sync();
console.log("node phase ok");
