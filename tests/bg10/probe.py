#!/usr/bin/env python3
"""Remote-desktop probes for BetterGuac.
usage:
  probe.py guacd rdp|vnc HOST PORT USER PASS        -- talk to guacd on 127.0.0.1:4822 directly
  probe.py web   rdp|vnc HOST PORT USER PASS ADMINUSER ADMINPASS [BASEURL]
        -- create the connection through the REST API and open it through Tomcat's HTTP tunnel
Prints counts and exits 0 when the session reached 'ready', streamed screen images and got no error.
"""
import os, json, socket, sys, time, urllib.parse, urllib.request, ssl, threading

WATCH = 15

def enc(*a):
    return ','.join('%d.%s' % (len(x), x) for x in a) + ';'

def parse(buf):
    out = []; i = 0
    while True:
        ins = []; j = i
        while True:
            d = buf.find('.', j)
            if d < 0: return out, buf[i:]
            try: n = int(buf[j:d])
            except ValueError: return out, ''
            e = d + 1 + n
            if e >= len(buf): return out, buf[i:]
            ins.append(buf[d+1:e]); j = e + 1
            if buf[e] == ';': break
        out.append(ins); i = j

def params(proto, host, port, user, pw):
    if proto == 'rdp':
        return {'hostname': host, 'port': port, 'username': user, 'password': pw,
                'security': 'any', 'ignore-cert': 'true'}
    if proto == 'ssh':
        return {'hostname': host, 'port': port, 'username': user, 'password': pw}
    return {'hostname': host, 'port': port, 'password': pw}

def summarize(seen, total, syncs, label, need_ready=True):
    ops = {}
    for x in seen: ops[x[0]] = ops.get(x[0], 0) + 1
    errs = [x for x in seen if x[0] in ('error', 'disconnect')]
    size = [x for x in seen if x[0] == 'size' and x[1] == '0']
    imgs = ops.get('img', 0) + ops.get('png', 0) + ops.get('jpeg', 0)
    print('%s: bytes=%d instructions=%d ready=%s img=%d blob=%d syncs=%d size=%s errors=%s' % (
        label, total, len(seen), 'ready' in ops, imgs, ops.get('blob', 0), syncs,
        size[0][2:4] if size else None, errs[:2]))
    return ('ready' in ops or not need_ready) and imgs >= 1 and syncs >= 1 and not errs

def guacd(proto, host, port, user, pw):
    s = socket.create_connection(('127.0.0.1', 4822), 10); f = s.makefile('rwb')
    f.write(enc('select', proto).encode()); f.flush()
    buf = b''
    while not buf.endswith(b';'): buf += s.recv(1)
    names = [a.split('.', 1)[1] for a in buf.decode()[:-1].split(',')][1:]
    vals = params(proto, host, port, user, pw); vals[names[0]] = names[0]
    for op in (('size', '1024', '768', '96'), ('audio',), ('video',), ('image', 'image/png'), ('timezone', 'UTC')):
        f.write(enc(*op).encode())
    f.write(enc('connect', *[vals.get(n, '') for n in names]).encode()); f.flush()
    s.settimeout(1); end = time.time() + WATCH; rest = ''; seen = []; syncs = 0; total = 0; last = time.time()
    while time.time() < end:
        if time.time() - last > 3:
            f.write(enc('nop').encode()); f.flush(); last = time.time()
        try: c = s.recv(65536)
        except socket.timeout: continue
        if not c: break
        total += len(c); rest += c.decode('utf-8', 'replace')
        ins, rest = parse(rest)
        for x in ins:
            seen.append(x)
            if x[0] == 'sync':
                syncs += 1; f.write(enc('sync', x[1]).encode()); f.flush()
    s.close()
    return summarize(seen, total, syncs, 'guacd-direct %s' % proto)

