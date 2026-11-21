#!/usr/bin/env python3
# BetterGuac fix for Apache Guacamole 1.6.0 guacamole-auth-jdbc-mysql:
# UserGroupMapper.xml <delete id="delete"> is missing "AND" between
# type = USER_GROUP and the name condition, so every user-group delete
# fails with an SQL syntax error. Rewrites the jar with only that file changed.
import sys, zipfile, shutil
src, dst = sys.argv[1], sys.argv[2]
NAME = "org/apache/guacamole/auth/jdbc/usergroup/UserGroupMapper.xml"
import re
PAT = re.compile(r"(<delete id=\"delete\">\s*DELETE FROM guacamole_entity\s*WHERE\s*type = 'USER_GROUP')(\s*)(<choose>)")
def fix(text):
    out, n = PAT.subn(lambda m: m.group(1) + m.group(2) + "<!-- BetterGuac fix: upstream 1.6.0 omits this AND (SQL syntax error on every group delete) -->" + m.group(2) + "AND" + m.group(2) + m.group(3), text)
    assert n == 1, "unexpected UserGroupMapper.xml content"
    return out
# Second upstream 1.6.0 bug: the sign-in history query used for non-admin users
# filters on guacamole_connection_history.user_id inside a query on
# guacamole_user_history, so it fails with "Unknown column" (HTTP 500).
NAME2 = "org/apache/guacamole/auth/jdbc/user/UserRecordMapper.xml"
BAD2 = "guacamole_connection_history.user_id IN ("
GOOD2 = "guacamole_user_history.user_id IN ( <!-- BetterGuac fix: upstream 1.6.0 names the wrong table here -->"

zin = zipfile.ZipFile(src)
zout = zipfile.ZipFile(dst, "w")
done = False
done2 = False
for info in zin.infolist():
    data = zin.read(info.filename)
    if info.filename == NAME:
        text = data.decode("utf-8")
        data = fix(text).encode("utf-8")
    elif info.filename == NAME2:
        text = data.decode("utf-8")
        assert text.count(BAD2) == 1, "unexpected UserRecordMapper.xml content"
        data = text.replace(BAD2, GOOD2).encode("utf-8")
        done2 = True
        done = True
    zout.writestr(info, data)
zout.close()
assert done and done2
print("patched", dst)
