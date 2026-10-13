"""桌面壳的冒烟测试后端。

不启动真实闲鱼链路，只复现 /health 和首页两个端点，用来单独验证
"加载页 -> http://127.0.0.1:<随机端口>" 这段跨 origin 导航。

用法见 shell/scripts/smoke.sh。
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("API_PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            payload = {
                "status": "healthy",
                "timestamp": 0,
                "services": {"cookie_manager": "ok", "database": "ok"},
                "system": {
                    "cpu_percent": 1.0,
                    "memory_percent": 10.0,
                    "memory_available": 1,
                },
            }
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return

        body = (
            "<!doctype html><meta charset=utf-8>"
            "<body style='background:#0f172a;color:#f5b301;font:22px system-ui;"
            "display:flex;align-items:center;justify-content:center;height:100vh'>"
            "<div style='text-align:center'>"
            "<h1>STUB BACKEND OK</h1>"
            "<p>API_PORT=%d</p></div></body>" % PORT
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)


print("stub backend on 127.0.0.1:%d" % PORT, flush=True)
HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
