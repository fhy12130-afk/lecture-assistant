#!/usr/bin/env python3
"""本地第二识别引擎（sherpa-onnx：SenseVoice / Paraformer），给讲座助手用。

只监听 127.0.0.1。POST /asr?lang=zh|en，请求体是 16 kHz 单声道 16 位小端 PCM，
返回 {"text": "...", "engines": {"sensevoice": "...", "paraformer": "..."}}。
GET /health 返回已加载的模型。

用法：python asr_server.py --models <模型目录> [--port 18765]
模型目录下放 sherpa-onnx-sense-voice-*/ 和（可选）sherpa-onnx-paraformer-zh-*/。
"""
import argparse
import glob
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
import sherpa_onnx

SAMPLE_RATE = 16000


def find(models_dir, pattern):
    hits = sorted(glob.glob(os.path.join(models_dir, pattern)))
    return hits[-1] if hits else None


def model_file(d):
    for name in ("model.int8.onnx", "model.onnx"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return None


class Engines:
    def __init__(self, models_dir, threads):
        self.recognizers = {}
        self.lock = threading.Lock()   # sherpa-onnx 识别器不保证线程安全，串行解码
        sv = find(models_dir, "sherpa-onnx-sense-voice-*")
        if sv and model_file(sv):
            for lang in ("zh", "en"):
                self.recognizers[("sensevoice", lang)] = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                    model=model_file(sv), tokens=os.path.join(sv, "tokens.txt"),
                    num_threads=threads, use_itn=True, language=lang)
        pf = find(models_dir, "sherpa-onnx-paraformer-zh-*")
        if pf and model_file(pf):
            self.recognizers[("paraformer", "zh")] = sherpa_onnx.OfflineRecognizer.from_paraformer(
                paraformer=model_file(pf), tokens=os.path.join(pf, "tokens.txt"), num_threads=threads)
        if not self.recognizers:
            raise SystemExit(f"在 {models_dir} 下没找到 sherpa-onnx 模型")

    def names(self):
        return sorted({k[0] for k in self.recognizers})

    def decode(self, samples, lang):
        out = {}
        with self.lock:
            for (name, l), rec in self.recognizers.items():
                if l != lang:
                    continue
                s = rec.create_stream()
                s.accept_waveform(SAMPLE_RATE, samples)
                rec.decode_stream(s)
                out[name] = s.result.text.strip()
        return out


def make_handler(engines):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def send_json(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if urlparse(self.path).path == "/health":
                self.send_json(200, {"ok": True, "engines": engines.names()})
            else:
                self.send_json(404, {"error": "not found"})

        def do_POST(self):
            u = urlparse(self.path)
            if u.path != "/asr":
                self.send_json(404, {"error": "not found"})
                return
            lang = parse_qs(u.query).get("lang", ["zh"])[0]
            lang = "en" if lang.startswith("en") else "zh"
            n = int(self.headers.get("Content-Length", "0"))
            if n <= 0 or n > SAMPLE_RATE * 2 * 120:     # 最长 2 分钟
                self.send_json(400, {"error": "bad length"})
                return
            raw = self.rfile.read(n)
            samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
            t0 = time.time()
            res = engines.decode(samples, lang)
            best = res.get("paraformer") if lang == "zh" and res.get("paraformer") else res.get("sensevoice", "")
            self.send_json(200, {"text": best or "", "engines": res, "ms": int((time.time() - t0) * 1000)})

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--port", type=int, default=18765)
    ap.add_argument("--threads", type=int, default=4)
    a = ap.parse_args()
    engines = Engines(a.models, a.threads)
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(engines))
    print(json.dumps({"ready": True, "port": a.port, "engines": engines.names()}), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
