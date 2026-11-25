#!/usr/bin/env python3
"""
A language server for mayfair-code's tests: just enough of the protocol, predictably.

It keeps each document's text from the edits it's sent, as a real server does, and reports every
"bad" in it as an error whose message is the whole line, so a test can check the server sees the
text as the buffer has it. Completions are always alpha, alphabet and beta; a hover says where it
was asked; a definition is the line with "def target" on it.
"""
import json
import sys

docs = {}


def send(message):
    body = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def read():
    length = 0
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    return json.loads(sys.stdin.buffer.read(length))


def utf16_to_index(line, units):
    """A column in UTF-16 code units, as a Python string index."""
    count = 0
    for i, ch in enumerate(line):
        if count >= units:
            return i
        count += 2 if ord(ch) > 0xFFFF else 1
    return len(line)


def index_to_utf16(line, index):
    return sum(2 if ord(ch) > 0xFFFF else 1 for ch in line[:index])


def apply(text, change):
    if "range" not in change:
        return change["text"]
    lines = text.split("\n")
    r = change["range"]
    s, e = r["start"], r["end"]
    start = sum(len(l) + 1 for l in lines[:s["line"]]) + utf16_to_index(lines[s["line"]], s["character"])
    end = sum(len(l) + 1 for l in lines[:e["line"]]) + utf16_to_index(lines[e["line"]], e["character"])
    return text[:start] + change["text"] + text[end:]


def publish(uri):
    text = docs[uri]
    diagnostics = []
    for n, line in enumerate(text.split("\n")):
        at = line.find("bad")
        while at >= 0:
            diagnostics.append({
                "range": {"start": {"line": n, "character": index_to_utf16(line, at)},
                          "end": {"line": n, "character": index_to_utf16(line, at + 3)}},
                "severity": 1, "source": "fake", "message": line})
            at = line.find("bad", at + 3)
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
          "params": {"uri": uri, "diagnostics": diagnostics}})


while True:
    m = read()
    if m is None:
        break
    method, params = m.get("method"), m.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "capabilities": {"textDocumentSync": 2, "completionProvider": {"triggerCharacters": ["."]},
                             "hoverProvider": True, "definitionProvider": True},
            "serverInfo": {"name": "fake"}}})
    elif method == "textDocument/didOpen":
        docs[params["textDocument"]["uri"]] = params["textDocument"]["text"]
        publish(params["textDocument"]["uri"])
    elif method == "textDocument/didChange":
        uri = params["textDocument"]["uri"]
        for change in params["contentChanges"]:
            docs[uri] = apply(docs[uri], change)
        publish(uri)
    elif method == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": m["id"], "result": [
            {"label": "alpha", "kind": 6, "detail": "int"},
            {"label": "alphabet", "kind": 3, "detail": "fn()"},
            {"label": "beta", "kind": 6}]})
    elif method == "textDocument/hover":
        p = params["position"]
        send({"jsonrpc": "2.0", "id": m["id"],
              "result": {"contents": {"kind": "plaintext", "value": "hover at %d:%d" % (p["line"], p["character"])}}})
    elif method == "textDocument/definition":
        uri = params["textDocument"]["uri"]
        lines = docs[uri].split("\n")
        line = next((n for n, l in enumerate(lines) if "def target" in l), 0)
        send({"jsonrpc": "2.0", "id": m["id"], "result": {
            "uri": uri, "range": {"start": {"line": line, "character": 4}, "end": {"line": line, "character": 10}}}})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
    elif method == "exit":
        break
    elif "id" in m:
        send({"jsonrpc": "2.0", "id": m["id"], "result": None})
