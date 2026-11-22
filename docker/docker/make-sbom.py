#!/usr/bin/env python3
"""Write the image's SBOM: every installed Debian package, its version,
architecture and source package, as packages.tsv and as an SPDX 2.3 JSON
document. Run at image build time: make-sbom.py <output dir>"""
import json, os, re, subprocess, sys, uuid, datetime

out = sys.argv[1]
fmt = "${Package}\\t${Version}\\t${Architecture}\\t${source:Package}\\t${source:Version}\\t${db:Status-Abbrev}\\n"
rows = []
for line in subprocess.run(["dpkg-query", "-W", "-f", fmt], check=True,
                           capture_output=True, text=True).stdout.splitlines():
    pkg, ver, arch, src, srcver, status = line.split("\t")
    if not status.startswith("ii"):
        continue
    rows.append((pkg, ver, arch, src or pkg, srcver or ver))
rows.sort()

def lic(pkg):
    for p in (f"/usr/share/doc/{pkg}/copyright",):
        if os.path.exists(p):
            return p
    return ""

with open(os.path.join(out, "packages.tsv"), "w") as f:
    f.write("package\tversion\tarchitecture\tsource_package\tsource_version\tlicense_file\n")
    for r in rows:
        f.write("\t".join(r + (lic(r[0]),)) + "\n")

def spdxid(s):
    return "SPDXRef-Package-" + re.sub(r"[^A-Za-z0-9.-]", "-", s)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "betterguac-docker-image",
    "documentNamespace": "https://github.com/BondJamesB07/BetterGuac/spdx/" + str(uuid.uuid4()),
    "creationInfo": {"created": now, "creators": ["Tool: betterguac make-sbom.py"],
                     "comment": "Debian packages installed in the BetterGuac Docker image. "
                                "Licenses: /usr/share/doc/<package>/copyright. "
                                "Source: https://deb.debian.org/debian/pool/main/ or "
                                "https://snapshot.debian.org/, see /usr/share/doc/betterguac/SOURCES."},
    "packages": [],
}
for pkg, ver, arch, src, srcver in rows:
    doc["packages"].append({
        "name": pkg, "SPDXID": spdxid(pkg + "-" + arch), "versionInfo": ver,
        "supplier": "Organization: Debian", "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False, "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
        "sourceInfo": f"Debian source package {src} {srcver}",
        "externalRefs": [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                          "referenceLocator": f"pkg:deb/debian/{pkg}@{ver}?arch={arch}&distro=trixie"}],
    })
with open(os.path.join(out, "betterguac.spdx.json"), "w") as f:
    json.dump(doc, f, indent=1)
print(f"SBOM: {len(rows)} packages")
