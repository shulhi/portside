"""Exercise the actual Android service through an isolated Rust server via adb reverse."""
import contextlib
import http.server
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

repo = Path(__file__).resolve().parents[2]
adb = str(Path(os.environ["ANDROID_HOME"]) / "platform-tools/adb")
devices = subprocess.check_output([adb, "devices"], text=True).splitlines()[1:]
serial = os.environ.get("ANDROID_SERIAL")
if not serial:
    emulators = [row.split()[0] for row in devices if row.startswith("emulator-") and row.endswith("\tdevice")]
    if len(emulators) != 1:
        raise SystemExit("Start one Android 17 emulator, or set ANDROID_SERIAL explicitly.")
    serial = emulators[0]
environment = dict(os.environ, ANDROID_SERIAL=serial)


class Target(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = b"portside-android-runtime-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="portside-android-runtime-") as temporary:
    directory = Path(temporary)
    token = "0123456789abcdef" * 4
    token_path = directory / "test.token"
    token_path.write_text(token)
    token_path.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        server_port = reservation.getsockname()[1]
    target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Target)
    threading.Thread(target=target.serve_forever, daemon=True).start()
    reverse_added = False
    with (directory / "server.log").open("wb") as log:
        server = subprocess.Popen([
            str(repo / "server/target/release/portside-server"), "serve", "--listen",
            f"127.0.0.1:{server_port}", "--token-file", str(token_path),
        ], stdout=subprocess.DEVNULL, stderr=log)
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for attempt in range(100):
                try:
                    request = urllib.request.Request(f"http://127.0.0.1:{server_port}/healthz",
                                                     headers={"Authorization": f"Bearer {token}"})
                    with opener.open(request, timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    if server.poll() is not None:
                        raise RuntimeError("The disposable Rust server stopped: " + (directory / "server.log").read_text()[-2000:])
                    time.sleep(0.05)
            else:
                raise RuntimeError("The disposable Rust server did not start.")
            subprocess.run([adb, "-s", serial, "reverse", "--no-rebind", f"tcp:{server_port}", f"tcp:{server_port}"], check=True)
            reverse_added = True
            subprocess.run([
                str(repo / "android/gradlew"), ":app:connectedDebugAndroidTest",
                f"-Pandroid.testInstrumentationRunnerArguments.serverPort={server_port}",
                f"-Pandroid.testInstrumentationRunnerArguments.targetPort={target.server_port}",
            ], cwd=repo / "android", env=environment, check=True)
        finally:
            if reverse_added:
                subprocess.run([adb, "-s", serial, "reverse", "--remove", f"tcp:{server_port}"], check=False)
            server.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                server.wait(timeout=5)
            if server.poll() is None:
                server.kill()
                server.wait()
            target.shutdown()
            target.server_close()
