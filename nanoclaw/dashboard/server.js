const http = require('http');
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const PORT = parseInt(process.env.DASHBOARD_PORT || '8099');
const APP_DIR = process.env.APP_DIR || '/data/app';
const DB_PATH = path.join(APP_DIR, 'store', 'messages.db');

function getStatus() {
  const status = {
    version: '?',
    uptime: process.uptime(),
    groups: [],
    recentMessages: [],
    activeContainers: [],
  };

  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(APP_DIR, 'package.json'), 'utf8'));
    status.version = pkg.version || '?';
  } catch {}

  if (!fs.existsSync(DB_PATH)) return status;

  try {
    const db = new Database(DB_PATH, { readonly: true });

    try {
      const groups = db.prepare('SELECT jid, name, folder, is_main FROM registered_groups').all();
      status.groups = groups;
    } catch {}

    try {
      const msgs = db.prepare(`
        SELECT sender_name, chat_name, body, timestamp
        FROM messages ORDER BY timestamp DESC LIMIT 20
      `).all();
      status.recentMessages = msgs;
    } catch {}

    try {
      const sessions = db.prepare('SELECT group_folder, session_id FROM sessions').all();
      status.activeSessions = sessions;
    } catch {}

    db.close();
  } catch {}

  // Check running containers
  try {
    const { execSync } = require('child_process');
    const out = execSync('docker ps --filter name=nanoclaw- --format "{{.Names}}|{{.Status}}|{{.RunningFor}}"', { timeout: 5000 }).toString().trim();
    if (out) {
      status.activeContainers = out.split('\n').map(line => {
        const [name, dockerStatus, running] = line.split('|');
        return { name, status: dockerStatus, running };
      });
    }
  } catch {}

  return status;
}

function renderHTML(status) {
  const messagesHTML = status.recentMessages.map(m => {
    const time = new Date(m.timestamp).toLocaleString('uk-UA', { timeZone: 'Europe/Kyiv' });
    const body = (m.body || '').substring(0, 200).replace(/</g, '&lt;');
    return `<tr><td>${time}</td><td>${m.sender_name || '?'}</td><td>${body}</td></tr>`;
  }).join('');

  const groupsHTML = status.groups.map(g =>
    `<tr><td>${g.name}</td><td><code>${g.jid}</code></td><td>${g.folder}</td><td>${g.is_main ? 'Yes' : 'No'}</td></tr>`
  ).join('');

  const containersHTML = status.activeContainers.length
    ? status.activeContainers.map(c =>
        `<tr><td>${c.name}</td><td>${c.status}</td><td>${c.running}</td></tr>`
      ).join('')
    : '<tr><td colspan="3" style="opacity:0.5">No active containers</td></tr>';

  const uptimeMin = Math.floor(status.uptime / 60);
  const uptimeH = Math.floor(uptimeMin / 60);
  const uptimeStr = uptimeH > 0 ? `${uptimeH}h ${uptimeMin % 60}m` : `${uptimeMin}m`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NanoClaw</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
         background: #f5f5f5; color: #333; padding: 24px; }
  h1 { font-size: 24px; margin-bottom: 8px; }
  .subtitle { color: #666; margin-bottom: 24px; font-size: 14px; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .card { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .card-label { font-size: 12px; text-transform: uppercase; color: #888; letter-spacing: 0.5px; }
  .card-value { font-size: 28px; font-weight: 600; margin-top: 4px; }
  .section { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 16px; }
  .section h2 { font-size: 16px; margin-bottom: 12px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; }
  th { font-weight: 600; color: #666; font-size: 12px; text-transform: uppercase; }
  code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
  .refresh { float: right; font-size: 13px; color: #4a9eff; cursor: pointer; text-decoration: none; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
  .dot-green { background: #4caf50; }
  .dot-gray { background: #ccc; }
</style>
</head>
<body>
  <h1>NanoClaw <span style="font-size:14px;color:#888">v${status.version}</span></h1>
  <p class="subtitle">Personal AI Agent Dashboard</p>

  <div class="cards">
    <div class="card">
      <div class="card-label">Uptime</div>
      <div class="card-value">${uptimeStr}</div>
    </div>
    <div class="card">
      <div class="card-label">Groups</div>
      <div class="card-value">${status.groups.length}</div>
    </div>
    <div class="card">
      <div class="card-label">Active Containers</div>
      <div class="card-value">${status.activeContainers.length}</div>
    </div>
    <div class="card">
      <div class="card-label">Messages (recent)</div>
      <div class="card-value">${status.recentMessages.length}</div>
    </div>
  </div>

  <div class="section">
    <h2>Active Containers <a class="refresh" href="javascript:location.reload()">Refresh</a></h2>
    <table>
      <tr><th>Name</th><th>Status</th><th>Running</th></tr>
      ${containersHTML}
    </table>
  </div>

  <div class="section">
    <h2>Registered Groups</h2>
    <table>
      <tr><th>Name</th><th>JID</th><th>Folder</th><th>Main</th></tr>
      ${groupsHTML || '<tr><td colspan="4" style="opacity:0.5">No groups registered</td></tr>'}
    </table>
  </div>

  <div class="section">
    <h2>Recent Messages</h2>
    <table>
      <tr><th>Time</th><th>Sender</th><th>Message</th></tr>
      ${messagesHTML || '<tr><td colspan="3" style="opacity:0.5">No messages yet</td></tr>'}
    </table>
  </div>

  <script>setTimeout(() => location.reload(), 30000);</script>
</body>
</html>`;
}

const server = http.createServer((req, res) => {
  if (req.url === '/api/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getStatus()));
    return;
  }

  const status = getStatus();
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(renderHTML(status));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Dashboard listening on port ${PORT}`);
});
