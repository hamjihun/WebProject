#!/bin/python
# -*- coding: utf-8 -*-
# IMS Monitoring Agent for VMware ESXi host
# ESXi 에 기본 내장된 python 과 vim-cmd / esxcli 만 사용. 설정: 같은 폴더의 agent.conf
import os, sys, re, json, time, subprocess, socket
try:
    from urllib.request import Request, urlopen
except ImportError:  # python2 (오래된 ESXi)
    from urllib2 import Request, urlopen

HERE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(HERE, 'agent.conf')
STATUS = os.path.join(HERE, 'status.json')

def load_conf():
    c = {'URL': '', 'TOKEN': '', 'INTERVAL': '5', 'NAME': '', 'INSECURE': '0'}
    try:
        for line in open(CONF):
            if '=' in line and not line.strip().startswith('#'):
                k, v = line.split('=', 1); c[k.strip().upper()] = v.strip()
    except Exception:
        pass
    return c

def run(cmd):
    try:
        out = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
        return out.decode('utf-8', 'replace') if isinstance(out, bytes) else out
    except Exception:
        return ''

def num(pattern, text, default=0):
    m = re.search(pattern, text)
    return int(m.group(1)) if m else default

def host_summary():
    """vim-cmd hostsvc/hostsummary 에서 CPU/메모리/가동시간/모델 추출"""
    t = run('vim-cmd hostsvc/hostsummary')
    cpu_mhz = num(r'cpuMhz\s*=\s*(\d+)', t); cores = num(r'numCpuCores\s*=\s*(\d+)', t)
    mem_total = num(r'memorySize\s*=\s*(\d+)', t)                   # bytes
    cpu_used_mhz = num(r'overallCpuUsage\s*=\s*(\d+)', t)           # MHz
    mem_used_mb = num(r'overallMemoryUsage\s*=\s*(\d+)', t)         # MB
    uptime = num(r'uptime\s*=\s*(\d+)', t)
    m = re.search(r'fullName\s*=\s*"([^"]+)"', t)
    osname = m.group(1) if m else 'VMware ESXi'
    m = re.search(r'model\s*=\s*"([^"]+)"', t)
    model = m.group(1) if m else ''
    total_mhz = cpu_mhz * cores
    cpu_pct = round(cpu_used_mhz * 100.0 / total_mhz, 1) if total_mhz else 0.0
    return {'cpu': cpu_pct, 'mem_total': mem_total, 'mem_used': mem_used_mb * 1024 * 1024, 'uptime': uptime, 'os': (osname + (' · ' + model if model else ''))}

def datastores():
    """esxcli storage filesystem list → VMFS/NFS 데이터스토어 용량"""
    t = run('esxcli --formatter=csv --format-param=fields="VolumeName,Size,Free,Type,Mounted" storage filesystem list')
    out = []
    for line in t.splitlines()[1:]:
        p = [x.strip() for x in line.split(',')]
        if len(p) < 5: continue
        name, size, free, typ, mounted = p[0], p[1], p[2], p[3], p[4]
        if not typ.upper().startswith(('VMFS', 'NFS')) or mounted.lower() != 'true': continue
        try:
            size = int(size); free = int(free)
        except ValueError:
            continue
        if size <= 0: continue
        out.append({'mount': name, 'total': size, 'used': size - free})
    return out

def net_bytes():
    """모든 vmnic 의 송수신 바이트 합"""
    rx = tx = 0
    for line in run('esxcli --formatter=csv --format-param=fields="Name" network nic list').splitlines()[1:]:
        nic = line.strip().strip(',')
        if not nic.startswith('vmnic'): continue
        s = run('esxcli network nic stats get -n %s' % nic)
        rx += num(r'Bytes received:\s*(\d+)', s); tx += num(r'Bytes sent:\s*(\d+)', s)
    return rx, tx

def write_status(ok, err, cpu=0, mem_pct=0, conf=None):
    try:
        json.dump({'ok': ok, 'time': time.strftime('%Y-%m-%dT%H:%M:%S'), 'error': err, 'host': HOST, 'name': (conf or {}).get('NAME', ''), 'cpu': cpu, 'mem_pct': mem_pct}, open(STATUS, 'w'))
    except Exception:
        pass

HOST = run('esxcli system hostname get').split('Host Name:')[-1].split('\n')[0].strip() or socket.gethostname()
if not HOST or HOST == 'localhost':
    HOST = socket.gethostname()

def main():
    conf = load_conf()
    url = sys.argv[1] if len(sys.argv) > 1 else conf['URL']
    if not url:
        print('전송 주소(URL)가 없습니다. agent.conf 를 확인하세요.'); sys.exit(1)
    interval = max(2, int(conf.get('INTERVAL') or 5))
    ctx = None
    if conf.get('INSECURE') == '1':
        import ssl; ctx = ssl._create_unverified_context()
    print('%s 에이전트 시작: %s -> %s (간격 %d초)' % (time.strftime('%F %T'), HOST, url, interval)); sys.stdout.flush()
    write_status(False, '시작 중', conf=conf)
    prev_rx, prev_tx, prev_t = 0, 0, time.time(); fail = 0
    try:
        prev_rx, prev_tx = net_bytes()
    except Exception:
        pass
    while True:
        time.sleep(interval)
        conf = load_conf()
        try:
            hs = host_summary()
            disks = datastores()
            now = time.time(); dt = max(1, now - prev_t)
            try:
                rx, tx = net_bytes(); net_rx = int((rx - prev_rx) / dt); net_tx = int((tx - prev_tx) / dt); prev_rx, prev_tx = rx, tx
            except Exception:
                net_rx = net_tx = 0
            prev_t = now
            body = {'host': HOST, 'name': conf.get('NAME', ''), 'os': hs['os'], 'token': conf.get('TOKEN', ''), 'cpu': hs['cpu'],
                    'mem_total': hs['mem_total'], 'mem_used': hs['mem_used'], 'uptime': hs['uptime'], 'net_rx': net_rx, 'net_tx': net_tx, 'disks': disks}
            data = json.dumps(body).encode('utf-8')
            req = Request(url, data=data, headers={'Content-Type': 'application/json', 'X-Token': conf.get('TOKEN', '')})
            resp = urlopen(req, timeout=5, context=ctx) if ctx else urlopen(req, timeout=5)
            resp.read()
            mem_pct = int(hs['mem_used'] * 100 / hs['mem_total']) if hs['mem_total'] else 0
            write_status(True, '', hs['cpu'], mem_pct, conf)
            if fail: print('%s 전송 복구' % time.strftime('%F %T')); sys.stdout.flush()
            fail = 0
        except Exception as e:
            fail += 1
            msg = str(e)
            if '401' in msg: msg = '토큰 불일치 (401)'
            write_status(False, msg, conf=conf)
            if fail <= 3 or fail % 60 == 0:
                print('%s 전송 실패 (%d회): %s' % (time.strftime('%F %T'), fail, msg)); sys.stdout.flush()

if __name__ == '__main__':
    main()
