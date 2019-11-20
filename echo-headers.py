#!/usr/bin/env python3

from http.server import HTTPServer, BaseHTTPRequestHandler
from argparse import ArgumentParser
from io import BytesIO
import urllib.parse
import socketserver

class RequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1" # enable keepalive; requires Content-Length
    def handle_one_request(self):
        # reset the expect fields for every request
        self.expect_100_received = False
        self.override_return_100 = False
        return super(RequestHandler, self).handle_one_request()
    def do_POST(self):
        query = urllib.parse.urlparse(self.path).query
        qs_single = dict(urllib.parse.parse_qsl(query))
        body = BytesIO()
        body.write("{} {} {}\r\n".format(self.command, self.path, self.request_version).encode("utf-8"))
        for key, value in self.headers.items():
            body.write("{}: {}\r\n".format(key, value).encode("utf-8"))
        content_length = int(self.headers.get("Content-Length", "0"))
        body.write("\r\n".encode("utf-8"))
        while content_length > 0:
            request_body = self.rfile.read(content_length)
            content_length -= len(request_body)
            if qs_single.get("echo-body", "true") == "true":
                body.write(request_body)
        client_host, client_port = self.client_address
        body.write("\r\nImmediate client address: {}:{}\r\n".format(client_host, client_port).encode("utf-8"))
        
        if self.expect_100_received:
            if self.override_return_100:
                expect_100_message = "Client sent “Expect: 100-continue”, but server did NOT return “100 Continue” (due to ?return-100=false)\r\n"
            else:
                expect_100_message = "Client sent “Expect: 100-continue”, and server returned normally with “100 Continue” (use ?return-100=false to override)\r\n"
        else:
            expect_100_message = "Client did not send “Expect: 100-continue”\r\n"
        body.write(expect_100_message.encode("utf-8"))

        bodybytes = body.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "{}".format(len(bodybytes)))
        self.end_headers()
        self.wfile.write(bodybytes)
        self.wfile.flush()
    def handle_expect_100(self):  # override base method
        query = urllib.parse.urlparse(self.path).query
        qs_single = dict(urllib.parse.parse_qsl(query))
        self.expect_100_received = True
        if qs_single.get("return-100", "true") != "false":
            return super(RequestHandler, self).handle_expect_100()
        else:
            self.override_return_100 = True
            return True
    do_PUT = do_DELETE = do_GET = do_POST

import code, traceback, signal

def debug(sig, frame):
    """Interrupt running process, and provide a python prompt for
    interactive debugging.

    Copied from https://stackoverflow.com/a/133384/471341
    """
    d={'_frame':frame}         # Allow access to frame object.
    d.update(frame.f_globals)  # Unless shadowed by global
    d.update(frame.f_locals)

    i = code.InteractiveConsole(d)
    message  = "Signal received : entering python shell.\nTraceback:\n"
    message += ''.join(traceback.format_stack(frame))
    i.interact(message)

def add_signal_handler():
    signal.signal(signal.SIGUSR1, debug)  # Register handler

# Copied from python 3.7 https://github.com/python/cpython/blob/3.7/Lib/http/server.py
class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True

def main():
    port = 8080
    parser = ArgumentParser(description = "HTTP server that echos headers to the client")
    parser.add_argument("--port", help="Port to listen", default=8080, type=int)
    parser.add_argument("--host", help="Host to bind", default="", type=str)
    args = parser.parse_args()
    print("Listening on {}:{}".format("INADDR_ANY" if args.host == "" else args.host, args.port))
    # If we just use HTTPServer (without threading), it hangs after one request through load balancer
    server = ThreadingHTTPServer((args.host, args.port), RequestHandler)
    add_signal_handler()
    server.serve_forever()

if __name__ == "__main__":
    main()