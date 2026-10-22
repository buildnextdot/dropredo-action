"""A stand-in for the DropRedo API and GitHub's issue comments API, for CI.

The trigger ID picks the run's result: "trigger-pass", "trigger-fail" or
"trigger-manual" (paused for manual action). A run reports "running" on its
first status call and its result from the second on.

GET /_state returns every run body received, status call counts and the
pull request comments, for the tests to assert on.

Usage: python3 tests/mock_server.py PORT
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "Bearer test-token"
GITHUB_TOKEN = "Bearer github-test-token"

RESULTS = {
    "trigger-pass": ("completed", {"total": 3, "passed": 3, "failed": 0, "running": 0}),
    "trigger-fail": ("failed", {"total": 3, "passed": 2, "failed": 1, "running": 0}),
    "trigger-manual": ("waiting for manual action", {"total": 3, "passed": 1, "failed": 0, "running": 2}),
}

state = {"runs": [], "status_calls": {}, "comments": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def base_url(self):
        return f"http://{self.headers['Host']}"

    def execution(self, execution_id, status, counts):
        terminal = status in ("completed", "failed", "force stopped")
        return {
            "execution_id": execution_id,
            "status": status,
            "finished": terminal,
            "passed": status == "completed" and counts["failed"] == 0,
            "counts": counts,
            "report_url": f"{self.base_url()}/r/{execution_id}",
            "app_url": f"{self.base_url()}/workspaces/w/executions/{execution_id}",
        }

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/_state":
            return self.send_json(200, state)

        match = re.fullmatch(r"/api/v1/executions/exec-([\w-]+)", path)
        if match:
            if self.headers.get("Authorization") != TOKEN:
                return self.send_json(401, {"error": {"message": "Invalid API token."}})
            trigger = match.group(1)
            if trigger not in RESULTS:
                return self.send_json(404, {"error": {"message": "Execution not found."}})
            calls = state["status_calls"].get(trigger, 0) + 1
            state["status_calls"][trigger] = calls
            status, counts = RESULTS[trigger]
            if calls == 1:
                status, counts = "running", {"total": 3, "passed": 1, "failed": 0, "running": 2}
            return self.send_json(200, {"success": self.execution(f"exec-{trigger}", status, counts)})

        if re.fullmatch(r"/github/repos/[^/]+/[^/]+/issues/\d+/comments", path):
            if self.headers.get("Authorization") != GITHUB_TOKEN:
                return self.send_json(401, {"message": "Bad credentials"})
            return self.send_json(200, state["comments"])

        self.send_json(404, {"error": {"message": "Not found."}})

    def do_POST(self):
        path = self.path.split("?")[0]

        match = re.fullmatch(r"/api/v1/triggers/([\w-]+)/run", path)
        if match:
            if self.headers.get("Authorization") != TOKEN:
                return self.send_json(401, {"error": {"message": "Invalid API token."}})
            trigger = match.group(1)
            if trigger not in RESULTS:
                return self.send_json(404, {"error": {"message": "Trigger not found."}})
            state["runs"].append({"trigger": trigger, "body": self.read_json()})
            return self.send_json(201, {"success": self.execution(f"exec-{trigger}", "running", RESULTS[trigger][1])})

        if re.fullmatch(r"/github/repos/[^/]+/[^/]+/issues/\d+/comments", path):
            if self.headers.get("Authorization") != GITHUB_TOKEN:
                return self.send_json(401, {"message": "Bad credentials"})
            comment = {"id": len(state["comments"]) + 1, "body": self.read_json()["body"]}
            state["comments"].append(comment)
            return self.send_json(201, comment)

        self.send_json(404, {"error": {"message": "Not found."}})

    def do_PATCH(self):
        match = re.fullmatch(r"/github/repos/[^/]+/[^/]+/issues/comments/(\d+)", self.path)
        if match and self.headers.get("Authorization") == GITHUB_TOKEN:
            for comment in state["comments"]:
                if comment["id"] == int(match.group(1)):
                    comment["body"] = self.read_json()["body"]
                    return self.send_json(200, comment)

        self.send_json(404, {"message": "Not Found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
