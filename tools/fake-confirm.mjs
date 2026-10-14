// 合成测试：往聊天 DOM 注入一对假的「运行/拒绝」按钮，触发 nudge 全链路
// 用法：node nudge-fake-confirm.mjs inject | remove
const mode = process.argv[2] || 'inject';
const list = await (await fetch('http://127.0.0.1:9224/json/list')).json();

// 按内容找聊天 target
let chat = null;
for (const t of list.filter(t => t.type === 'iframe' && t.webSocketDebuggerUrl)) {
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  const v = await new Promise(res => {
    const timer = setTimeout(() => res(null), 4000);
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: "(() => { const f = document.querySelector('iframe'); const d = f && f.contentDocument; return d ? String((d.body?.innerText||'').length) : '0'; })()", returnByValue: true } }));
    ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id === 1) { clearTimeout(timer); res(m.result?.result?.value); } };
  });
  ws.close();
  if (v && Number(v) > 100) { chat = t; break; }
}
if (!chat) { console.log('未找到聊天 target'); process.exit(1); }
console.log('聊天 target:', chat.id.slice(0, 8));

const expr = mode === 'inject' ? `
  (() => {
    const f = document.querySelector('iframe');
    const d = f && f.contentDocument;
    if (!d) return 'no-doc';
    if (d.getElementById('__nudge-fake')) return 'exists';
    const box = d.createElement('div');
    box.id = '__nudge-fake';
    box.style.cssText = 'position:fixed;top:8px;left:8px;z-index:99999;background:#222;color:#fff;padding:8px;font-size:12px;';
    box.innerText = 'touch /tmp/nudge-e2e-confirm-test\\n';
    const run = d.createElement('div'); run.className = 'menu-item'; run.innerText = '运行';
    const deny = d.createElement('div'); deny.className = 'menu-item'; deny.innerText = '拒绝';
    box.appendChild(run); box.appendChild(deny);
    d.body.appendChild(box);
    return 'injected';
  })()
` : `
  (() => {
    const f = document.querySelector('iframe');
    const d = f && f.contentDocument;
    const el = d && d.getElementById('__nudge-fake');
    if (el) el.remove();
    return 'removed';
  })()
`;

const ws = new WebSocket(chat.webSocketDebuggerUrl);
const r = await new Promise(res => {
  ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true } }));
  ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id === 1) res(m.result?.result?.value); };
});
ws.close();
console.log(mode, '=>', r);