def web(proto, host, port, user, pw, auser, apw, base, existing=None):
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    hdr = {}
    def req(method, path, data=None, ctype=None, timeout=20):
        r = urllib.request.Request(base + path, data=data, method=method)
        if ctype: r.add_header('Content-Type', ctype)
        for k, v in hdr.items(): r.add_header(k, v)
        return urllib.request.urlopen(r, timeout=timeout, context=ctx)
    tok = json.load(req('POST', '/api/tokens', urllib.parse.urlencode({'username': auser, 'password': apw}).encode(),
                        'application/x-www-form-urlencoded'))
    T = tok['authToken']; ds = tok.get('dataSource', 'mysql')
    if existing:
        cid = existing; print('opening existing connection id=%s' % cid)
    body = {'parentIdentifier': 'ROOT', 'name': 'probe-%s-%d' % (proto, int(time.time())), 'protocol': proto,
            'parameters': params(proto, host, port, user, pw), 'attributes': {}}
    if not existing:
      conn = json.load(req('POST', '/api/session/data/%s/connections?token=%s' % (ds, T), json.dumps(body).encode(), 'application/json'))
      cid = conn['identifier']; print('created %s connection id=%s via REST API (data source %s)' % (proto, cid, ds))
    q = urllib.parse.urlencode({'token': T, 'GUAC_DATA_SOURCE': ds, 'GUAC_ID': cid, 'GUAC_TYPE': 'c',
                                'GUAC_WIDTH': '1024', 'GUAC_HEIGHT': '768', 'GUAC_DPI': '96',
                                'GUAC_IMAGE': 'image/png', 'GUAC_TIMEZONE': 'UTC'}).encode()
    cr = req('POST', '/tunnel?connect', q, 'application/x-www-form-urlencoded')
    uuid = cr.read().decode().strip()
    tt = cr.headers.get('Guacamole-Tunnel-Token')
    if tt: hdr['Guacamole-Tunnel-Token'] = tt
    print('tunnel token header present: %s' % bool(tt))
    print('HTTP tunnel opened, uuid length %d' % len(uuid))
    stop = threading.Event()
    def keepalive():
        while not stop.wait(3):
            try: req('POST', '/tunnel?write:%s' % uuid, enc('nop').encode(), 'application/octet-stream').read()
            except Exception: pass
    threading.Thread(target=keepalive, daemon=True).start()
    end = time.time() + WATCH; seen = []; syncs = 0; total = 0; n = 0; rest = ''; last = time.time()
    while time.time() < end:
        try:
            r = req('GET', '/tunnel?read:%s:%d' % (uuid, n), timeout=10); n += 1
            while True:
                c = r.read1(65536)
                if not c: break
                total += len(c); rest += c.decode('utf-8', 'replace')
                ins, rest = parse(rest)
                out = ''
                if time.time() - last > 3:
                    out += enc('nop'); last = time.time()
                for x in ins:
                    if x[0] == '' or x[0] == 'nop':
                        continue
                    seen.append(x)
                    if x[0] == 'sync':
                        syncs += 1; out += enc('sync', x[1])
                if out:
                    req('POST', '/tunnel?write:%s' % uuid, out.encode(), 'application/octet-stream').read()
                if time.time() > end: break
            if any(x[0] in ('error', 'disconnect') for x in seen): break
        except Exception as e:
            print('tunnel read stopped: %s' % e); break
    stop.set()
    try: req('POST', '/tunnel?write:%s' % uuid, enc('disconnect').encode(), 'application/octet-stream').read()
    except Exception: pass
    ok = summarize(seen, total, syncs, 'web-tunnel %s' % proto, need_ready=False)
    if os.environ.get('PROBE_KEEP') != '1' and not existing:
        try: req('DELETE', '/api/session/data/%s/connections/%s?token=%s' % (ds, cid, T)).read()
        except Exception as e: print('cleanup delete failed: %s' % e)
    return ok

if __name__ == '__main__':
    a = sys.argv[1:]
    if a[0] == 'guacd': ok = guacd(*a[1:6])
    elif a[0] == 'conn': ok = web('ssh', '', '', '', '', a[2], a[3], 'http://127.0.0.1:8080/betterguac', existing=a[1])
    else: ok = web(*a[1:8], a[8] if len(a) > 8 else 'http://127.0.0.1:8080/betterguac')
    sys.exit(0 if ok else 1)
