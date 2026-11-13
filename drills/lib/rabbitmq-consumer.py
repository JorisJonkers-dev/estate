"""Hold one AMQP connection open, and log everything that happens to it.

The rabbitmq-rotation drill runs this in its throwaway namespace and reads
the log: one JSON object per line, with the time, this pod, the user it
connected as, and the event. It publishes a tick every five seconds, so a
connection that died quietly shows as a failed tick, not as silence.

It is ready (/tmp/connected exists) only while connected, so a rollout keeps
the old pod until the new one has connected.
"""

import json
import os
import signal
import socket
import time

import pika
from pika.exceptions import AMQPError, ConnectionClosedByBroker, ProbableAuthenticationError

POD = os.environ.get("POD_NAME", socket.gethostname())
USER = os.environ["RABBITMQ_USERNAME"]
PASSWORD = os.environ["RABBITMQ_PASSWORD"]
READY = "/tmp/connected"
stopping = False


def log(event, **detail):
    print(json.dumps({"ts": round(time.time(), 3), "pod": POD, "user": USER, "event": event, **detail}), flush=True)


def ready(connected):
    if connected:
        open(READY, "w").close()
    elif os.path.exists(READY):
        os.remove(READY)


def stop(signum, frame):
    global stopping
    stopping = True
    log("sigterm")


signal.signal(signal.SIGTERM, stop)

parameters = pika.ConnectionParameters(
    host=os.environ["RABBITMQ_HOST"],
    virtual_host=os.environ["RABBITMQ_VHOST"],
    credentials=pika.PlainCredentials(USER, PASSWORD),
    heartbeat=10,
    blocked_connection_timeout=30,
    connection_attempts=1,
)

log("start")
# STARTUP_DELAY stands in for a service that takes a while to start: the pod is
# not Ready until it connects, so a rollout keeps the old one until then.
time.sleep(float(os.environ.get("STARTUP_DELAY", "0")))
while not stopping:
    try:
        connection = pika.BlockingConnection(parameters)
    except ProbableAuthenticationError as error:
        log("refused", reason=repr(error))
        time.sleep(3)
        continue
    except AMQPError as error:
        log("connect-failed", reason=repr(error))
        time.sleep(3)
        continue
    log("connected")
    ready(True)
    try:
        channel = connection.channel()
        channel.queue_declare("drill", arguments={"x-max-length": 10})
        while not stopping:
            channel.basic_publish("", "drill", b"tick")
            log("tick")
            connection.process_data_events(time_limit=5)
        connection.close()
        log("closed", by="consumer")
    except ConnectionClosedByBroker as error:
        log("closed", by="broker", code=error.reply_code, text=error.reply_text)
    except AMQPError as error:
        log("lost", reason=repr(error))
    finally:
        ready(False)
    if not stopping:
        time.sleep(3)
log("exit")
