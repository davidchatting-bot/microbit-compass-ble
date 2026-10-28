// server.js using CommonJS (HTTP version)
const express = require("express");
const { WebSocketServer } = require("ws");
const http = require("http");

const app = express();
const PORT = 3000;


const server = http.createServer(app);

const wss = new WebSocketServer({ server, path: "/pubgames" });

const sessions = new Map();

function broadcastToSession(sessionId, payload) {
  // Forward message to all clients in the same session
  if (sessionId && sessions.has(sessionId)) {
    for (const client of sessions.get(sessionId)) {
      if (client.readyState === client.OPEN) {
        client.send(JSON.stringify(payload));
      }
    }
  }
}

/**
 * Send a parsed JSON message either to a specific target in the same session
 * or broadcast to the session if no target is present.
 *
 * @param {WebSocket} senderWs  the WebSocket that sent the original message
 * @param {object} msgObj      parsed JSON message from sender
 * @returns {boolean}          true if delivered to at least one recipient
 */
function sendToClient(senderWs, msgObj) {
  if (!msgObj || typeof msgObj !== 'object') return false;

  // Determine session to use: prefer explicit sessionId in message, else sender's registered session
  const sessionId = (typeof msgObj.sessionId === 'string' && msgObj.sessionId.length > 0)
    ? msgObj.sessionId
    : senderWs.sessionId;

  if (!sessionId || !sessions.has(sessionId)) {
    return false; // no such session
  }

  // Ensure sender belongs to the session
  const clients = sessions.get(sessionId);
  if (!clients.has(senderWs)) return false;

  const fromId = (msgObj.clientId) ? msgObj.clientId : (senderWs.clientId || 'unknown');

  // targeted delivery if targetId/targetClientId present
  const targetId = msgObj.targetClientId || msgObj.target || null;
  if (targetId) {
    for (const client of clients) {
      if (client.clientId && client.clientId === targetId && client.readyState === client.OPEN) {
        try {
          client.send(JSON.stringify(msgObj));
          return true;
        } catch (e) {
          return false;
        }
      }
    }
    return false; // target not found in session
  }

  // no explicit target -> broadcast to all other members of the session
  let sent = false;
  const out = JSON.stringify(msgObj);
  for (const client of clients) {
    if (client !== senderWs && client.readyState === client.OPEN) {
      try {
        client.send(out);
        sent = true;
      } catch (e) {
        // ignore per-client send errors
      }
    }
  }
  return sent;
}

wss.on("connection", (ws) => {
  let sessionId = null;

  ws.on("message", (msg) => {
    // try to parse JSON; non-JSON messages are ignored
    let data;
    try {
      data = JSON.parse(msg);
    } catch {
      return;
    }

    // remember clientId for this ws (useful on close / replies)
    if (data && data.clientId) ws.clientId = data.clientId;

    // register session when client_info is received
    if (data && data.type === "client_info" && data.sessionId) {
      sessionId = data.sessionId;
      if (!sessions.has(sessionId)) sessions.set(sessionId, new Set());
      sessions.get(sessionId).add(ws);
      ws.sessionId = sessionId;
    }

    sendToClient(ws, data);
  });

  ws.on("close", (code, reason) => {
    const clientId = ws.clientId;
    console.log("Client disconnected:", clientId, code, reason ? reason.toString() : '');
    if (sessionId && sessions.has(sessionId)) {
      sendToClient(ws, {
        type: "disconnect",
        clientId: clientId,
        sessionId: sessionId
      });

      sessions.get(sessionId).delete(ws);
      if (sessions.get(sessionId).size === 0) sessions.delete(sessionId);
    }
  });
});

server.listen(PORT, () => {
  console.log(`HTTP server running at http://localhost:${PORT}`);
});