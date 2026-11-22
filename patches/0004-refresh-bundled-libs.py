#!/usr/bin/env python3
# BetterGuac, 2026: replaces third-party libraries bundled in the stock
# Apache Guacamole 1.6.0 web application and extensions with newer upstream
# releases that fix known security issues. The replacement jars are the
# unmodified releases from Maven Central, kept in upstream/third-party/ and
# checked against upstream/third-party/SHA256SUMS. Nested jars (an extension
# jar inside an extension jar) are handled too. Nothing in Guacamole's own
# code is changed.
#
#   0004-refresh-bundled-libs.py <third-party dir> <jar-or-war> [...]
import hashlib, io, os, re, sys, zipfile

# (pattern for the bundled jar's file name, replacement jar)
RULES = [
    (r"jackson-core-2\.[0-9.]+\.jar", "jackson-core-2.21.8.jar"),
    (r"jackson-databind-2\.[0-9.]+\.jar", "jackson-databind-2.21.8.jar"),
    (r"jackson-annotations-2\.[0-9.]+\.jar", "jackson-annotations-2.21.jar"),
    (r"jackson-module-jaxb-annotations-2\.[0-9.]+\.jar", "jackson-module-jaxb-annotations-2.21.8.jar"),
    (r"guava-[0-9.]+-jre\.jar", "guava-33.8.0-jre.jar"),
    (r"failureaccess-[0-9.]+\.jar", "failureaccess-1.0.3.jar"),
    (r"logback-core-1\.[0-9.]+\.jar", "logback-core-1.5.38.jar"),
    (r"logback-classic-1\.[0-9.]+\.jar", "logback-classic-1.5.38.jar"),
    (r"mybatis-3\.[0-9.]+\.jar", "mybatis-3.6.0.jar"),
]

tp = sys.argv[1]
sums = {}
for line in open(os.path.join(tp, "SHA256SUMS")):
    h, f = line.split()
    sums[f.lstrip("*")] = h
new = {}
for _, f in RULES:
    data = open(os.path.join(tp, f), "rb").read()
    assert hashlib.sha256(data).hexdigest() == sums[f], "checksum mismatch: " + f
    new[f] = data

replaced = []

def refresh(blob, where):
    zin = zipfile.ZipFile(io.BytesIO(blob))
    out = io.BytesIO()
    zout = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED)
    names = set()
    for info in zin.infolist():
        name = info.filename
        data = zin.read(name)
        base = name.rsplit("/", 1)[-1]
        if name.endswith(".jar"):
            for rx, f in RULES:
                if re.fullmatch(rx, base):
                    if base != f:
                        replaced.append("%s!%s -> %s" % (where, name, f))
                    name = name[: len(name) - len(base)] + f
                    data = new[f]
                    break
            else:
                if base.startswith("guacamole-"):
                    data = refresh(data, where + "!" + name)
        if name in names:
            continue
        names.add(name)
        ni = zipfile.ZipInfo(name, info.date_time)
        ni.external_attr = info.external_attr
        # nested jars stay stored when they were stored (the class loader
        # reads them either way; keep the original layout)
        ni.compress_type = info.compress_type
        zout.writestr(ni, data)
    zout.close()
    return out.getvalue()

for path in sys.argv[2:]:
    blob = open(path, "rb").read()
    res = refresh(blob, os.path.basename(path))
    open(path + ".tmp", "wb").write(res)
    os.replace(path + ".tmp", path)

# nothing older may be left anywhere inside
def check(blob, where):
    z = zipfile.ZipFile(io.BytesIO(blob))
    for n in z.namelist():
        if not n.endswith(".jar"):
            continue
        base = n.rsplit("/", 1)[-1]
        for rx, f in RULES:
            assert not (re.fullmatch(rx, base) and base != f), "left over: %s!%s" % (where, n)
        if base.startswith("guacamole-"):
            check(z.read(n), where + "!" + n)

for path in sys.argv[2:]:
    check(open(path, "rb").read(), os.path.basename(path))
for r in replaced:
    print("refreshed:", r)
