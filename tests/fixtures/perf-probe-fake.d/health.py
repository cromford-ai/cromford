# owner: BH-9786.6
# The health handler of the perf probe fake server
# (tests/fixtures/perf-probe-fake-server.bh-9786.py). Empty in the tracer
# (BH-9786.0); its owner fills it. A non-None answer wins before the 404.


def handle(req, state):
    return None
