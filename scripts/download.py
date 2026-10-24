#!/usr/bin/env python3
"""多连接分段下载：python3 download.py <url> <输出文件> [连接数]"""
import sys, threading, urllib.request, time, os
url, out = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 8
size = int(urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30).headers["Content-Length"])
chunk = 4_000_000
parts = [(i, min(i + chunk, size) - 1) for i in range(0, size, chunk)]
done = {}
lock = threading.Lock()
idx = [0]
def worker():
    while True:
        with lock:
            if idx[0] >= len(parts): return
            k = idx[0]; idx[0] += 1
        a, b = parts[k]
        for attempt in range(6):
            try:
                req = urllib.request.Request(url, headers={"Range": f"bytes={a}-{b}"})
                with urllib.request.urlopen(req, timeout=30) as r:
                    data = r.read()
                if len(data) == b - a + 1:
                    with lock: done[k] = data
                    break
            except Exception as e:
                time.sleep(1 + attempt)
        else:
            print("failed part", k); os._exit(1)
t0 = time.time()
th = [threading.Thread(target=worker) for _ in range(n)]
[t.start() for t in th]
while any(t.is_alive() for t in th):
    time.sleep(10)
    got = sum(len(v) for v in done.values())
    print(f"{got/1e6:.0f}/{size/1e6:.0f} MB  {got/(time.time()-t0)/1e6:.2f} MB/s", flush=True)
with open(out, "wb") as f:
    for k in range(len(parts)): f.write(done[k])
print("ok", out, os.path.getsize(out), f"{time.time()-t0:.0f}s")
