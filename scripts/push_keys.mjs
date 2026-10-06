import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";

const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const key = privateKey.export({ format: "jwk" });
const publicKey = Buffer.concat([
  Buffer.from([4]),
  Buffer.from(key.x, "base64url"),
  Buffer.from(key.y, "base64url"),
]).toString("base64url");
mkdirSync(".data", { recursive: true, mode: 0o700 });
writeFileSync(
  ".data/push.env",
  `VAPID_PUBLIC_KEY=${publicKey}\nVAPID_PRIVATE_KEY=${key.d}\n`,
  { flag: "wx", mode: 0o600 },
);
console.log(
  "Saved Web Push keys to .data/push.env. Keep this file private and include it in backups.",
);
