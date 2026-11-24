"""Provenance stamps for recorded evidence (s2 tools review m-6): the commit, whether the tree was dirty, and a hash
of every `src/` file, so a record says which code produced it (HEAD alone can predate the code)."""
import hashlib, os, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def src_sha(root=ROOT):
    h = hashlib.sha256()
    for d, _, fs in sorted(os.walk(os.path.join(root, 'src'))):
        for f in sorted(fs):
            if f.endswith('.sol'):
                p = os.path.join(d, f)
                h.update(os.path.relpath(p, root).encode() + b'\0' + open(p, 'rb').read() + b'\0')
    return h.hexdigest()[:16]


def stamp(root=ROOT):
    g = lambda *a: subprocess.run(['git', *a], cwd=root, capture_output=True, text=True).stdout.strip()
    return {'commit': g('rev-parse', '--short', 'HEAD'), 'dirty': bool(g('status', '--porcelain', '--', 'src', 'script', 'test')),
            'src_sha': src_sha(root)}
