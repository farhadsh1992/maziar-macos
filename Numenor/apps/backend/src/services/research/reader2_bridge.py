"""Serve a same-origin bridge to the authenticated JupyterLab notebook model."""
import json
import os
from pathlib import Path
from urllib.parse import urlencode

from jupyter_server.base.handlers import JupyterHandler
from tornado import web


def _jupyter_server_extension_points():
    return [{"module": "reader2_bridge"}]


class NotebookBridge(JupyterHandler):
    @web.authenticated
    def get(self, notebook):
        token = self.get_query_argument("token", "")
        document = Path(__file__).with_name("notebook-bridge.html").read_text(encoding="utf8")
        config = {
            "origin": os.environ["MAZIAR_READER_ORIGIN"],
            "notebook": notebook,
            "lab": "/lab/tree/" + notebook + ("?" + urlencode({"token": token}) if token else ""),
        }
        self.set_header("Cache-Control", "no-store")
        self.set_header("Content-Type", "text/html; charset=utf-8")
        self.finish(document.replace("__READER2_CONFIG__", json.dumps(config).replace("<", "\\u003c")))


class SourceLink(JupyterHandler):
    @web.authenticated
    def get(self, paper):
        page = self.get_query_argument("page", "1")
        if not page.isascii() or not page.isdecimal():
            page = "1"
        self.redirect(os.environ["MAZIAR_READER_ORIGIN"] + "/reader2/" + paper + "?page=" + page)


def _load_jupyter_server_extension(serverapp):
    serverapp.web_app.add_handlers(".*$", [
        (r"/reader2/bridge/([a-f0-9-]{32,36}\.ipynb)", NotebookBridge),
        (r"/reader2/paper/([a-f0-9-]{32,36})", SourceLink),
    ])
