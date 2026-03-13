#!/usr/bin/env node

import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { mkdirSync, existsSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SERVER_ROOT = path.resolve(__dirname, "..");
const DEFAULT_DATA_DIR = path.join(SERVER_ROOT, "data");
const DEFAULT_STORE_PATH = path.join(DEFAULT_DATA_DIR, "store.json");
const LISTEN_HOST = process.env.CLIPSYNC_BIND || "0.0.0.0";
const LISTEN_PORT = Number.parseInt(process.env.CLIPSYNC_PORT || "8787", 10);
const EVENT_RETENTION_MS = 8 * 60 * 60 * 1000;
const BODY_LIMIT_BYTES = 128 * 1024;

function ensureDir(dirPath) {
  mkdirSync(dirPath, { recursive: true });
}

function now() {
  return Date.now();
}

function createId(prefix) {
  return `${prefix}_${randomBytes(12).toString("hex")}`;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

class Store {
  constructor(filePath) {
    this.filePath = filePath;
    ensureDir(path.dirname(filePath));
    this.state = this.load();
    this.applyServerKey();
    this.compact();
    this.save();
  }

  load() {
    if (!existsSync(this.filePath)) {
      return {
        serverKey: "",
        nextCursor: 1,
        pairings: [],
        events: []
      };
    }

    try {
      const raw = readFileSync(this.filePath, "utf8");
      const parsed = JSON.parse(raw);
      return {
        serverKey: typeof parsed.serverKey === "string" ? parsed.serverKey : "",
        nextCursor: Number.isInteger(parsed.nextCursor) && parsed.nextCursor > 0 ? parsed.nextCursor : 1,
        pairings: Array.isArray(parsed.pairings) ? parsed.pairings : [],
        events: Array.isArray(parsed.events) ? parsed.events : []
      };
    } catch (error) {
      console.error("Failed to read store, starting fresh:", error);
      return {
        serverKey: "",
        nextCursor: 1,
        pairings: [],
        events: []
      };
    }
  }

  applyServerKey() {
    const configuredKey = (process.env.CLIPSYNC_SERVER_KEY || "").trim();
    if (configuredKey) {
      this.state.serverKey = configuredKey;
      return;
    }

    if (!this.state.serverKey) {
      this.state.serverKey = randomBytes(24).toString("hex");
    }
  }

  save() {
    const tempPath = `${this.filePath}.tmp`;
    writeFileSync(tempPath, JSON.stringify(this.state, null, 2));
    renameSync(tempPath, this.filePath);
  }

  compact() {
    const cutoff = now() - EVENT_RETENTION_MS;
    const activePairingIds = new Set(
      this.state.pairings
        .filter((pairing) => pairing.status === "active")
        .map((pairing) => pairing.pairingId)
    );

    this.state.pairings = this.state.pairings.filter((pairing) => {
      if (pairing.status === "active") {
        return true;
      }
      return (pairing.updatedAt || pairing.createdAt || 0) >= cutoff;
    });

    this.state.events = this.state.events.filter((event) => {
      if ((event.timestamp || 0) < cutoff) {
        return false;
      }
      return activePairingIds.has(event.pairingId);
    });
  }

  getServerKey() {
    return this.state.serverKey;
  }

  deactivatePairingsForDevices({ macDeviceId, androidDeviceId }) {
    const changeTime = now();
    let changed = false;

    this.state.pairings = this.state.pairings.map((pairing) => {
      const matchesDevice =
        pairing.status === "active" &&
        (pairing.macDeviceId === macDeviceId || pairing.androidDeviceId === androidDeviceId);

      if (!matchesDevice) {
        return pairing;
      }

      changed = true;
      return {
        ...pairing,
        status: "deleted",
        updatedAt: changeTime
      };
    });

    if (changed) {
      const inactivePairingIds = new Set(
        this.state.pairings
          .filter((pairing) => pairing.status !== "active")
          .map((pairing) => pairing.pairingId)
      );

      this.state.events = this.state.events.filter((event) => !inactivePairingIds.has(event.pairingId));
    }
  }

  createPairing({ macDeviceId, macDeviceName, androidDeviceId, androidDeviceName, sessionId }) {
    this.deactivatePairingsForDevices({ macDeviceId, androidDeviceId });

    const pairing = {
      pairingId: createId("pairing"),
      macDeviceId,
      macDeviceName,
      androidDeviceId,
      androidDeviceName,
      sessionId: typeof sessionId === "string" && sessionId.trim() ? sessionId.trim() : "",
      status: "active",
      createdAt: now(),
      updatedAt: now()
    };

    this.state.pairings.push(pairing);
    this.save();
    return clone(pairing);
  }

  getPairing(pairingId) {
    const pairing = this.state.pairings.find((entry) => entry.pairingId === pairingId);
    return pairing ? clone(pairing) : null;
  }

  getLatestPairingForMac(macDeviceId, since, sessionId) {
    const candidates = this.state.pairings
      .filter((pairing) => pairing.macDeviceId === macDeviceId)
      .filter((pairing) => pairing.status === "active")
      .filter((pairing) => {
        if (sessionId) {
          return pairing.sessionId === sessionId;
        }
        return pairing.createdAt >= since;
      })
      .sort((left, right) => right.createdAt - left.createdAt);

    return candidates.length > 0 ? clone(candidates[0]) : null;
  }

  deletePairing(pairingId) {
    const index = this.state.pairings.findIndex((pairing) => pairing.pairingId === pairingId);
    if (index === -1) {
      return null;
    }

    const pairing = this.state.pairings[index];
    if (pairing.status !== "active") {
      return clone(pairing);
    }

    const deletedPairing = {
      ...pairing,
      status: "deleted",
      updatedAt: now()
    };

    this.state.pairings[index] = deletedPairing;
    this.state.events = this.state.events.filter((event) => event.pairingId !== pairingId);
    this.save();
    return clone(deletedPairing);
  }

  addEvent({ pairingId, type, sourceDeviceId, sourceDeviceName, content, encryptedOTP }) {
    const pairing = this.state.pairings.find((entry) => entry.pairingId === pairingId);
    if (!pairing) {
      return { error: "not_found" };
    }
    if (pairing.status !== "active") {
      return { error: "deleted" };
    }

    const event = {
      id: this.state.nextCursor++,
      pairingId,
      type,
      sourceDeviceId,
      sourceDeviceName: sourceDeviceName || "",
      content: content || null,
      encryptedOTP: encryptedOTP || null,
      timestamp: now()
    };

    this.state.events.push(event);
    pairing.updatedAt = now();
    this.compact();
    this.save();
    return { event: clone(event) };
  }

  listEvents({ pairingId, after, type, excludeDeviceId, limit }) {
    const pairing = this.state.pairings.find((entry) => entry.pairingId === pairingId);
    if (!pairing) {
      return { error: "not_found" };
    }
    if (pairing.status !== "active") {
      return { error: "deleted" };
    }

    const currentCursor = Math.max(0, this.state.nextCursor - 1);
    const events = this.state.events
      .filter((event) => event.pairingId === pairingId)
      .filter((event) => event.id > after)
      .filter((event) => !type || event.type === type)
      .filter((event) => !excludeDeviceId || event.sourceDeviceId !== excludeDeviceId)
      .sort((left, right) => left.id - right.id)
      .slice(0, limit)
      .map((event) => clone(event));

    const nextCursor = events.length > 0 ? events[events.length - 1].id : currentCursor;
    return { events, cursor: nextCursor };
  }

  clearClipboardEvents(pairingId) {
    const pairing = this.state.pairings.find((entry) => entry.pairingId === pairingId);
    if (!pairing) {
      return { error: "not_found" };
    }
    if (pairing.status !== "active") {
      return { error: "deleted" };
    }

    const before = this.state.events.length;
    this.state.events = this.state.events.filter(
      (event) => !(event.pairingId === pairingId && event.type === "clipboard")
    );
    const deleted = before - this.state.events.length;
    pairing.updatedAt = now();
    this.save();
    return { deleted };
  }
}

const dataDir = process.env.CLIPSYNC_DATA_DIR
  ? path.resolve(process.env.CLIPSYNC_DATA_DIR)
  : DEFAULT_DATA_DIR;
const storePath = process.env.CLIPSYNC_STORE_FILE
  ? path.resolve(process.env.CLIPSYNC_STORE_FILE)
  : path.join(dataDir, path.basename(DEFAULT_STORE_PATH));

ensureDir(dataDir);
const store = new Store(storePath);

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;

    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > BODY_LIMIT_BYTES) {
        reject(new Error("Request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("Invalid JSON body"));
      }
    });

    req.on("error", reject);
  });
}

