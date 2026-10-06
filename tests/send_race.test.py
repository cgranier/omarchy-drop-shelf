#!/usr/bin/python3
"""The send stream never reads a file swapped in after it was looked at.

Reproduces the review finding on #10285: an item is checked, another local
user swaps it for a symlink to a private file, then the stream is built.
Run: /usr/bin/python3 tests/send_race.test.py
"""
import io
import os
import runpy
import stat
import sys
import tarfile
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
helper = runpy.run_path(os.path.join(here, "..", "bin", "dropshelf"), run_name="dropshelf_test")
tar_add_entry, Refused = helper["tar_add_entry"], helper["Refused"]
copy_file, Progress = helper["copy_file"], helper["Progress"]
passed = failed = 0


def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL:", name)


def build(dir_path, name, expect):
    buf = io.BytesIO()
    skipped = []
    error = None
    fd = os.open(dir_path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        with tarfile.open(fileobj=buf, mode="w|", format=tarfile.PAX_FORMAT) as tar:
            try:
                tar_add_entry(tar, fd, name, "0/" + name, skipped, 0, expect)
            except Refused as why:
                error = str(why)
    finally:
        os.close(fd)
    return buf.getvalue(), error


with tempfile.TemporaryDirectory() as work:
    shared = os.path.join(work, "shared")
    os.mkdir(shared)
    secret = os.path.join(work, "private.txt")
    with open(secret, "w") as f:
        f.write("TOP-SECRET-CONTENT")
    item = os.path.join(shared, "report.txt")
    with open(item, "w") as f:
        f.write("harmless report")

    # 1. Looked at, then swapped for a link to the private file.
    st = os.lstat(item)
    os.unlink(item)
    os.symlink(secret, item)
    data, error = build(shared, "report.txt", (st.st_dev, st.st_ino))
    check("swapped item refused", error == "changed while being sent")
    check("private content never in the stream", b"TOP-SECRET-CONTENT" not in data)

    # 2. A link staged on purpose is sent as a link, not its target's content.
    lst = os.lstat(item)
    data, error = build(shared, "report.txt", (lst.st_dev, lst.st_ino))
    members = tarfile.open(fileobj=io.BytesIO(data), mode="r|").getmembers()
    check("staged link travels as a link", error is None and members[0].issym() and members[0].linkname == secret)
    check("its target's content is not read", b"TOP-SECRET-CONTENT" not in data)

    # 3. Inside a folder: a file swapped for a link is stored as the link.
    folder = os.path.join(shared, "album")
    os.mkdir(folder)
    os.symlink(secret, os.path.join(folder, "photo.jpg"))
    fst = os.lstat(folder)
    data, error = build(shared, "album", (fst.st_dev, fst.st_ino))
    check("links inside folders are never followed", error is None and b"TOP-SECRET-CONTENT" not in data)

    # 4. An ordinary file goes through intact.
    plain = os.path.join(shared, "plain.txt")
    with open(plain, "w") as f:
        f.write("plain words")
    pst = os.lstat(plain)
    data, error = build(shared, "plain.txt", (pst.st_dev, pst.st_ino))
    got = tarfile.open(fileobj=io.BytesIO(data), mode="r|")
    member = got.next()
    check("ordinary file sent intact", error is None and got.extractfile(member).read() == b"plain words")

    # 5. Local copy and zip: a file swapped for another file after the look is refused too.
    target = os.path.join(work, "target")
    os.mkdir(target)
    a = os.path.join(shared, "a.txt")
    with open(a, "w") as f:
        f.write("looked at")
    ast = os.lstat(a)
    os.unlink(a)
    os.link(secret, a)  # same user here; another user could only swap in files it can make
    src = os.open(shared, os.O_RDONLY | os.O_DIRECTORY)
    dst = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
    try:
        copy_file(src, "a.txt", dst, ["a.txt"], Progress(0), (ast.st_dev, ast.st_ino))
        check("local copy refuses a swapped file", False)
    except Refused as why:
        check("local copy refuses a swapped file", str(why) == "changed while being delivered" and not os.listdir(target))
    finally:
        os.close(src)
        os.close(dst)

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
