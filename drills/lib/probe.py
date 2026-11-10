#!/usr/bin/env python3
"""Ask one DNS address which replica answers, several times a second.

The drill's responders answer `version.bind` in class CHAOS with the name of
the node they run on, so every line of the log says who answered, or that
nobody did.

    probe.py run ADDRESS LOG [INTERVAL_S] [TIMEOUT_S]
    probe.py once ADDRESS
    probe.py tail LOG SECONDS
    probe.py gap LOG FROM_MS

`run` appends `<epoch ms>\t<ok|timeout|error>\t<node or reason>` until it is
killed. `once` prints who answers, or exits 1. `tail` prints, as JSON, what the
last SECONDS of the log say. `gap` prints, as JSON, the longest stretch without
an answer that starts at or after FROM_MS: from the last answer before it to
the first answer after it, and who answered on each side; `open` is true while
no answer has come back yet.

Standard library only, so it runs with `python3 -I` and nothing installed.
"""

import json
import os
import socket
import struct
import sys
import time

# DRILL_PROBE_PORT asks a responder on another port, such as one run locally to
# test this script.
PORT = int(os.environ.get("DRILL_PROBE_PORT", "53"))


def query(qid):
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    name = b"".join(bytes([len(label)]) + label for label in (b"version", b"bind")) + b"\0"
    return header + name + struct.pack(">HH", 16, 3)  # TXT, class CHAOS


def skip_name(message, i):
    while True:
        length = message[i]
        if length == 0:
            return i + 1
        if length & 0xC0 == 0xC0:
            return i + 2
        i += 1 + length


class Stale(Exception):
    pass


def answer(message, qid):
    rid, flags, questions, answers, _, _ = struct.unpack(">HHHHHH", message[:12])
    if rid != qid:
        raise Stale()
    if flags & 0xF:
        raise ValueError(f"rcode {flags & 0xF}")
    if answers == 0:
        raise ValueError("no answer")
    i = 12
    for _ in range(questions):
        i = skip_name(message, i) + 4
    i = skip_name(message, i)
    rtype, _, _, _ = struct.unpack(">HHIH", message[i : i + 10])
    i += 10
    if rtype != 16:
        raise ValueError(f"answer type {rtype}")
    return message[i + 1 : i + 1 + message[i]].decode(errors="replace")


def ask(sock, address, qid, timeout):
    sock.sendto(query(qid), (address, PORT))
    deadline = time.monotonic() + timeout
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            raise socket.timeout()
        sock.settimeout(left)
        message, _ = sock.recvfrom(512)
        try:
            return answer(message, qid)
        except Stale:
            continue


def run(address, log, interval=0.1, timeout=0.25):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    qid = 0
    with open(log, "a", buffering=1) as out:
        while True:
            started = time.monotonic()
            qid = (qid + 1) & 0xFFFF
            stamp = int(time.time() * 1000)
            try:
                out.write(f"{stamp}\tok\t{ask(sock, address, qid, timeout)}\n")
            except socket.timeout:
                out.write(f"{stamp}\ttimeout\t\n")
            except (OSError, ValueError) as error:
                out.write(f"{stamp}\terror\t{error}\n")
            rest = interval - (time.monotonic() - started)
            if rest > 0:
                time.sleep(rest)


def once(address):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for attempt in range(3):
        try:
            print(ask(sock, address, attempt + 1, 1.0))
            return 0
        except (OSError, ValueError):
            continue
    return 1


def read(log):
    rows = []
    with open(log) as lines:
        for line in lines:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0].isdigit():
                rows.append((int(parts[0]), parts[1] == "ok", parts[2] if len(parts) > 2 else ""))
    return rows


def tail(log, seconds):
    rows = read(log)
    now = int(time.time() * 1000)
    recent = [row for row in rows if row[0] >= now - seconds * 1000]
    streak = 0
    for _, ok, _ in reversed(rows):
        if not ok:
            break
        streak += 1
    last_ok = next((row for row in reversed(rows) if row[1]), None)
    print(json.dumps({
        "answers": sum(1 for row in recent if row[1]),
        "misses": sum(1 for row in recent if not row[1]),
        "streak": streak,
        "last_node": last_ok[2] if last_ok else None,
        "last_ok_ms_ago": now - last_ok[0] if last_ok else None,
    }))


def gap(log, start):
    best = None
    before = None  # the last answer seen
    stretch = None  # [answer before, misses] while nobody answers
    for stamp, ok, node in read(log):
        if ok:
            if stretch is not None:
                found = {"before": stretch[0], "after": {"at": stamp, "node": node},
                         "misses": stretch[1], "open": False}
                if best is None or span(found) > span(best):
                    best = found
                stretch = None
            before = {"at": stamp, "node": node}
        elif stamp >= start:
            if stretch is None:
                stretch = [before, 0]
            stretch[1] += 1
    if stretch is not None:
        found = {"before": stretch[0], "after": None, "misses": stretch[1], "open": True}
        if best is None or span(found) >= span(best):
            best = found
    if best is None:
        print(json.dumps({"gap_ms": 0, "misses": 0, "open": False, "before": before, "after": before}))
        return
    best["gap_ms"] = span(best)
    print(json.dumps(best))


def span(stretch):
    begin = stretch["before"]["at"] if stretch["before"] else None
    end = stretch["after"]["at"] if stretch["after"] else int(time.time() * 1000)
    return end - begin if begin is not None else 0


def main(argv):
    command, args = argv[1], argv[2:]
    if command == "run":
        run(args[0], args[1], *(float(a) for a in args[2:4]))
    elif command == "once":
        return once(args[0])
    elif command == "tail":
        tail(args[0], int(args[1]))
    elif command == "gap":
        gap(args[0], int(args[1]))
    else:
        raise SystemExit(f"unknown command {command}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
