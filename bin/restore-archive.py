#!/usr/bin/env python3
"""Extract a restore tar stream into private staging, without following links.

Only regular files and directories are accepted. These are extraction safety
caps, not a promise that an archive's contents are authorized for live merge.
The caller owns the staging directory and must refuse merge on a nonzero exit.
"""
import argparse
import os
import pathlib
import sys
import tarfile

DEFAULT_MAX_BYTES = 8 * 1024 ** 3
DEFAULT_MAX_MEMBERS = 100000


class BoundedInfo(tarfile.TarInfo):
    def _proc_pax(self, archive):
        if self.size > 65536:
            raise ValueError('extended header too large')
        return super()._proc_pax(archive)

    def _proc_gnulong(self, archive):
        if self.size > 65536:
            raise ValueError('extended name too large')
        return super()._proc_gnulong(archive)

    def _proc_sparse(self, *args):
        raise ValueError('sparse members are not supported')

    _proc_gnusparse_00 = _proc_sparse
    _proc_gnusparse_01 = _proc_sparse
    _proc_gnusparse_10 = _proc_sparse


def parent_fd(root_fd, parts):
    fd = os.dup(root_fd)
    try:
        for part in parts:
            try:
                os.mkdir(part, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def extract(source, root, *, env_blob=None, prefix=None, max_bytes=DEFAULT_MAX_BYTES, max_members=DEFAULT_MAX_MEMBERS):
    if max_bytes < 1 or max_members < 1:
        raise ValueError('extraction limits must be positive')
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    blob_fd = None
    total = count = 0
    try:
        if env_blob:
            blob_path = pathlib.Path(env_blob)
            blob_fd = os.open(blob_path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        with tarfile.open(fileobj=source, mode='r|', tarinfo=BoundedInfo) as archive:
            for member in archive:
                count += 1
                if count > max_members:
                    raise ValueError('archive member limit exceeded')
                name = member.name
                if name.startswith('/') or any(p == '..' for p in name.split('/')) or '\\' in name or '\x00' in name:
                    raise ValueError('unsafe member path')
                parts = [p for p in name.split('/') if p not in ('', '.')]
                if not parts:
                    if member.isdir():
                        continue
                    raise ValueError('empty member path')
                if len(parts) > 64 or len(name) > 4096:
                    raise ValueError('member path limit exceeded')
                if prefix and parts[0] != prefix:
                    raise ValueError('member outside expected root')
                if not (member.isdir() or member.isfile()) or member.issparse():
                    raise ValueError('unsupported member type')
                if member.size < 0 or (member.isdir() and member.size):
                    raise ValueError('invalid member size')
                total += member.size
                if total > max_bytes:
                    raise ValueError('archive expanded-byte limit exceeded')
                is_blob = env_blob and parts == ['env.tar.age']
                if is_blob and not member.isfile():
                    raise ValueError('encrypted env blob must be a regular file')
                parent = os.dup(blob_fd) if is_blob else parent_fd(root_fd, parts[:-1])
                leaf = blob_path.name if is_blob else parts[-1]
                try:
                    if member.isdir():
                        try:
                            os.mkdir(leaf, mode=0o700, dir_fd=parent)
                        except FileExistsError:
                            check = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                            os.close(check)
                    else:
                        fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
                        with os.fdopen(fd, 'wb') as out, archive.extractfile(member) as data:
                            remaining = member.size
                            while remaining:
                                chunk = data.read(min(65536, remaining))
                                if not chunk:
                                    raise ValueError('truncated member')
                                out.write(chunk)
                                remaining -= len(chunk)
                            os.fchmod(out.fileno(), member.mode & 0o777)
                            out.flush()
                            os.utime(out.fileno(), (member.mtime, member.mtime))
                finally:
                    os.close(parent)
    finally:
        os.close(root_fd)
        if blob_fd is not None:
            os.close(blob_fd)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', required=True)
    p.add_argument('--env-blob')
    p.add_argument('--prefix')
    p.add_argument('--max-bytes', type=int, default=DEFAULT_MAX_BYTES)
    p.add_argument('--max-members', type=int, default=DEFAULT_MAX_MEMBERS)
    args = p.parse_args()
    try:
        extract(sys.stdin.buffer, args.root, env_blob=args.env_blob, prefix=args.prefix,
                max_bytes=args.max_bytes, max_members=args.max_members)
    except (OSError, ValueError, tarfile.TarError):
        print('REFUSED: unsafe, incomplete, duplicate, or over-budget restore archive', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
