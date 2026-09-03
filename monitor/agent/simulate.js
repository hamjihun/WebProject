'use strict';
// 실제 서버 없이 화면을 확인하기 위한 가짜 에이전트.
// 사용법: node agent/simulate.js [http://127.0.0.1:8787/api/metrics]
const http = require('http');
const url = new URL(process.argv[2] || process.env.URL || 'http://127.0.0.1:8787/api/metrics');
const TOKEN = process.env.TOKEN || '';
const GB = 1024 ** 3;

const hosts = [
  { host: 'ERP-DB01',  os: 'Windows Server 2019', mem: 64 * GB, base: 35, disks: [['C:', 200 * GB, 120 * GB], ['D:', 2000 * GB, 1650 * GB]] },
  { host: 'MES-APP01', os: 'Ubuntu 22.04',        mem: 32 * GB, base: 55, disks: [['/', 100 * GB, 61 * GB], ['/data', 500 * GB, 470 * GB]] },
  { host: 'FILE-SRV',  os: 'Windows Server 2016', mem: 16 * GB, base: 10, disks: [['C:', 120 * GB, 40 * GB], ['E:', 4000 * GB, 3100 * GB]] },
];
const t0 = Date.now();

function send(h) {
  const wobble = Math.sin(Date.now() / 20000 + h.base) * 15 + Math.random() * 10;
  const body = JSON.stringify({
    host: h.host, os: h.os, token: TOKEN,
    cpu: Math.max(1, Math.min(99, h.base + wobble)),
    mem_total: h.mem, mem_used: h.mem * (0.4 + Math.random() * 0.2),
    uptime: 86400 * 12 + (Date.now() - t0) / 1000,
    net_rx: Math.random() * 5e6, net_tx: Math.random() * 2e6,
    disks: h.disks.map(([mount, total, used]) => ({ mount, total, used })),
  });
  const req = http.request({ hostname: url.hostname, port: url.port, path: url.pathname, method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Token': TOKEN, 'Content-Length': Buffer.byteLength(body) } },
    (res) => res.resume());
  req.on('error', (e) => console.error(h.host, 'send failed:', e.message));
  req.end(body);
}

console.log(`가짜 서버 ${hosts.length}대 데이터를 ${url.href} 로 5초마다 전송합니다. Ctrl+C 로 종료.`);
hosts.forEach(send);
setInterval(() => hosts.forEach(send), 5000);
