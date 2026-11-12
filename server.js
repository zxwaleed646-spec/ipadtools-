// سيرفر مكافحة الغش - Node.js بدون أي مكتبات خارجية
// التشغيل:  ADMIN_KEY=كلمة_سر_قوية node server.js

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT) || 3000;
const ADMIN_KEY = process.env.ADMIN_KEY || 'change-me';
const DATA_DIR = process.env.DATA_DIR || __dirname;
const BANNED_FILE = path.join(DATA_DIR, 'banned.json');
const REPORTS_FILE = path.join(DATA_DIR, 'reports.jsonl');

if (ADMIN_KEY === 'change-me') {
  console.warn('تحذير: غيّر ADMIN_KEY قبل ما تنشر السيرفر.');
}

// ---------- الحالة ----------
const sessions = new Map();   // sessionId -> { playerId, secret, lastTs, createdAt }
const recent = [];            // آخر 200 تقرير للوحة المشرف
let banned = new Map();       // playerId -> { reasons, at }

try {
  banned = new Map(Object.entries(JSON.parse(fs.readFileSync(BANNED_FILE, 'utf8'))));
} catch (_) { /* أول تشغيل */ }

const saveBanned = () =>
  fs.writeFileSync(BANNED_FILE, JSON.stringify(Object.fromEntries(banned), null, 2));

// ---------- أدوات ----------
const SEVERE = { jailbroken: 'jailbroken', debuggerAttached: 'debugger', injectedLibrary: 'injected_library' };
const MINOR  = { screenCaptured: 'screen_captured', timeTampered: 'time_tampered', simulator: 'simulator' };
const FLAG_ORDER = ['jailbroken', 'debuggerAttached', 'injectedLibrary',
                    'screenCaptured', 'timeTampered', 'leftApp', 'simulator'];
const MAX_DRIFT_MS = 120_000;

function readBody(req, limit = 10_000) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', c => {
      size += c.length;
      if (size > limit) { reject(new Error('too_large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

function hmacHex(message, secret) {
  return crypto.createHmac('sha256', secret).update(message).digest('hex');
}

function safeEqualHex(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

const validPlayerId = id => typeof id === 'string' && /^[\w.\-]{1,64}$/.test(id);

const esc = s => String(s).replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---------- القرار ----------
function decide(flags, timestamp) {
  const reasons = [];
  let status = 'ok';

  for (const [k, label] of Object.entries(SEVERE)) {
    if (flags[k]) { reasons.push(label); status = 'ban'; }
  }
  for (const [k, label] of Object.entries(MINOR)) {
    if (flags[k]) { reasons.push(label); if (status !== 'ban') status = 'warn'; }
  }
  // التحقق من الوقت من جهة السيرفر (أقوى من فحص الجهاز)
  if (Math.abs(Date.now() - timestamp) > MAX_DRIFT_MS && !reasons.includes('time_tampered')) {
    reasons.push('time_tampered');
    if (status !== 'ban') status = 'warn';
  }
  return { status, reasons };
}

// ---------- المسارات ----------
async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');

  // بدء جلسة
  if (req.method === 'POST' && url.pathname === '/session') {
    const { playerId } = JSON.parse(await readBody(req) || '{}');
    if (!validPlayerId(playerId)) return send(res, 400, { error: 'bad_player_id' });
    if (banned.has(playerId)) return send(res, 403, { error: 'banned' });

    const sessionId = crypto.randomUUID();
    const secret = crypto.randomBytes(32).toString('hex');
    sessions.set(sessionId, { playerId, secret, lastTs: 0, createdAt: Date.now() });
    return send(res, 200, { sessionId, secret, serverTime: Date.now() });
  }

  // استقبال تقرير
  if (req.method === 'POST' && url.pathname === '/report') {
    const b = JSON.parse(await readBody(req) || '{}');
    const s = sessions.get(b.sessionId);
    if (!s || s.playerId !== b.playerId) return send(res, 401, { error: 'unknown_session' });
    if (banned.has(s.playerId)) return send(res, 403, { error: 'banned' });

    const f = b.flags || {};
    const bit = v => (v === true ? '1' : '0');
    const canonical = [b.sessionId, b.playerId, String(b.timestamp),
                       ...FLAG_ORDER.map(k => bit(f[k]))].join('|');
    if (!Number.isFinite(b.timestamp) || !safeEqualHex(b.signature, hmacHex(canonical, s.secret))) {
      return send(res, 401, { error: 'bad_signature' });
    }
    // منع إعادة إرسال تقرير قديم
    if (b.timestamp <= s.lastTs) return send(res, 409, { error: 'replay' });
    s.lastTs = b.timestamp;

    const flags = Object.fromEntries(FLAG_ORDER.map(k => [k, f[k] === true]));
    const decision = decide(flags, b.timestamp);

    const entry = { at: new Date().toISOString(), playerId: s.playerId, flags, ...decision };
    recent.unshift(entry);
    if (recent.length > 200) recent.pop();
    fs.appendFile(REPORTS_FILE, JSON.stringify(entry) + '\n', () => {});

    if (decision.status === 'ban') {
      banned.set(s.playerId, { reasons: decision.reasons, at: entry.at });
      saveBanned();
    }
    return send(res, 200, decision);
  }

  // لوحة المشرف
  if (req.method === 'GET' && url.pathname === '/admin') {
    const key = url.searchParams.get('key') || '';
    if (!safeEqualHex(key, ADMIN_KEY)) { res.writeHead(401); return res.end('unauthorized'); }

    const rows = recent.map(r => `<tr class="${esc(r.status)}">
      <td>${esc(r.at)}</td><td>${esc(r.playerId)}</td><td>${esc(r.status)}</td>
      <td>${esc(r.reasons.join(', ') || '-')}</td>
      <td>${esc(r.flags.leftApp ? 'خرج من التطبيق' : '')}</td></tr>`).join('');
    const bans = [...banned.entries()].map(([id, v]) =>
      `<li>${esc(id)} — ${esc(v.reasons.join(', '))} — ${esc(v.at)}</li>`).join('');

    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(`<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>لوحة مكافحة الغش</title>
<style>
body{font-family:system-ui;margin:24px;max-width:1000px}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px 10px;text-align:right;font-size:14px}
tr.ban{background:#fde2e2}tr.warn{background:#fff3cd}
</style>
<h1>لوحة مكافحة الغش</h1>
<h2>المحظورون (${banned.size})</h2><ul>${bans || '<li>لا أحد</li>'}</ul>
<p>لفك حظر لاعب: احذفه من ملف banned.json وأعد تشغيل السيرفر.</p>
<h2>آخر التقارير</h2>
<table><tr><th>الوقت</th><th>اللاعب</th><th>الحالة</th><th>الأسباب</th><th>ملاحظة</th></tr>${rows}</table>
</html>`);
  }

  send(res, 404, { error: 'not_found' });
}

const server = http.createServer((req, res) => {
  handle(req, res).catch(err => {
    const code = err.message === 'too_large' ? 413 : 400;
    if (!res.headersSent) send(res, code, { error: err.message === 'too_large' ? 'too_large' : 'bad_request' });
  });
});

// تنظيف الجلسات القديمة (أكثر من 6 ساعات)
setInterval(() => {
  const cutoff = Date.now() - 6 * 3600_000;
  for (const [id, s] of sessions) if (s.createdAt < cutoff) sessions.delete(id);
}, 600_000).unref();

server.listen(PORT, () => console.log(`Anti-cheat server on :${PORT}`));
