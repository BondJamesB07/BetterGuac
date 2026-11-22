#!/usr/bin/env python3
"""Open a real session through Guacamole's HTTP tunnel, hold it, disconnect.
usage: tunnel.py <base> <token> <connection id> <seconds>
Prints READY when guacd said ready (the SSH session is up), then DONE."""
import sys, time, urllib.request, urllib.parse, threading

base, token, cid, hold = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
form = urllib.parse.urlencode({
    'token': token, 'GUAC_DATA_SOURCE': 'mysql', 'GUAC_ID': cid, 'GUAC_TYPE': 'c',
    'GUAC_WIDTH': '1024', 'GUAC_HEIGHT': '768', 'GUAC_DPI': '96', 'GUAC_TIMEZONE': 'America/Chicago',
    'GUAC_AUDIO': 'audio/L16', 'GUAC_IMAGE': 'image/png'}).encode()
uuid = urllib.request.urlopen(urllib.request.Request(base + '/tunnel?connect', data=form), timeout=20).read().decode().strip()
print('tunnel', uuid, flush=True)

seen = {'ready': False, 'buf': ''}

def reader():
    n = 0
    end = time.time() + hold + 15
    while time.time() < end:
        try:
            r = urllib.request.urlopen(base + '/tunnel?read:%s:%d' % (uuid, n), timeout=hold + 15)
            while True:
                chunk = r.read(4096)
                if not chunk:
                    break
                s = chunk.decode('utf-8', 'replace')
                seen['buf'] = (seen['buf'] + s)[-20000:]
                if not seen['ready'] and '5.ready,' in seen['buf']:
                    seen['ready'] = True
                    print('READY', flush=True)
                if '10.disconnect;' in s or '5.error,' in s:
                    return
            n += 1
        except Exception as e:
            print('read error', repr(e), flush=True)
            return

t = threading.Thread(target=reader, daemon=True)
t.start()
start = time.time()
while time.time() - start < 3 and not seen['ready']:
    time.sleep(0.2)
# The HTTP read can be refused outside a browser; the session is still made
# (proof: sshd's 'Accepted password' line and the history row).
time.sleep(hold)
try:
    urllib.request.urlopen(urllib.request.Request(base + '/tunnel?write:' + uuid, data=b'10.disconnect;'), timeout=10).read()
except Exception as e:
    print('write error', e)
t.join(10)
print('DONE', flush=True)
