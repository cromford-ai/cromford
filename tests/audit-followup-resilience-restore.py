"""Restore verification and staging use dummy local objects only."""
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('fixture_restore', ROOT / 'bin/restore-archive.py')
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


def tar_bytes(entries):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w') as stream:
        for name, kind, value in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.mode = 0o600
            data = value.encode()
            if kind == tarfile.REGTYPE:
                info.size = len(data)
                stream.addfile(info, io.BytesIO(data))
            else:
                info.linkname = value
                stream.addfile(info)
    out.seek(0)
    return out


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def test_regular_tree_and_encrypted_blob_are_staged_separately(self):
        tree = self.root / 'tree'
        tree.mkdir()
        archive.extract(tar_bytes([('state/fixture.json', tarfile.REGTYPE, '{}'), ('env.tar.age', tarfile.REGTYPE, 'fixture ciphertext')]), tree, env_blob=self.root / 'env.tar.age')
        self.assertEqual((tree / 'state/fixture.json').read_text(), '{}')
        self.assertEqual((tree / 'state/fixture.json').stat().st_mtime, 0)
        self.assertFalse((tree / 'env.tar.age').exists())
        self.assertEqual((self.root / 'env.tar.age').read_text(), 'fixture ciphertext')

    def test_links_traversal_devices_and_duplicates_are_refused(self):
        for name, kind, value in [('state/link', tarfile.SYMTYPE, '/fixture-outside'), ('state/hard', tarfile.LNKTYPE, 'state/file'), ('../fixture-outside', tarfile.REGTYPE, 'x'), ('/fixture-absolute', tarfile.REGTYPE, 'x'), ('state/device', tarfile.CHRTYPE, '')]:
            with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory(dir=self.root) as tree:
                with self.assertRaises((ValueError, OSError)):
                    archive.extract(tar_bytes([(name, kind, value)]), tree)
        with self.assertRaises(FileExistsError):
            archive.extract(tar_bytes([('fixture', tarfile.REGTYPE, 'a'), ('fixture', tarfile.REGTYPE, 'b')]), self.root)

    def test_existing_directory_symlink_is_not_followed(self):
        outside = self.root / 'outside'
        outside.mkdir()
        tree = self.root / 'tree'
        tree.mkdir()
        (tree / 'state').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            archive.extract(tar_bytes([('state/fixture', tarfile.REGTYPE, 'x')]), tree)
        self.assertFalse((outside / 'fixture').exists())

    def test_expanded_bytes_member_count_and_env_root_are_bounded(self):
        for opts in [{'max_bytes': 1}, {'max_members': 1}, {'prefix': 'env'}]:
            with self.subTest(opts=opts), tempfile.TemporaryDirectory(dir=self.root) as tree:
                with self.assertRaises(ValueError):
                    archive.extract(tar_bytes([('state/a', tarfile.REGTYPE, 'ab'), ('state/b', tarfile.REGTYPE, '')]), tree, **opts)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.blob = self.root / 'fixture.tar'
        self.blob.write_bytes(tar_bytes([('state/fixture', tarfile.REGTYPE, 'fixture')]).getvalue())
        self.stub('zstd', 'exec cat\n')
        self.stub('fixture-s3', '''case "$2" in
list-objects-v2) printf '{"Contents":[{"Key":"fixture/20261105T120000Z.tar.zst","Size":10240}]}' ;;
head-object) [ "$FIXTURE_HEAD" = fail ] && exit 3; printf '%s' "$FIXTURE_HEAD" ;;
get-object) for last; do :; done; cp "$FIXTURE_BLOB" "$last"; printf '{}' ;;
*) exit 4 ;;
esac
''')

    def stub(self, name, body):
        f = self.bin / name
        f.write_text('#!/bin/bash\n' + body)
        f.chmod(0o700)

    def run_restore(self, metadata, *extra):
        (self.root / 'live').mkdir(exist_ok=True)
        env = dict(os.environ, PATH=f'{self.bin}:' + os.environ['PATH'], HARNESS=str(self.root / 'harness'), BACKUP_S3_ENDPOINT='https://fixture.invalid', BACKUP_S3_ACCESS_KEY_ID='fixture-access', BACKUP_S3_SECRET_ACCESS_KEY='fixture-secret', BACKUP_S3_CLIENT=str(self.bin / 'fixture-s3'), FIXTURE_BLOB=str(self.blob), FIXTURE_HEAD=metadata, BOX_NAME='fixture-standby', WATCHDOG_URL='https://watchdog.fixture.invalid', WATCHDOG_SECRET='fixture-watchdog-token', FIXTURE_REPORT=str(self.root / 'report.json'))
        base = self.root / 'harness/tmp' if '--standby' in extra else self.root
        dest = base / ('dest-' + str(len(list(base.glob('dest-*')))))
        proc = subprocess.run(['bash', str(ROOT / 'bin/state-restore.sh'), 'fixture', 'latest', '--dest', str(dest), '--live', str(self.root / 'live'), *extra], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        return proc, dest

    def test_missing_or_unreadable_proof_refuses_before_extraction(self):
        for metadata in ['{}', 'fail', '{invalid', '{"Metadata":{"sha256":"fixture-invalid"}}']:
            with self.subTest(metadata=metadata):
                proc, dest = self.run_restore(metadata)
                self.assertEqual(proc.returncode, 1, proc.stdout)
                self.assertFalse(any(dest.rglob('state/fixture')), proc.stdout)

    def test_explicit_legacy_override_allows_missing_proof_only(self):
        proc, _ = self.run_restore('{}', '--allow-unverified')
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('sha256 unverified', proc.stdout)
        proc, _ = self.run_restore(json.dumps({'Metadata': {'sha256': '0' * 64}}), '--allow-unverified')
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn('sha256 mismatch', proc.stdout)

    def test_valid_hash_continues_to_dry_run(self):
        digest = hashlib.sha256(self.blob.read_bytes()).hexdigest()
        proc, dest = self.run_restore(json.dumps({'Metadata': {'sha256': digest}}))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertTrue(any(dest.rglob('state/fixture')), proc.stdout)

    def test_standby_reports_the_fleet_name_and_keeps_the_bucket_prefix(self):
        state = self.root / 'live/state'
        state.mkdir(parents=True)
        (state / 'standby-of').write_text('box-hub fixture\n')
        (state / 'standby-stream.json').write_text(json.dumps({'of': 'fixture', 'snapshot': '20261105T120000Z', 'rc': 0}))
        identity = self.root / 'fixture-identity'
        identity.write_text('fixture-not-a-real-private-key')
        self.stub('age', 'exit 3\n')
        self.stub('curl', 'while [ $# -gt 0 ]; do\nif [ "$1" = --data ]; then printf \'%s\' "$2" > "$FIXTURE_REPORT"; break; fi\nshift\ndone\n')
        proc, _ = self.run_restore('{}', '--standby', '--apply', '--identity', str(identity))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn('up to date', proc.stdout)
        self.assertEqual(json.loads((self.root / 'report.json').read_text())['of'], 'box-hub')
        self.assertEqual(json.loads((state / 'standby-stream.json').read_text())['of'], 'fixture')

    def test_unverified_override_is_never_used_by_automatic_standby(self):
        proc, _ = self.run_restore('{}', '--standby', '--apply', '--allow-unverified')
        self.assertEqual(proc.returncode, 2, proc.stdout)


if __name__ == '__main__':
    unittest.main()
