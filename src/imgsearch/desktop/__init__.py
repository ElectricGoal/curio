"""JSON-lines engine behind the native desktop application.

Run ``python -m imgsearch.desktop`` to answer a single request from stdin, or
``python -m imgsearch.desktop --serve`` to keep one process (and its loaded
model) alive for many requests.
"""

from imgsearch.desktop.model_store import download_patterns
from imgsearch.desktop.server import dispatch, main, serve
from imgsearch.desktop.storage import configure_storage

__all__ = ["configure_storage", "dispatch", "download_patterns", "main", "serve"]
