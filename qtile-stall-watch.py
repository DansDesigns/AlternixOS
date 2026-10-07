# ── STALL WATCH — temporary diagnostic, remove once the cause is found ──
# If qtile's event loop stops for more than 3 seconds, every thread's
# stack is written to ~/.local/share/qtile/stall.log, showing exactly
# which line qtile is stuck on. Repeats every 5 seconds while stuck.
import faulthandler
_stall = {"beat": time.monotonic()}

def _stall_beat():
    _stall["beat"] = time.monotonic()
    qtile.call_later(0.5, _stall_beat)

def _stall_watch():
    path = os.path.expanduser("~/.local/share/qtile/stall.log")
    last_dump = 0.0
    while True:
        time.sleep(1)
        now = time.monotonic()
        lag = now - _stall["beat"]
        if lag > 3 and now - last_dump > 5:
            last_dump = now
            with open(path, "a") as f:
                f.write("\n=== qtile stuck for %.1fs at %s ===\n" % (lag, datetime.now()))
                f.flush()
                faulthandler.dump_traceback(file=f, all_threads=True)

@hook.subscribe.startup_complete
def _stall_start():
    _stall_beat()
    threading.Thread(target=_stall_watch, daemon=True).start()