function json(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store"
  });
  res.end(body);
}

function text(res, statusCode, value) {
  res.writeHead(statusCode, {
    "Content-Type": "text/plain; charset=utf-8",
    "Content-Length": Buffer.byteLength(value),
    "Cache-Control": "no-store"
  });
  res.end(value);
}

function getHeader(req, name) {
  const value = req.headers[name.toLowerCase()];
  return Array.isArray(value) ? value[0] : value;
}

function isAuthorized(req) {
  const supplied = getHeader(req, "x-clipsync-key") || "";
  const configured = store.getServerKey();
  if (!supplied || !configured) {
    return false;
  }

  const left = Buffer.from(supplied);
  const right = Buffer.from(configured);
  if (left.length !== right.length) {
    return false;
  }
  return timingSafeEqual(left, right);
}

function requireString(value, fieldName) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Missing ${fieldName}`);
  }
  return value.trim();
}

function routeParts(urlPath) {
  return urlPath.split("/").filter(Boolean);
}

function handleError(res, error) {
  json(res, 400, {
    error: error instanceof Error ? error.message : "Bad request"
  });
}

function serverInfo() {
  return {
    ok: true,
    host: LISTEN_HOST,
    port: LISTEN_PORT,
    dataDir,
    storeFile: storePath,
    authHeader: "X-ClipSync-Key"
  };
}

const app = createServer(async (req, res) => {
  try {
    if (!req.url || !req.method) {
      json(res, 400, { error: "Invalid request" });
      return;
    }

    const parsedUrl = new URL(req.url, `http://${req.headers.host || "localhost"}`);
    const parts = routeParts(parsedUrl.pathname);

    if (req.method === "GET" && parsedUrl.pathname === "/health") {
      json(res, 200, {
        ok: true,
        serverTime: now()
      });
      return;
    }

    if (req.method === "GET" && parsedUrl.pathname === "/api/v1/server") {
      if (!isAuthorized(req)) {
        json(res, 401, { error: "Unauthorized" });
        return;
      }
      json(res, 200, serverInfo());
      return;
    }

    if (!isAuthorized(req)) {
      json(res, 401, { error: "Unauthorized" });
      return;
    }

    if (req.method === "POST" && parsedUrl.pathname === "/api/v1/pairings") {
      const body = await readBody(req);
      const pairing = store.createPairing({
        macDeviceId: requireString(body.macDeviceId, "macDeviceId"),
        macDeviceName: requireString(body.macDeviceName, "macDeviceName"),
        androidDeviceId: requireString(body.androidDeviceId, "androidDeviceId"),
        androidDeviceName: requireString(body.androidDeviceName, "androidDeviceName"),
        sessionId: typeof body.sessionId === "string" ? body.sessionId : ""
      });

      json(res, 201, { pairing });
      return;
    }

    if (req.method === "GET" && parts[0] === "api" && parts[1] === "v1" && parts[2] === "pairings" && parts[3] === "by-mac" && parts[4]) {
      const since = Number.parseInt(parsedUrl.searchParams.get("since") || "0", 10);
      const sessionId = (parsedUrl.searchParams.get("sessionId") || "").trim();
      const pairing = store.getLatestPairingForMac(parts[4], Number.isFinite(since) ? since : 0, sessionId);
      json(res, 200, { pairing });
      return;
    }

    if (parts[0] === "api" && parts[1] === "v1" && parts[2] === "pairings" && parts[3]) {
      const pairingId = parts[3];

      if (req.method === "GET" && parts.length === 4) {
        const pairing = store.getPairing(pairingId);
        if (!pairing) {
          json(res, 404, { error: "Pairing not found" });
          return;
        }

        if (pairing.status !== "active") {
          json(res, 410, { error: "Pairing deleted", pairing });
          return;
        }

        json(res, 200, { pairing });
        return;
      }

      if (req.method === "DELETE" && parts.length === 4) {
        const pairing = store.deletePairing(pairingId);
        if (!pairing) {
          json(res, 404, { error: "Pairing not found" });
          return;
        }

        json(res, 200, { pairing });
        return;
      }

      if (req.method === "POST" && parts[4] === "clipboard" && parts.length === 5) {
        const body = await readBody(req);
        const result = store.addEvent({
          pairingId,
          type: "clipboard",
          sourceDeviceId: requireString(body.sourceDeviceId, "sourceDeviceId"),
          sourceDeviceName: typeof body.sourceDeviceName === "string" ? body.sourceDeviceName.trim() : "",
          content: requireString(body.content, "content")
        });

        if (result.error === "not_found") {
          json(res, 404, { error: "Pairing not found" });
          return;
        }
        if (result.error === "deleted") {
          json(res, 410, { error: "Pairing deleted" });
          return;
        }

        json(res, 201, { event: result.event });
        return;
      }

      if (req.method === "DELETE" && parts[4] === "clipboard" && parts.length === 5) {
        const result = store.clearClipboardEvents(pairingId);
        if (result.error === "not_found") {
          json(res, 404, { error: "Pairing not found" });
          return;
        }
        if (result.error === "deleted") {
          json(res, 410, { error: "Pairing deleted" });
          return;
        }
        json(res, 200, { deleted: result.deleted });
        return;
      }

      if (req.method === "POST" && parts[4] === "otp" && parts.length === 5) {
        const body = await readBody(req);
        const result = store.addEvent({
          pairingId,
          type: "otp",
          sourceDeviceId: requireString(body.sourceDeviceId, "sourceDeviceId"),
          sourceDeviceName: typeof body.sourceDeviceName === "string" ? body.sourceDeviceName.trim() : "",
          encryptedOTP: requireString(body.encryptedOTP, "encryptedOTP")
        });

        if (result.error === "not_found") {
          json(res, 404, { error: "Pairing not found" });
          return;
        }
        if (result.error === "deleted") {
          json(res, 410, { error: "Pairing deleted" });
          return;
        }

        json(res, 201, { event: result.event });
        return;
      }

      if (req.method === "GET" && parts[4] === "events" && parts.length === 5) {
        const after = Number.parseInt(parsedUrl.searchParams.get("after") || "0", 10);
        const limit = Math.max(1, Math.min(100, Number.parseInt(parsedUrl.searchParams.get("limit") || "25", 10)));
        const type = parsedUrl.searchParams.get("type") || "";
        const excludeDeviceId = parsedUrl.searchParams.get("excludeDeviceId") || "";
        const result = store.listEvents({
          pairingId,
          after: Number.isFinite(after) ? after : 0,
          type: type || "",
          excludeDeviceId,
          limit
        });

        if (result.error === "not_found") {
          json(res, 404, { error: "Pairing not found" });
          return;
        }
        if (result.error === "deleted") {
          json(res, 410, { error: "Pairing deleted" });
          return;
        }

        json(res, 200, result);
        return;
      }
    }

    text(res, 404, "Not found");
  } catch (error) {
    handleError(res, error);
  }
});

app.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`ClipSync self-hosted server listening on http://${LISTEN_HOST}:${LISTEN_PORT}`);
  console.log(`Data file: ${storePath}`);
  console.log(`Server key: ${store.getServerKey()}`);
});

function shutdown(signal) {
  console.log(`Received ${signal}, shutting down.`);
  app.close(() => process.exit(0));
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("uncaughtException", (error) => {
  console.error("Uncaught exception:", error);
  process.exit(1);
});
process.on("unhandledRejection", (error) => {
  console.error("Unhandled rejection:", error);
  process.exit(1);
});
