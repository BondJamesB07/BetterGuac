#!/usr/bin/env python3
"""betterguac-sync: sync users and connections from a YAML file into the BetterGuac (Apache Guacamole 1.6.0 based)
MariaDB/MySQL database (schema 1.6.0).

Safety model
  * Plan first. `plan` (the default) only reads. `apply --confirm <plan id>` re-plans inside
    one transaction and writes only if the plan is identical to the one you reviewed.
  * Ownership. The tool only changes or deletes objects it created (or that you adopted
    explicitly). Ownership and last-applied state live in a separate database
    (guac_yamlsync), never in Guacamole's tables.
  * Three-way merge per field: YAML now vs. what the tool last wrote vs. the database now.
    A web-UI edit is kept; if YAML changed the same field too, it is a conflict and skipped
    (or the run aborts with --strict). `--overwrite kind:key` is the only way to clobber.
  * Never touched: guacadmin and GUAC_SYNC_PROTECTED_USERS, user attribute rows (TOTP
    secrets and enrollment), history, sharing profiles, user groups.
"""
import argparse, datetime, hashlib, hmac, json, os, re, secrets, stat, sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit('PyYAML missing: sudo apt install python3-yaml')

SCHEMA_VERSION = 1
PLAN_KEY = [b'guac_dbsync']   # replaced with a key derived from the DB password at run time
PROTOCOLS = {'rdp', 'ssh', 'telnet', 'vnc', 'kubernetes'}
SYSTEM_PERMS = ['ADMINISTER', 'CREATE_CONNECTION', 'CREATE_CONNECTION_GROUP',
                'CREATE_SHARING_PROFILE', 'CREATE_USER', 'CREATE_USER_GROUP']
USER_COLS = ['access_window_start', 'access_window_end', 'valid_from', 'valid_until',
             'timezone', 'full_name', 'email_address', 'organization', 'organizational_role']
YAML_USER_COLS = {'access_window_start': 'access_window_start', 'access_window_end': 'access_window_end',
                  'valid_from': 'valid_from', 'valid_until': 'valid_until', 'timezone': 'timezone',
                  'full_name': 'full_name', 'email': 'email_address', 'organization': 'organization',
                  'role': 'organizational_role'}
SECRET_HINTS = ('password', 'passphrase', 'private-key', 'secret', 'token', 'client-key')
KEY_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{0,127}$')
IDENT_RE = re.compile(r'^[A-Za-z0-9_]{1,64}$')
NULLS = {'', '~', 'null', 'Null', 'NULL'}
# SSH keys are a file path on the Guacamole server. The database only gets the
# path (private-key-file) and this placeholder in private-key; BetterGuac's
# extension reads the file when someone connects. Key text never goes in.
SSH_KEY_PLACEHOLDER = '${BETTERGUAC_SSH_PRIVATE_KEY}'
SSH_KEY_DIR_DEFAULT = '/etc/betterguac/keys'


class SyncError(Exception):
    pass


def is_secret_field(field):
    f = field.lower()
    if f == 'private-key-file':
        return False
    return f == 'password' or any(h in f for h in SECRET_HINTS)


# ----------------------------------------------------------------------------- .env

def load_env(path, allow_insecure=False):
    if not os.path.exists(path):
        raise SyncError('.env not found: %s (copy .env.example)' % path)
    st = os.stat(path)
    if st.st_mode & 0o077 and not allow_insecure:
        raise SyncError('%s is readable by other accounts (mode %o); run: chmod 600 %s'
                        % (path, stat.S_IMODE(st.st_mode), path))
    env = {}
    with open(path, encoding='utf-8') as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                raise SyncError('%s line %d: expected KEY=VALUE' % (path, n))
            k, v = line.split('=', 1)
            k, v = k.strip(), v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            env[k] = v
    return env


# ----------------------------------------------------------------------------- YAML

class StrictLoader(yaml.BaseLoader):
    """Every scalar stays a string (no yes->True, 0123->83), duplicate keys are errors."""


def _mapping(loader, node, deep=False):
    seen = set()
    for k, _ in node.value:
        key = loader.construct_scalar(k) if isinstance(k, yaml.ScalarNode) else None
        if key in seen:
            raise SyncError('duplicate key %r at line %d' % (key, k.start_mark.line + 1))
        seen.add(key)
    return loader.construct_mapping(node, deep=True)


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


class Secret:
    """A value that came from env or a file; never printed."""
    def __init__(self, value, source):
        self.value, self.source = value, source


def resolve_value(v, where, env, warnings, field):
    if isinstance(v, dict):
        if set(v) == {'env'}:
            name = v['env']
            val = os.environ.get(name, env.get(name))
            if val is None or val == '':
                raise SyncError('%s: environment variable %s is not set (in the shell or .env)' % (where, name))
            return Secret(val, 'env %s' % name)
        if set(v) == {'file'}:
            p = os.path.expanduser(v['file'])
            try:
                st = os.stat(p)
                with open(p, encoding='utf-8') as f:
                    val = f.read()
            except OSError as e:
                raise SyncError('%s: cannot read %s (%s)' % (where, p, e.strerror))
            if st.st_mode & 0o077:
                warnings.append('%s: %s is readable by other accounts; chmod 600 it' % (where, p))
            if field not in ('private-key', 'public-key'):
                val = val.rstrip('\r\n')
            return Secret(val, 'file %s' % p)
        raise SyncError('%s: a value may be text, {env: NAME} or {file: PATH}' % where)
    if isinstance(v, list):
        raise SyncError('%s: a list is not allowed here' % where)
    return v


def ssh_key_path(v, where, env, warnings, protocol):
    """Checks an SSH key file path. Returns the clean path."""
    key_dir = os.path.normpath(os.environ.get('GUAC_SSH_KEY_DIR', env.get('GUAC_SSH_KEY_DIR', SSH_KEY_DIR_DEFAULT)))
    if protocol != 'ssh':
        raise SyncError('%s: a key file only works for ssh connections' % where)
    if not isinstance(v, str) or not v.strip():
        raise SyncError('%s: write the key file as a path, like %s/web-01' % (where, key_dir))
    v = v.strip()
    if '-----BEGIN' in v or '\n' in v:
        raise SyncError('%s: that is the key itself. Save it as a file in %s and give its path' % (where, key_dir))
    if not v.startswith('/'):
        raise SyncError('%s: use the full path, like %s/web-01 (~ and relative paths are not supported)' % (where, key_dir))
    p = os.path.normpath(v)
    if not (p + '/').startswith(key_dir.rstrip('/') + '/'):
        raise SyncError('%s: key files must be in %s on the Guacamole server; %s is not' % (where, key_dir, p))
    try:
        st = os.stat(p)
    except FileNotFoundError:
        raise SyncError('%s: there is no file at %s' % (where, p))
    except PermissionError:
        warnings.append('%s: cannot check %s from this account; Guacamole checks it when someone connects '
                        '(Test on the Servers page shows the result)' % (where, p))
        return p
    if not stat.S_ISREG(st.st_mode):
        raise SyncError('%s: %s is not a file' % (where, p))
    if st.st_mode & 0o007:
        warnings.append('%s: %s is readable by every account; fix it with sudo chown root:tomcat %s && sudo chmod 640 %s'
                        % (where, p, p, p))
    return p


def _bool(v, where):
    if v in ('true', 'True'):
        return True
    if v in ('false', 'False'):
        return False
    raise SyncError('%s: expected true or false, got %r' % (where, v))


def _int(v, where):
    if v in NULLS:
        return None
    if not re.fullmatch(r'[0-9]{1,9}', v or ''):
        raise SyncError('%s: expected a whole number, got %r' % (where, v))
    return int(v)


def _col(name, v, where):
    if v in NULLS:
        return None
    if name in ('valid_from', 'valid_until'):
        try:
            return datetime.date.fromisoformat(v).isoformat()
        except ValueError:
            raise SyncError('%s: expected YYYY-MM-DD, got %r' % (where, v))
    if name in ('access_window_start', 'access_window_end'):
        m = re.fullmatch(r'([01][0-9]|2[0-3]):([0-5][0-9])(?::([0-5][0-9]))?', v)
        if not m:
            raise SyncError('%s: expected HH:MM or HH:MM:SS, got %r' % (where, v))
        return '%s:%s:%s' % (m.group(1), m.group(2), m.group(3) or '00')
    if len(v) > (64 if name == 'timezone' else 256):
        raise SyncError('%s: too long' % where)
    return v


def load_yaml(path, env, protected):
    warnings = []
    try:
        with open(path, encoding='utf-8') as f:
            doc = yaml.load(f, Loader=StrictLoader)
    except yaml.YAMLError as e:
        raise SyncError('%s is not valid YAML: %s' % (path, e))
    if not isinstance(doc, dict):
        raise SyncError('%s: top level must be a mapping' % path)
    unknown = set(doc) - {'version', 'kind', 'instance', 'connections', 'users'}
    if unknown:
        raise SyncError('unknown top-level keys: %s' % ', '.join(sorted(unknown)))
    if doc.get('version') != '1' or doc.get('kind') != 'guacamole-db-sync':
        raise SyncError('file must start with version: 1 and kind: guacamole-db-sync')
    inst = doc.get('instance', '')
    if not KEY_RE.match(inst or ''):
        raise SyncError('instance: must be a short name like betterguac-sandbox')
    conns, users = {}, {}
    for i, c in enumerate(doc.get('connections') or []):
        where = 'connections[%d]' % i
        if not isinstance(c, dict):
            raise SyncError('%s: must be a mapping' % where)
        bad = set(c) - {'key', 'name', 'group', 'protocol', 'params', 'max_connections', 'max_connections_per_user'}
        if bad:
            raise SyncError('%s: unknown keys %s' % (where, ', '.join(sorted(bad))))
        key = c.get('key', '')
        if not KEY_RE.match(key or ''):
            raise SyncError('%s: key must be lowercase letters, digits, . _ - (got %r)' % (where, key))
        where = 'connection %s' % key
        if key in conns:
            raise SyncError('%s: key used twice' % where)
        name = c.get('name') or ''
        if not name or len(name) > 128 or not isinstance(name, str):
            raise SyncError('%s: name is required (1-128 characters)' % where)
        proto = c.get('protocol')
        if proto not in PROTOCOLS:
            raise SyncError('%s: protocol must be one of %s' % (where, ', '.join(sorted(PROTOCOLS))))
        group = c.get('group')
        if group in NULLS:
            group = None
        if group is not None:
            parts = [p.strip() for p in group.split('/')]
            if any(not p or len(p) > 128 for p in parts):
                raise SyncError('%s: group path %r has an empty or too long part' % (where, group))
            group = '/'.join(parts)
        params = {}
        for pn, pv in (c.get('params') or {}).items():
            if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,127}', pn):
                raise SyncError('%s: bad parameter name %r' % (where, pn))
            if pn in ('private-key', 'private-key-file'):
                if pn == 'private-key':
                    if isinstance(pv, dict) and set(pv) == {'file'}:
                        # Old form: same meaning now, the path is stored instead of the key
                        warnings.append('%s: private-key: {file: ...} is read as private-key-file: %s; '
                                        'write it that way' % (where, pv['file']))
                        pv = pv['file']
                    else:
                        raise SyncError('%s param private-key: SSH keys are a file path now. Write '
                                        'private-key-file: /etc/betterguac/keys/<name> instead of the key' % where)
                if 'private-key-file' in params:
                    raise SyncError('%s: give private-key-file once (not both it and private-key)' % where)
                params['private-key-file'] = ssh_key_path(pv, '%s param private-key-file' % where, env, warnings, proto)
                params['private-key'] = SSH_KEY_PLACEHOLDER
                continue
            val = resolve_value(pv, '%s param %s' % (where, pn), env, warnings, pn)
            raw = val.value if isinstance(val, Secret) else val
            if len(raw) > 4096:
                raise SyncError('%s param %s: longer than 4096 characters' % (where, pn))
            if is_secret_field(pn) and not isinstance(val, Secret):
                warnings.append('%s param %s: secret written inline; prefer {env: ...} or {file: ...}' % (where, pn))
            params[pn] = val
        conns[key] = {'key': key, 'name': name, 'group': group, 'protocol': proto, 'params': params,
                      'cols': {k: _int(c[k], '%s %s' % (where, k)) for k in ('max_connections', 'max_connections_per_user') if k in c}}
    seen_names = {}
    for c in conns.values():
        k = ((c['group'] or '').casefold(), c['name'].casefold())
        if k in seen_names:
            raise SyncError('connections %s and %s have the same name in the same group' % (seen_names[k], c['key']))
        seen_names[k] = c['key']
    for i, u in enumerate(doc.get('users') or []):
        where = 'users[%d]' % i
        if not isinstance(u, dict):
            raise SyncError('%s: must be a mapping' % where)
        allowed = {'username', 'password', 'password_mode', 'disabled', 'expired', 'admin', 'change_own_password',
                   'system_permissions', 'connections'} | set(YAML_USER_COLS)
        bad = set(u) - allowed
        if bad:
            raise SyncError('%s: unknown keys %s' % (where, ', '.join(sorted(bad))))
        name = u.get('username') or ''
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._@-]{0,127}', name):
            raise SyncError('%s: username %r is not allowed' % (where, name))
        where = 'user %s' % name
        key = name.casefold()
        if key in protected:
            raise SyncError('%s is protected (guacadmin or GUAC_SYNC_PROTECTED_USERS); YAML may not manage it' % where)
        if key in users:
            raise SyncError('%s: listed twice (usernames are compared without case)' % where)
        pw = u.get('password')
        if pw is None:
            raise SyncError('%s: password is required, as {env: NAME} or {file: PATH}' % where)
        pw = resolve_value(pw, where + ' password', env, warnings, 'password')
        if not isinstance(pw, Secret):
            raise SyncError('%s: write the password as {env: NAME} or {file: PATH}, not inline' % where)
        mode = u.get('password_mode', 'initial')
        if mode not in ('initial', 'managed'):
            raise SyncError('%s: password_mode must be initial or managed' % where)
        if 'admin' in u and 'system_permissions' in u:
            raise SyncError('%s: use admin or system_permissions, not both' % where)
        if 'admin' in u:
            perms = set(SYSTEM_PERMS) if _bool(u['admin'], where + ' admin') else set()
        else:
            perms = set(u.get('system_permissions') or [])
            if not isinstance(u.get('system_permissions') or [], list) or perms - set(SYSTEM_PERMS):
                raise SyncError('%s: system_permissions may only list %s' % (where, ', '.join(SYSTEM_PERMS)))
        grants = u.get('connections') or []
        if not isinstance(grants, list):
            raise SyncError('%s: connections must be a list of connection keys' % where)
        for g in grants:
            if g not in conns:
                raise SyncError('%s: connection key %r is not defined in this file' % (where, g))
        cols = {}
        for yk, col in YAML_USER_COLS.items():
            if yk in u:
                cols[col] = _col(col, u[yk], '%s %s' % (where, yk))
        users[key] = {'key': key, 'name': name, 'password': pw, 'password_mode': mode,
                      'disabled': _bool(u.get('disabled', 'false'), where + ' disabled'),
                      'expired': _bool(u.get('expired', 'false'), where + ' expired'),
                      'change_own_password': _bool(u.get('change_own_password', 'true'), where + ' change_own_password'),
                      'perms': perms, 'grants': set(grants), 'cols': cols}
    return {'instance': inst, 'connections': conns, 'users': users, 'warnings': warnings}


# ----------------------------------------------------------------------------- hashing

def guac_hash(password, salt):
    """Guacamole JDBC: SHA-256(password + uppercase hex(salt))."""
    return hashlib.sha256((password + salt.hex().upper()).encode('utf-8')).digest()


def fp(pw_hash, pw_salt):
    return hashlib.sha256((pw_hash or b'') + b'|' + (pw_salt or b'')).hexdigest()


def digest(salt, field, value):
    if isinstance(value, Secret):
        value = value.value
    if isinstance(value, (set, frozenset)):
        value = sorted(value)
    blob = json.dumps(value, sort_keys=True)
    return hashlib.sha256(('%s\0%s\0%s' % (salt, field, blob)).encode('utf-8')).hexdigest()


def plain(v):
    return v.value if isinstance(v, Secret) else v


# ----------------------------------------------------------------------------- DB

def connect(env):
    try:
        import pymysql
    except ImportError:  # pragma: no cover
        raise SyncError('PyMySQL missing: sudo apt install python3-pymysql')
    for k in ('GUAC_SYNC_DB_NAME', 'GUAC_SYNC_STATE_DB'):
        if not IDENT_RE.match(env.get(k, '')):
            raise SyncError('%s must be set to a plain database name' % k)
    if not env.get('GUAC_SYNC_DB_PASSWORD') or env.get('GUAC_SYNC_DB_PASSWORD') == 'CHANGE_ME':
        raise SyncError('GUAC_SYNC_DB_PASSWORD is not set in .env')
    kw = dict(user=env.get('GUAC_SYNC_DB_USER', 'guac_yamlsync'), password=env['GUAC_SYNC_DB_PASSWORD'],
              database=env['GUAC_SYNC_DB_NAME'], charset='utf8mb4', autocommit=False)
    if env.get('GUAC_SYNC_DB_SOCKET'):
        kw['unix_socket'] = env['GUAC_SYNC_DB_SOCKET']
    else:
        kw['host'] = env.get('GUAC_SYNC_DB_HOST', '127.0.0.1')
        kw['port'] = int(env.get('GUAC_SYNC_DB_PORT', '3306'))
    try:
        conn = pymysql.connect(**kw)
    except pymysql.err.OperationalError as e:
        raise SyncError('cannot connect to the database: %s' % e.args[-1])
    return conn


def _norm(v):
    if isinstance(v, datetime.timedelta):
        s = int(v.total_seconds())
        return '%02d:%02d:%02d' % (s // 3600, s % 3600 // 60, s % 60)
    if isinstance(v, datetime.date):
        return v.isoformat()
    if isinstance(v, bytes):
        return v
    return v


def load_snapshot(cur, lock):
    sfx = ' FOR UPDATE' if lock else ''
    s = {}
    cur.execute('SELECT e.entity_id, e.name, u.user_id, u.password_hash, u.password_salt, u.disabled, u.expired, '
                + ', '.join('u.' + c for c in USER_COLS) +
                " FROM guacamole_entity e JOIN guacamole_user u ON u.entity_id = e.entity_id WHERE e.type = 'USER'" + sfx)
    s['users'] = {}
    for r in cur.fetchall():
        d = {'entity_id': r[0], 'name': r[1], 'user_id': r[2], 'hash': r[3], 'salt': r[4],
             'disabled': bool(r[5]), 'expired': bool(r[6])}
        for i, c in enumerate(USER_COLS):
            d[c] = _norm(r[7 + i])
        s['users'][r[0]] = d
    cur.execute("SELECT name FROM guacamole_entity WHERE type = 'USER'" + sfx)
    s['user_entity_names'] = {r[0].casefold() for r in cur.fetchall()}
    cur.execute("SELECT entity_id, name FROM guacamole_entity WHERE type = 'USER_GROUP'" + sfx)
    s['group_entities'] = dict(cur.fetchall())
    cur.execute('SELECT entity_id, permission FROM guacamole_system_permission' + sfx)
    s['sysperms'] = {}
    for e, p in cur.fetchall():
        s['sysperms'].setdefault(e, set()).add(p)
    cur.execute('SELECT connection_id, connection_name, parent_id, protocol, max_connections, max_connections_per_user '
                'FROM guacamole_connection' + sfx)
    s['conns'] = {r[0]: {'id': r[0], 'name': r[1], 'parent_id': r[2], 'protocol': r[3],
                         'max_connections': r[4], 'max_connections_per_user': r[5], 'params': {}} for r in cur.fetchall()}
    cur.execute('SELECT connection_id, parameter_name, parameter_value FROM guacamole_connection_parameter' + sfx)
    for cid, n, v in cur.fetchall():
        s['conns'][cid]['params'][n] = v
    cur.execute('SELECT connection_group_id, connection_group_name, parent_id, type FROM guacamole_connection_group' + sfx)
    s['groups'] = {r[0]: {'id': r[0], 'name': r[1], 'parent_id': r[2], 'type': r[3]} for r in cur.fetchall()}
    cur.execute('SELECT entity_id, connection_id, permission FROM guacamole_connection_permission' + sfx)
    s['conn_perms'] = set(cur.fetchall())
    cur.execute('SELECT entity_id, connection_group_id, permission FROM guacamole_connection_group_permission' + sfx)
    s['group_perms'] = set(cur.fetchall())
    cur.execute('SELECT entity_id, affected_user_id, permission FROM guacamole_user_permission' + sfx)
    s['user_perms'] = set(cur.fetchall())
    # attribute NAMES only: TOTP secrets are never read
    cur.execute('SELECT user_id, attribute_name FROM guacamole_user_attribute' + sfx)
    s['user_attrs'] = {}
    for uid, n in cur.fetchall():
        s['user_attrs'].setdefault(uid, set()).add(n)
    cur.execute('SELECT primary_connection_id, COUNT(*) FROM guacamole_sharing_profile GROUP BY primary_connection_id' + sfx)
    s['sharing'] = dict(cur.fetchall())
    cur.execute('SELECT member_entity_id, COUNT(*) FROM guacamole_user_group_member GROUP BY member_entity_id' + sfx)
    s['memberships'] = dict(cur.fetchall())
    return s


def load_state(cur, sdb, lock):
    sfx = ' FOR UPDATE' if lock else ''
    cur.execute('SELECT instance_id, schema_version FROM `%s`.sync_meta WHERE id = 1%s' % (sdb, sfx))
    row = cur.fetchone()
    if not row:
        raise SyncError('state database not initialised; run: betterguac-sync init --instance NAME')
    if row[1] != SCHEMA_VERSION:
        raise SyncError('state schema version %s, tool expects %s' % (row[1], SCHEMA_VERSION))
    cur.execute('SELECT kind, yaml_key, guac_id, guac_name, salt, base_json FROM `%s`.managed_object%s' % (sdb, sfx))
    st = {'instance': row[0], 'user': {}, 'connection': {}, 'group': {}}
    for kind, key, gid, gname, salt, base in cur.fetchall():
        st[kind][key] = {'id': gid, 'name': gname, 'salt': salt, 'base': json.loads(base)}
    return st


# ----------------------------------------------------------------------------- planning

class Plan:
    def __init__(self):
        self.actions = []   # dicts, sorted at the end
        self.notes = []
        self.warnings = []

    def add(self, **a):
        self.actions.append(a)

    def counts(self):
        c = {}
        for a in self.actions:
            c[a['op']] = c.get(a['op'], 0) + 1
        return c

    def canonical(self):
        def enc(v):
            if isinstance(v, Secret):
                return 'secret:' + hmac.new(PLAN_KEY[0], v.value.encode('utf-8'), hashlib.sha256).hexdigest()
            if isinstance(v, (set, frozenset)):
                return sorted(v)
            if isinstance(v, bytes):
                return v.hex()
            if isinstance(v, dict):
                return {k: enc(x) for k, x in v.items()}
            if isinstance(v, (list, tuple)):
                return [enc(x) for x in v]
            return v
        return json.dumps([enc({k: v for k, v in a.items() if not k.startswith('_')}) for a in self.actions],
                          sort_keys=True, default=str)

    @property
    def plan_id(self):
        return hashlib.sha256(self.canonical().encode()).hexdigest()


ORDER = {'conflict': 0, 'create': 1, 'update': 2, 'delete': 3, 'forget': 4, 'unchanged': 5}
KORDER = {'group': 0, 'connection': 1, 'user': 2}


def three_way(field, desired, db, base, salt, default):
    """Returns 'unchanged' | 'write' | 'converged' | 'kept' | 'conflict'."""
    d_y, d_d = digest(salt, field, desired), digest(salt, field, db)
    if field not in base:
        if d_y == d_d:
            return 'converged'
        return 'write' if db == default else 'conflict'
    b = base[field]
    if d_y == d_d:
        return 'unchanged' if d_y == b else 'converged'
    if d_d == b:
        return 'write'
    if d_y == b:
        return 'kept'
    return 'conflict'


def build_plan(cfg, snap, state, overwrite=(), allow_empty=False, allow_mass_delete=False):
    plan = Plan()
    plan.warnings += cfg['warnings']
    if state['instance'] != cfg['instance']:
        raise SyncError('this YAML is for instance %r but the database is %r; wrong file or wrong server?'
                        % (cfg['instance'], state['instance']))
    overwrite = set(overwrite)
    for o in overwrite:
        kind, _, key = o.partition(':')
        if kind not in ('user', 'connection', 'group') or not key:
            raise SyncError('--overwrite takes kind:key, for example connection:yaml-test-ssh')
    managed_total = sum(len(state[k]) for k in ('user', 'connection', 'group'))
    if not cfg['users'] and not cfg['connections'] and managed_total and not allow_empty:
        raise SyncError('the YAML has no users or connections but %d objects are managed; refusing to delete '
                        'everything (use --allow-empty if you really mean it)' % managed_total)
    snap_users_by_name = {u['name'].casefold(): u for u in snap['users'].values()}
    owned_gids = {v['id']: k for k, v in state['group'].items()}
    owned_cids = {v['id']: k for k, v in state['connection'].items()}
    owned_eids = {v['id']: k for k, v in state['user'].items()}

    # ---- groups
    needed = set()
    for c in cfg['connections'].values():
        if c['group']:
            parts = c['group'].split('/')
            for i in range(1, len(parts) + 1):
                needed.add('/'.join(parts[:i]))
    gref = {}      # path -> ('owned', key) | ('id', gid) | ('blocked', reason)
    gcreate = []
    for path in sorted(needed, key=lambda p: (p.count('/'), p)):
        parent_path, _, seg = path.rpartition('/')
        pref = gref.get(parent_path) if parent_path else None
        if pref and pref[0] == 'blocked':
            gref[path] = pref
            continue
        if path in state['group']:
            sg = state['group'][path]
            if sg['id'] in snap['groups']:
                gref[path] = ('owned', path)
                plan.add(op='unchanged', kind='group', key=path)
                continue
            if 'group:' + path not in overwrite:
                gref[path] = ('blocked', 'group %r was deleted outside YAML' % path)
                plan.add(op='conflict', kind='group', key=path,
                         reason='deleted outside YAML; not recreated (use --overwrite group:%s)' % path)
                continue
        parent_id = None
        if pref and pref[0] == 'id':
            parent_id = pref[1]
        elif pref and pref[0] == 'owned':
            parent_id = state['group'][pref[1]]['id'] if pref[1] in state['group'] and state['group'][pref[1]]['id'] in snap['groups'] else 'new'
        existing = None
        if parent_id != 'new':
            for g in snap['groups'].values():
                if g['parent_id'] == parent_id and g['name'].casefold() == seg.casefold() and g['id'] not in owned_gids:
                    existing = g
        if existing:
            gref[path] = ('id', existing['id'])
            plan.notes.append('group %r already exists outside YAML; connections are placed in it, but YAML never '
                              'changes or deletes it' % path)
        else:
            gref[path] = ('owned', path)
            gcreate.append(path)
            pr = None if not parent_path else ('group:' + parent_path if pref[0] == 'owned' else 'id:%d' % pref[1])
            plan.add(op='create', kind='group', key=path, name=seg, after={'name': seg, 'parent': pr},
                     _parent=pr, _recreate=path in state['group'])

    def group_label(parent_id):
        if parent_id is None:
            return None
        if parent_id in owned_gids:
            return 'group:' + owned_gids[parent_id]
        return 'id:%d' % parent_id

    def want_parent(c):
        if not c['group']:
            return None
        r = gref[c['group']]
        return 'group:' + r[1] if r[0] == 'owned' else ('id:%d' % r[1] if r[0] == 'id' else r)

    def group_chain(path):
        if not path:
            return []
        parts = path.split('/')
        refs = []
        for i in range(1, len(parts) + 1):
            r = gref.get('/'.join(parts[:i]))
            if not r or r[0] == 'blocked':
                return []
            refs.append('group:' + r[1] if r[0] == 'owned' else 'id:%d' % r[1])
        return refs

    def ref_gid(ref):
        if ref.startswith('id:'):
            return int(ref[3:])
        sg = state['group'].get(ref[6:])
        return sg['id'] if sg and sg['id'] in snap['groups'] else None

    def ref_alive(ref):
        if ref.startswith('id:'):
            return int(ref[3:]) in snap['groups']
        return ref[6:] in needed

    # ---- connections
    conn_deleting = set()
    conn_available = {}   # key -> True if exists or will be created
    for key in sorted(cfg['connections']):
        c = cfg['connections'][key]
        ow = 'connection:' + key in overwrite
        parent = want_parent(c)
        if isinstance(parent, tuple):
            plan.add(op='conflict', kind='connection', key=key, reason='its group cannot be used: ' + parent[1])
            continue
        desired = {'name': c['name'], 'parent': parent, 'protocol': c['protocol']}
        desired.update(c['cols'])
        for pn, pv in c['params'].items():
            desired['param:' + pn] = pv
        st = state['connection'].get(key)
        if st and st['id'] not in snap['conns'] and not ow:
            plan.add(op='conflict', kind='connection', key=key,
                     reason='deleted outside YAML; not recreated (use --overwrite connection:%s)' % key)
            continue
        if not st or st['id'] not in snap['conns']:
            # collision check: never adopt
            clash = None
            for dc in snap['conns'].values():
                if dc['name'].casefold() == c['name'].casefold() and group_label(dc['parent_id']) == parent and dc['id'] not in owned_cids:
                    clash = dc
            if parent is not None and parent.startswith('group:') and parent[6:] in gcreate:
                clash = None
            if clash:
                plan.add(op='conflict', kind='connection', key=key,
                         reason='a connection named %r already exists there and was not made by YAML; '
                                'not adopted (rename it in YAML, or run adopt)' % c['name'])
                continue
            plan.add(op='create', kind='connection', key=key, name=c['name'], after=desired,
                     _recreate=bool(st))
            conn_available[key] = True
            continue
        dc = snap['conns'][st['id']]
        dbv = {'name': dc['name'], 'parent': group_label(dc['parent_id']), 'protocol': dc['protocol'],
               'max_connections': dc['max_connections'], 'max_connections_per_user': dc['max_connections_per_user']}
        for pn, pv in dc['params'].items():
            dbv['param:' + pn] = pv
        fields = set(desired) | {f for f in st['base'] if f.startswith('param:')}
        diff_object(plan, 'connection', key, c['name'], fields, desired, dbv, st, ow)
        conn_available[key] = True
    for key in sorted(set(state['connection']) - set(cfg['connections'])):
        st = state['connection'][key]
        if st['id'] not in snap['conns']:
            plan.add(op='forget', kind='connection', key=key, reason='already gone from the database')
            continue
        dc = snap['conns'][st['id']]
        ow = 'connection:' + key in overwrite
        dbv = {'name': dc['name'], 'parent': group_label(dc['parent_id']), 'protocol': dc['protocol'],
               'max_connections': dc['max_connections'], 'max_connections_per_user': dc['max_connections_per_user']}
        for pn, pv in dc['params'].items():
            dbv['param:' + pn] = pv
        blockers = []
        drift = sorted(f for f in set(dbv) | set(st['base'])
                       if (f in st['base'] and digest(st['salt'], f, dbv.get(f)) != st['base'][f])
                       or (f not in st['base'] and f.startswith('param:')))
        if drift:
            blockers.append('edited outside YAML (%s)' % ', '.join(drift))
        foreign = sorted({e for (e, cid, p) in snap['conn_perms'] if cid == dc['id'] and e not in owned_eids})
        if foreign:
            names = [snap['users'][e]['name'] if e in snap['users'] else snap['group_entities'].get(e, 'entity %d' % e) for e in foreign]
            blockers.append('access given outside YAML to %s' % ', '.join(sorted(names)))
        if snap['sharing'].get(dc['id']):
            blockers.append('has %d sharing profile(s)' % snap['sharing'][dc['id']])
        before = dict(dbv)
        grantees = sorted(snap['users'][e]['name'] for (e, cid, p) in snap['conn_perms'] if cid == dc['id'] and e in snap['users'])
        before['access'] = grantees
        if blockers and not ow:
            plan.add(op='conflict', kind='connection', key=key, name=dc['name'], before=before,
                     reason='removed from YAML but not deleted: ' + '; '.join(blockers)
                     + ' (use --overwrite connection:%s to delete anyway)' % key)
            continue
        plan.add(op='delete', kind='connection', key=key, name=dc['name'], before=before,
                 also=(['access for %s' % ', '.join(grantees)] if grantees else []) + blockers, _id=dc['id'])
        conn_deleting.add(key)

    # ---- users
    for key in sorted(cfg['users']):
        u = cfg['users'][key]
        ow = 'user:' + key in overwrite
        desired = {'disabled': u['disabled'], 'expired': u['expired'], 'change_own_password': u['change_own_password']}
        desired.update(u['cols'])
        for p in SYSTEM_PERMS:
            desired['sysperm:' + p] = p in u['perms']
        for ck in cfg['connections']:
            if conn_available.get(ck):
                desired['grant:' + ck] = ck in u['grants']
        # Guacamole only shows a connection inside a group if the user can also READ every
        # group above it, exactly like ticking the group in the web UI's permission tree.
        for ck in sorted(u['grants']):
            if conn_available.get(ck):
                for ref in group_chain(cfg['connections'][ck]['group']):
                    desired['grant-group:' + ref] = True
        st = state['user'].get(key)
        if st and st['id'] not in snap['users'] and not ow:
            plan.add(op='conflict', kind='user', key=key,
                     reason='deleted outside YAML; not recreated (use --overwrite user:%s)' % key)
            continue
        if not st or st['id'] not in snap['users']:
            if key in snap_users_by_name or key in snap['user_entity_names']:
                plan.add(op='conflict', kind='user', key=key,
                         reason='user %r already exists and was not made by YAML; not adopted '
                                '(pick another username, or run adopt)' % u['name'])
                continue
            after = dict(desired)
            after['password'] = u['password']
            plan.add(op='create', kind='user', key=key, name=u['name'], after=after, _recreate=bool(st))
            continue
        du = snap['users'][st['id']]
        dbv = {'disabled': du['disabled'], 'expired': du['expired']}
        for c in USER_COLS:
            dbv[c] = du[c]
        perms = snap['sysperms'].get(du['entity_id'], set())
        for p in SYSTEM_PERMS:
            dbv['sysperm:' + p] = p in perms
        dbv['change_own_password'] = (du['entity_id'], du['user_id'], 'UPDATE') in snap['user_perms']
        for ck, cst in state['connection'].items():
            dbv['grant:' + ck] = (du['entity_id'], cst['id'], 'READ') in snap['conn_perms']
        for f in set(desired) | set(st['base']):
            if f.startswith('grant-group:'):
                gid = ref_gid(f[12:])
                dbv[f] = gid is not None and (du['entity_id'], gid, 'READ') in snap['group_perms']
        fields = set(desired) | ({f for f in st['base'] if f.startswith('grant:') and f[6:] in conn_available})
        fields |= {f for f in st['base'] if f.startswith('grant-group:') and ref_alive(f[12:])}
        for f in list(fields):
            if f.startswith('grant:') and f[6:] not in conn_available:
                fields.discard(f)
        pw = None
        if u['password_mode'] == 'managed':
            pw = password_decision(u['password'], du, st)
        diff_object(plan, 'user', key, u['name'], fields, desired, dbv, st, ow, password=pw,
                    pw_value=u['password'], pw_mode=u['password_mode'])
    for key in sorted(set(state['user']) - set(cfg['users'])):
        st = state['user'][key]
        if st['id'] not in snap['users']:
            plan.add(op='forget', kind='user', key=key, reason='already gone from the database')
            continue
        du = snap['users'][st['id']]
        ow = 'user:' + key in overwrite
        blockers, also = [], []
        attrs = snap['user_attrs'].get(du['user_id'], set())
        if any(a.startswith('guac-totp') for a in attrs):
            blockers.append('has a TOTP enrollment, which deleting would erase')
        elif attrs:
            blockers.append('has attributes set outside YAML')
        if snap['memberships'].get(du['entity_id']):
            blockers.append('is in a user group')
        foreign = [cid for (e, cid, p) in snap['conn_perms'] if e == du['entity_id'] and cid not in owned_cids]
        if foreign:
            blockers.append('has access to %d connection(s) not made by YAML' % len(set(foreign)))
        yaml_groups = {ref_gid(f[12:]) for f in st['base'] if f.startswith('grant-group:')} | set(owned_gids)
        if any(e == du['entity_id'] and g not in yaml_groups for (e, g, p) in snap['group_perms']):
            blockers.append('has connection-group permissions not given by YAML')
        dbv = {'disabled': du['disabled'], 'expired': du['expired']}
        for c in USER_COLS:
            dbv[c] = du[c]
        drift = sorted(f for f in dbv if f in st['base'] and digest(st['salt'], f, dbv[f]) != st['base'][f])
        if drift:
            blockers.append('edited outside YAML (%s)' % ', '.join(drift))
        before = {k: v for k, v in dbv.items() if v not in (None, False)}
        before['system_permissions'] = sorted(snap['sysperms'].get(du['entity_id'], set()))
        before['access'] = sorted(snap['conns'][cid]['name'] for (e, cid, p) in snap['conn_perms']
                                  if e == du['entity_id'] and cid in snap['conns'])
        before['totp_enrolled'] = 'guac-totp-key-confirmed' in attrs
        if blockers and not ow:
            plan.add(op='conflict', kind='user', key=key, name=du['name'], before=before,
                     reason='removed from YAML but not deleted: ' + '; '.join(blockers)
                     + ' (use --overwrite user:%s to delete anyway)' % key)
            continue
        if attrs:
            also.append('TOTP enrollment and other attributes' if any(a.startswith('guac-totp') for a in attrs) else 'user attributes')
        also.append('login history is kept, unlinked from the user')
        plan.add(op='delete', kind='user', key=key, name=du['name'], before=before, also=also + blockers, _id=du['entity_id'])

    # ---- groups no longer needed
    for path in sorted(set(state['group']) - needed, key=lambda p: (-p.count('/'), p)):
        sg = state['group'][path]
        if sg['id'] not in snap['groups']:
            plan.add(op='forget', kind='group', key=path, reason='already gone from the database')
            continue
        children = [c for c in snap['conns'].values() if c['parent_id'] == sg['id']
                    and not (c['id'] in owned_cids and owned_cids[c['id']] in conn_deleting)
                    and not (c['id'] in owned_cids and owned_cids[c['id']] in cfg['connections'])]
        moving_in = [k for k, c in cfg['connections'].items() if c['group'] and (c['group'] == path or c['group'].startswith(path + '/'))]
        sub = [g for g in snap['groups'].values() if g['parent_id'] == sg['id']
               and not (g['id'] in owned_gids and owned_gids[g['id']] not in needed)]
        g = snap['groups'][sg['id']]
        foreign_gp = sorted({e for (e, gid, p) in snap['group_perms'] if gid == sg['id'] and e not in owned_eids})
        if foreign_gp and 'group:' + path not in overwrite:
            names = [snap['users'][e]['name'] if e in snap['users'] else snap['group_entities'].get(e, 'entity %d' % e) for e in foreign_gp]
            plan.add(op='conflict', kind='group', key=path, name=g['name'],
                     reason='removed from YAML but not deleted: access given outside YAML to %s' % ', '.join(sorted(names)))
            continue
        if children or sub or moving_in:
            plan.add(op='conflict', kind='group', key=path, name=g['name'],
                     reason='removed from YAML but not deleted: it still holds %d connection(s) and %d group(s) not '
                            'being deleted by YAML' % (len(children), len(sub)))
            continue
        plan.add(op='delete', kind='group', key=path, name=g['name'], before={'name': g['name'], 'parent': group_label(g['parent_id'])},
                 also=[], _id=sg['id'])

    deletes = sum(1 for a in plan.actions if a['op'] == 'delete')
    if deletes and managed_total and not allow_mass_delete and deletes > max(3, managed_total // 2):
        raise SyncError('this plan deletes %d of %d managed objects; that looks like the wrong file. '
                        'Use --allow-mass-delete if it is intended.' % (deletes, managed_total))
    plan.actions.sort(key=lambda a: (ORDER[a['op']], KORDER[a['kind']], a['key']))
    return plan


def password_decision(pw, du, st):
    """Three-way for a managed password, without ever storing it in plain text."""
    base = st['base']
    yaml_changed = digest(st['salt'], 'password', pw) != base.get('password')
    db_changed = fp(du['hash'], du['salt']) != base.get('password_fp')
    matches = du['salt'] is not None and guac_hash(pw.value, du['salt']) == du['hash']
    if matches:
        return 'unchanged' if not (yaml_changed or db_changed) else 'converged'
    if not db_changed:
        return 'write'
    if not yaml_changed:
        return 'kept'
    return 'conflict'


def diff_object(plan, kind, key, name, fields, desired, dbv, st, ow, password=None, pw_value=None, pw_mode=None):
    defaults = {'disabled': False, 'expired': False, 'change_own_password': False}
    writes, kept, conflicts, converged = {}, [], [], []
    for f in sorted(fields):
        want = desired.get(f)
        if f.startswith('param:') or f in USER_COLS or f.startswith('max_'):
            default = None
        elif f.startswith('sysperm:') or f.startswith('grant:') or f.startswith('grant-group:'):
            default = False
        else:
            default = defaults.get(f, None)
        if f not in desired and (f.startswith('param:') or f.startswith('grant')):
            want = None if f.startswith('param:') else False
        r = three_way(f, want, dbv.get(f), st['base'], st['salt'], default)
        if r == 'write' or (ow and r in ('kept', 'conflict')):
            writes[f] = (dbv.get(f), want)
        elif r == 'kept':
            kept.append(f)
        elif r == 'conflict':
            conflicts.append((f, dbv.get(f), want))
        elif r == 'converged':
            converged.append(f)
    if password is not None:
        if password == 'write' or (ow and password in ('kept', 'conflict')):
            writes['password'] = ('(current)', pw_value)
        elif password == 'kept':
            kept.append('password')
        elif password == 'conflict':
            conflicts.append(('password', '(changed in the web UI)', pw_value))
        elif password == 'converged':
            converged.append('password')
    for f in kept:
        plan.notes.append('%s %s: kept the web-UI value of %s (YAML did not change it)' % (kind, key, label(f)))
    if conflicts:
        plan.add(op='conflict', kind=kind, key=key, name=name,
                 fields={f: {'before': b, 'after': a} for f, b, a in conflicts},
                 reason='changed in the web UI and in YAML; skipped (use --overwrite %s:%s to take the YAML value)' % (kind, key))
    if writes:
        plan.add(op='update', kind=kind, key=key, name=name,
                 fields={f: {'before': b, 'after': a} for f, (b, a) in writes.items()},
                 _id=st['id'], _desired=desired, _converged=converged, _pw_mode=pw_mode)
    elif not conflicts:
        plan.add(op='unchanged', kind=kind, key=key, name=name, _converged=converged, _desired=desired)
    if conflicts and not writes:
        pass


# ----------------------------------------------------------------------------- output

def show(field, v):
    if v is None:
        return '(top level)' if field == 'parent' else '(none)'
    if isinstance(v, Secret):
        return '(secret from %s)' % v.source
    if field == 'param:private-key' and v == SSH_KEY_PLACEHOLDER:
        return '(no key stored; read from private-key-file when someone connects)'
    if field == 'param:private-key' and isinstance(v, str) and v.startswith('-----BEGIN'):
        return '(pasted key text)'
    if field == 'password' or (field.startswith('param:') and is_secret_field(field[6:])):
        return '(secret)' if v not in ('', '(current)', '(changed in the web UI)') else str(v)
    if field == 'parent' and isinstance(v, str):
        return v[6:] if v.startswith('group:') else 'existing group #%s (not made by YAML)' % v[3:]
    if isinstance(v, bool):
        return 'yes' if v else 'no'
    if isinstance(v, (list, set)):
        return ', '.join(sorted(v)) if v else '(none)'
    s = str(v)
    return s if len(s) <= 80 else s[:77] + '...'


FIRST = {'name': 0, 'username': 0, 'protocol': 1, 'parent': 2}


def field_order(f):
    return (FIRST.get(f, 5 if f.startswith(('access', 'grant', 'sysperm', 'system_permissions', 'change_own', 'totp')) else 3), f)


def label(f):
    if f.startswith('grant-group:'):
        ref = f[12:]
        return 'see group ' + (ref[6:] if ref.startswith('group:') else '#%s (not made by YAML)' % ref[3:])
    return {'parent': 'group'}.get(f, f.replace('param:', '').replace('sysperm:', 'permission ').replace('grant:', 'access to '))


def render(plan, out=None, verbose=False):
    w = (out or sys.stdout).write
    c = plan.counts()
    w('Plan %s\n' % plan.plan_id)
    w('  %d to create, %d to update, %d to delete, %d conflicts, %d unchanged\n\n' % (
        c.get('create', 0), c.get('update', 0), c.get('delete', 0), c.get('conflict', 0), c.get('unchanged', 0)))
    for a in plan.actions:
        op, kind, key = a['op'], a['kind'], a['key']
        title = '%s %s' % (kind, key) + (' "%s"' % a['name'] if a.get('name') and a.get('name') != key else '')
        if op == 'unchanged':
            if verbose:
                w('= %s: no changes\n' % title)
            continue
        if op == 'create':
            w('+ CREATE %s\n' % title)
            w('    before: (does not exist)\n    after:\n')
            for f in sorted(a['after'], key=field_order):
                v = a['after'][f]
                if (f.startswith('sysperm:') or f.startswith('grant') or f in ('disabled', 'expired')) and v is False:
                    continue
                w('      %s: %s\n' % (label(f), show(f, v)))
        elif op == 'update':
            w('~ UPDATE %s\n' % title)
            for f in sorted(a['fields'], key=field_order):
                b, af = a['fields'][f]['before'], a['fields'][f]['after']
                w('    %s\n      before: %s\n      after:  %s\n' % (label(f), show(f, b), show(f, af)))
        elif op == 'delete':
            w('- DELETE %s\n    before:\n' % title)
            for f in sorted(a['before'], key=field_order):
                v = a['before'][f]
                if (f.startswith('sysperm:') or f in ('disabled', 'expired', 'totp_enrolled')) and v is False:
                    continue
                w('      %s: %s\n' % (label(f), show(f, v)))
            w('    after:  (deleted)\n')
            for x in a.get('also') or []:
                w('    also removes: %s\n' % x)
        elif op == 'conflict':
            w('! CONFLICT %s: %s\n' % (title, a['reason']))
            for f, v in sorted((a.get('fields') or {}).items()):
                w('    %s\n      in the database now: %s\n      YAML wants:          %s\n' % (label(f), show(f, v['before']), show(f, v['after'])))
            if a.get('before') and not a.get('fields'):
                w('    current state:\n')
                for f in sorted(a['before']):
                    v = a['before'][f]
                    if v is False:
                        continue
                    w('      %s: %s\n' % (label(f), show(f, v)))
        elif op == 'forget':
            w('? FORGET %s: %s (only the tool\'s own record is removed)\n' % (title, a['reason']))
        w('\n')
    for n in plan.notes:
        w('note: %s\n' % n)
    for x in plan.warnings:
        w('warning: %s\n' % x)
    if c.get('create') or c.get('update') or c.get('delete') or c.get('forget'):
        w('\nNothing was written. To apply exactly this plan:\n  betterguac-sync apply FILE --confirm %s\n' % plan.plan_id)
    else:
        w('\nNothing to apply.\n')


# ----------------------------------------------------------------------------- apply

def new_salt():
    return secrets.token_hex(16)


def apply_plan(cur, sdb, plan, cfg, state, snap):
    now = datetime.datetime.now().replace(microsecond=0)
    gids = {k: v['id'] for k, v in state['group'].items()}
    cids = {k: v['id'] for k, v in state['connection'].items()}
    new_state = {}   # (kind,key) -> (id, name, salt, base)
    acts = plan.actions

    def gid_of(ref):
        if ref is None:
            return None
        if ref.startswith('group:'):
            return gids[ref[6:]]
        return int(ref[3:])

    # groups (parents first; actions already sorted by key, and parent paths sort before children)
    for a in sorted([a for a in acts if a['op'] == 'create' and a['kind'] == 'group'], key=lambda a: a['key'].count('/')):
        parent = gid_of(a['_parent'])
        cur.execute("INSERT INTO guacamole_connection_group (connection_group_name, parent_id, type) VALUES (%s, %s, 'ORGANIZATIONAL')",
                    (a['name'], parent))
        gids[a['key']] = cur.lastrowid
        salt = new_salt()
        new_state[('group', a['key'])] = (cur.lastrowid, a['name'], salt,
                                         {'name': digest(salt, 'name', a['name'])})
    # connections
    for a in [a for a in acts if a['kind'] == 'connection' and a['op'] in ('create', 'update')]:
        if a['op'] == 'create':
            d = a['after']
            cur.execute('INSERT INTO guacamole_connection (connection_name, parent_id, protocol, max_connections, max_connections_per_user) '
                        'VALUES (%s, %s, %s, %s, %s)', (d['name'], gid_of(d['parent']), d['protocol'],
                                                        d.get('max_connections'), d.get('max_connections_per_user')))
            cid = cur.lastrowid
            for f, v in d.items():
                if f.startswith('param:'):
                    cur.execute('INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES (%s, %s, %s)',
                                (cid, f[6:], plain(v)))
            cids[a['key']] = cid
            salt = new_salt()
            new_state[('connection', a['key'])] = (cid, d['name'], salt, {f: digest(salt, f, v) for f, v in d.items()})
        else:
            cid = a['_id']
            for f, ch in a['fields'].items():
                v = plain(ch['after'])
                if f.startswith('param:'):
                    if v is None:
                        cur.execute('DELETE FROM guacamole_connection_parameter WHERE connection_id = %s AND parameter_name = %s', (cid, f[6:]))
                    else:
                        cur.execute('INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES (%s, %s, %s) '
                                    'ON DUPLICATE KEY UPDATE parameter_value = VALUES(parameter_value)', (cid, f[6:], v))
                elif f == 'name':
                    cur.execute('UPDATE guacamole_connection SET connection_name = %s WHERE connection_id = %s', (v, cid))
                elif f == 'parent':
                    cur.execute('UPDATE guacamole_connection SET parent_id = %s WHERE connection_id = %s', (gid_of(v), cid))
                elif f in ('protocol', 'max_connections', 'max_connections_per_user'):
                    cur.execute('UPDATE guacamole_connection SET `%s` = %%s WHERE connection_id = %%s' % f, (v, cid))
    # users
    for a in [a for a in acts if a['kind'] == 'user' and a['op'] in ('create', 'update')]:
        u = cfg['users'][a['key']]
        if a['op'] == 'create':
            d = a['after']
            cur.execute("INSERT INTO guacamole_entity (name, type) VALUES (%s, 'USER')", (u['name'],))
            eid = cur.lastrowid
            ps = os.urandom(32)
            ph = guac_hash(u['password'].value, ps)
            cols = ['entity_id', 'password_hash', 'password_salt', 'password_date', 'disabled', 'expired'] + list(u['cols'])
            vals = [eid, ph, ps, now, int(u['disabled']), int(u['expired'])] + [u['cols'][c] for c in u['cols']]
            cur.execute('INSERT INTO guacamole_user (%s) VALUES (%s)' % (', '.join('`%s`' % c for c in cols), ', '.join(['%s'] * len(cols))), vals)
            uid = cur.lastrowid
            # what Guacamole itself grants a new user: READ on their own account
            cur.execute("INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission) VALUES (%s, %s, 'READ')", (eid, uid))
            if u['change_own_password']:
                # the web UI's "Change own password" box: UPDATE on their own account
                cur.execute("INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission) VALUES (%s, %s, 'UPDATE')", (eid, uid))
            for p in sorted(u['perms']):
                cur.execute('INSERT INTO guacamole_system_permission (entity_id, permission) VALUES (%s, %s)', (eid, p))
            for ck in sorted(u['grants']):
                if ck in cids and d.get('grant:' + ck):
                    cur.execute("INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission) VALUES (%s, %s, 'READ')", (eid, cids[ck]))
            for f in sorted(d):
                if f.startswith('grant-group:') and d[f]:
                    cur.execute("INSERT IGNORE INTO guacamole_connection_group_permission (entity_id, connection_group_id, permission) VALUES (%s, %s, 'READ')",
                                (eid, gid_of(f[12:])))
            salt = new_salt()
            base = {f: digest(salt, f, v) for f, v in d.items() if f != 'password'}
            base['password'] = digest(salt, 'password', u['password'])
            base['password_fp'] = fp(ph, ps)
            new_state[('user', a['key'])] = (eid, u['name'], salt, base)
        else:
            eid = a['_id']
            uid = snap['users'][eid]['user_id']
            for f, ch in a['fields'].items():
                v = ch['after']
                if f == 'password':
                    ps = os.urandom(32)
                    ph = guac_hash(v.value, ps)
                    cur.execute('UPDATE guacamole_user SET password_hash = %s, password_salt = %s, password_date = %s WHERE user_id = %s',
                                (ph, ps, now, uid))
                    a['_new_fp'] = fp(ph, ps)
                elif f in ('disabled', 'expired') or f in USER_COLS:
                    cur.execute('UPDATE guacamole_user SET `%s` = %%s WHERE user_id = %%s' % f,
                                (int(v) if isinstance(v, bool) else v, uid))
                elif f.startswith('sysperm:'):
                    if v:
                        cur.execute('INSERT IGNORE INTO guacamole_system_permission (entity_id, permission) VALUES (%s, %s)', (eid, f[8:]))
                    else:
                        cur.execute('DELETE FROM guacamole_system_permission WHERE entity_id = %s AND permission = %s', (eid, f[8:]))
                elif f == 'change_own_password':
                    if v:
                        cur.execute("INSERT IGNORE INTO guacamole_user_permission (entity_id, affected_user_id, permission) VALUES (%s, %s, 'UPDATE')", (eid, uid))
                    else:
                        cur.execute("DELETE FROM guacamole_user_permission WHERE entity_id = %s AND affected_user_id = %s AND permission = 'UPDATE'", (eid, uid))
                elif f.startswith('grant-group:'):
                    gid = gid_of(f[12:])
                    if v:
                        cur.execute("INSERT IGNORE INTO guacamole_connection_group_permission (entity_id, connection_group_id, permission) VALUES (%s, %s, 'READ')", (eid, gid))
                    else:
                        cur.execute("DELETE FROM guacamole_connection_group_permission WHERE entity_id = %s AND connection_group_id = %s AND permission = 'READ'", (eid, gid))
                elif f.startswith('grant:'):
                    cid = cids[f[6:]]
                    if v:
                        cur.execute("INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission) VALUES (%s, %s, 'READ')", (eid, cid))
                    else:
                        cur.execute("DELETE FROM guacamole_connection_permission WHERE entity_id = %s AND connection_id = %s AND permission = 'READ'", (eid, cid))
    # deletes: users, then connections, then groups (deepest first)
    for kind, sql in (('user', 'DELETE FROM guacamole_entity WHERE entity_id = %s AND type = \'USER\''),
                      ('connection', 'DELETE FROM guacamole_connection WHERE connection_id = %s'),
                      ('group', 'DELETE FROM guacamole_connection_group WHERE connection_group_id = %s')):
        dels = [a for a in acts if a['op'] == 'delete' and a['kind'] == kind]
        if kind == 'group':
            dels.sort(key=lambda a: -a['key'].count('/'))
        for a in dels:
            cur.execute(sql, (a['_id'],))
            if cur.rowcount != 1:
                raise SyncError('%s %s vanished during apply; rolled back' % (kind, a['key']))
            cur.execute('DELETE FROM `%s`.managed_object WHERE kind = %%s AND yaml_key = %%s' % sdb, (kind, a['key']))
    for a in acts:
        if a['op'] == 'forget':
            cur.execute('DELETE FROM `%s`.managed_object WHERE kind = %%s AND yaml_key = %%s' % sdb, (a['kind'], a['key']))
    # refresh bases of updated / unchanged objects
    for a in acts:
        if a['op'] not in ('update', 'unchanged') or a['kind'] == 'group':
            continue
        st = state[a['kind']][a['key']]
        base = dict(st['base'])
        desired = a.get('_desired')
        for f, ch in (a.get('fields') or {}).items():
            if f == 'password':
                base['password'] = digest(st['salt'], 'password', ch['after'])
                base['password_fp'] = a['_new_fp']
            elif ch['after'] is None and f.startswith('param:'):
                base.pop(f, None)
            else:
                base[f] = digest(st['salt'], f, ch['after'])
        for f in a.get('_converged') or []:
            if f == 'password':
                u = cfg['users'][a['key']]
                du = snap['users'][st['id']]
                base['password'] = digest(st['salt'], 'password', u['password'])
                base['password_fp'] = fp(du['hash'], du['salt'])
                continue
            v = (desired or {}).get(f)
            if v is None and f.startswith('param:'):
                base.pop(f, None)
            elif v is None and f.startswith('grant'):
                base[f] = digest(st['salt'], f, False)
            else:
                base[f] = digest(st['salt'], f, v)
        # stop tracking optional columns YAML no longer lists, and grants on deleted connections
        if a['kind'] == 'user':
            u = cfg['users'][a['key']]
            for f in list(base):
                if f in USER_COLS and f not in u['cols']:
                    base.pop(f)
                if f.startswith('grant:') and f[6:] not in cids:
                    base.pop(f)
                if f.startswith('grant-group:group:') and f[18:] not in gids:
                    base.pop(f)
        else:
            c = cfg['connections'][a['key']]
            for f in ('max_connections', 'max_connections_per_user'):
                if f in base and f not in c['cols']:
                    base.pop(f)
        new_state[(a['kind'], a['key'])] = (st['id'], a.get('name') or st['name'], st['salt'], base)
    for a in acts:
        if a['op'] == 'delete' and a['kind'] in ('connection', 'group'):
            field = ('grant:' if a['kind'] == 'connection' else 'grant-group:group:') + a['key']
            for (k, key), v in list(new_state.items()):
                if k == 'user':
                    v[3].pop(field, None)
    for (kind, key), (gid, name, salt, base) in new_state.items():
        cur.execute('INSERT INTO `%s`.managed_object (kind, yaml_key, guac_id, guac_name, salt, base_json, created_at, updated_at) '
                    'VALUES (%%s, %%s, %%s, %%s, %%s, %%s, %%s, %%s) ON DUPLICATE KEY UPDATE guac_id = VALUES(guac_id), '
                    'guac_name = VALUES(guac_name), salt = VALUES(salt), base_json = VALUES(base_json), updated_at = VALUES(updated_at)' % sdb,
                    (kind, key, gid, name, salt, json.dumps(base, sort_keys=True), now, now))
    cur.execute('UPDATE `%s`.sync_meta SET last_apply_at = %%s, last_plan_id = %%s WHERE id = 1' % sdb, (now, plan.plan_id))
    cur.execute('INSERT INTO `%s`.apply_log (applied_at, plan_id, summary_json) VALUES (%%s, %%s, %%s)' % sdb,
                (now, plan.plan_id, json.dumps(plan.counts(), sort_keys=True)))


# ----------------------------------------------------------------------------- adopt

def adopt(cur, sdb, cfg, snap, state, target, protected):
    kind, _, key = target.partition(':')
    if kind == 'user':
        if key.casefold() in protected:
            raise SyncError('user %s is protected and cannot be adopted' % key)
        u = cfg['users'].get(key.casefold())
        if not u:
            raise SyncError('user %s is not in the YAML file' % key)
        if u['key'] in state['user']:
            raise SyncError('user %s is already managed' % key)
        du = next((x for x in snap['users'].values() if x['name'].casefold() == u['key']), None)
        if not du:
            raise SyncError('no user %s in the database to adopt' % key)
        salt = new_salt()
        base = {'disabled': digest(salt, 'disabled', du['disabled']), 'expired': digest(salt, 'expired', du['expired'])}
        for c in USER_COLS:
            base[c] = digest(salt, c, du[c])
        for p in SYSTEM_PERMS:
            base['sysperm:' + p] = digest(salt, 'sysperm:' + p, p in snap['sysperms'].get(du['entity_id'], set()))
        base['change_own_password'] = digest(salt, 'change_own_password', (du['entity_id'], du['user_id'], 'UPDATE') in snap['user_perms'])
        for ck, cst in state['connection'].items():
            base['grant:' + ck] = digest(salt, 'grant:' + ck, (du['entity_id'], cst['id'], 'READ') in snap['conn_perms'])
        base['password'] = 'adopted'
        base['password_fp'] = fp(du['hash'], du['salt'])
        return ('user', u['key'], du['entity_id'], du['name'], salt, base)
    if kind == 'connection':
        c = cfg['connections'].get(key)
        if not c:
            raise SyncError('connection %s is not in the YAML file' % key)
        if key in state['connection']:
            raise SyncError('connection %s is already managed' % key)
        owned = {v['id'] for v in state['connection'].values()}
        hits = [x for x in snap['conns'].values() if x['name'].casefold() == c['name'].casefold() and x['id'] not in owned]
        if len(hits) != 1:
            raise SyncError('expected exactly one unmanaged connection named %r, found %d' % (c['name'], len(hits)))
        dc = hits[0]
        gl = None
        if dc['parent_id'] is not None:
            owned_g = {v['id']: k for k, v in state['group'].items()}
            gl = 'group:' + owned_g[dc['parent_id']] if dc['parent_id'] in owned_g else 'id:%d' % dc['parent_id']
        salt = new_salt()
        base = {'name': digest(salt, 'name', dc['name']), 'protocol': digest(salt, 'protocol', dc['protocol']),
                'parent': digest(salt, 'parent', gl)}
        for f in ('max_connections', 'max_connections_per_user'):
            base[f] = digest(salt, f, dc[f])
        for pn, pv in dc['params'].items():
            base['param:' + pn] = digest(salt, 'param:' + pn, pv)
        return ('connection', key, dc['id'], dc['name'], salt, base)
    raise SyncError('adopt takes user:NAME or connection:KEY')


# ----------------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description='Sync Guacamole users and connections from YAML into MariaDB (dry run by default).')
    ap.add_argument('--env', default=os.environ.get('GUAC_SYNC_ENV', '.env'),
                    help='path to the .env file (default /etc/betterguac/sync.env when run through the betterguac-sync wrapper, otherwise ./.env)')
    ap.add_argument('--insecure-env', action='store_true', help=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('check', help='validate the YAML only (no database)')
    p.add_argument('file')
    p = sub.add_parser('init', help='record the instance name in the state database (once)')
    p.add_argument('--instance', required=True)
    for name in ('plan', 'apply'):
        if name == 'plan':
            p = sub.add_parser(name, help='preview the changes and print a plan ID (writes nothing)')
        else:
            p = sub.add_parser(name, help='apply exactly the plan you reviewed (--confirm PLAN_ID)')
        p.add_argument('file')
        p.add_argument('--overwrite', action='append', default=[], metavar='KIND:KEY',
                       help='take the YAML value for this object even over web-UI edits / delete conflicts')
        p.add_argument('--allow-empty', action='store_true')
        p.add_argument('--allow-mass-delete', action='store_true')
        p.add_argument('--strict', action='store_true', help='treat any conflict as an error')
        p.add_argument('--json', action='store_true')
        p.add_argument('-v', '--verbose', action='store_true')
        if name == 'apply':
            p.add_argument('--confirm', required=True, metavar='PLAN_ID')
    p = sub.add_parser('adopt', help='take ownership of one existing object (dry run unless --confirm)')
    p.add_argument('file')
    p.add_argument('target', metavar='user:NAME|connection:KEY')
    p.add_argument('--confirm', action='store_true')
    p = sub.add_parser('status', help='list what the tool manages')
    a = ap.parse_args(argv)
    try:
        env = load_env(a.env, a.insecure_env) if a.cmd != 'check' or os.path.exists(a.env) else {}
        protected = {'guacadmin'} | {x.strip().casefold() for x in env.get('GUAC_SYNC_PROTECTED_USERS', '').split(',') if x.strip()}
        if a.cmd == 'check':
            cfg = load_yaml(a.file, env, protected)
            print('OK: %d connections, %d users (instance %s)' % (len(cfg['connections']), len(cfg['users']), cfg['instance']))
            for c in cfg['connections'].values():
                print('  connection %s: params %s' % (c['key'], ', '.join(sorted(c['params']))))
            for x in cfg['warnings']:
                print('warning: ' + x)
            return 0
        sdb = env.get('GUAC_SYNC_STATE_DB', 'guac_yamlsync')
        PLAN_KEY[0] = hashlib.sha256(('guac_dbsync-plan\0' + env.get('GUAC_SYNC_DB_PASSWORD', '')).encode()).digest()
        conn = connect(env)
        try:
            cur = conn.cursor()
            if a.cmd == 'init':
                if not KEY_RE.match(a.instance):
                    raise SyncError('instance name: lowercase letters, digits, . _ -')
                cur.execute('SELECT instance_id FROM `%s`.sync_meta WHERE id = 1' % sdb)
                r = cur.fetchone()
                if r:
                    raise SyncError('already initialised as %r' % r[0])
                cur.execute('INSERT INTO `%s`.sync_meta (id, instance_id, schema_version, created_at) VALUES (1, %%s, %%s, NOW())' % sdb,
                            (a.instance, SCHEMA_VERSION))
                conn.commit()
                print('initialised instance %s' % a.instance)
                return 0
            if a.cmd == 'status':
                st = load_state(cur, sdb, False)
                print('instance %s' % st['instance'])
                for k in ('group', 'connection', 'user'):
                    for key, v in sorted(st[k].items()):
                        print('  %-10s %-30s id %-6d %s' % (k, key, v['id'], v['name']))
                conn.rollback()
                return 0
            cfg = load_yaml(a.file, env, protected)
            if a.cmd == 'adopt':
                st = load_state(cur, sdb, a.confirm)
                if st['instance'] != cfg['instance']:
                    raise SyncError('YAML instance %r does not match database %r' % (cfg['instance'], st['instance']))
                snap = load_snapshot(cur, a.confirm)
                rec = adopt(cur, sdb, cfg, snap, st, a.target, protected)
                print('would adopt %s %s (database id %d, %r); its current values become the baseline, so the next plan '
                      'shows YAML differences as updates' % rec[:4] if not a.confirm else 'adopted %s %s (database id %d, %r)' % rec[:4])
                if a.confirm:
                    now = datetime.datetime.now().replace(microsecond=0)
                    cur.execute('INSERT INTO `%s`.managed_object (kind, yaml_key, guac_id, guac_name, salt, base_json, created_at, updated_at) '
                                'VALUES (%%s, %%s, %%s, %%s, %%s, %%s, %%s, %%s)' % sdb,
                                (rec[0], rec[1], rec[2], rec[3], rec[4], json.dumps(rec[5], sort_keys=True), now, now))
                    conn.commit()
                else:
                    conn.rollback()
                return 0
            lock = a.cmd == 'apply'
            st = load_state(cur, sdb, lock)
            snap = load_snapshot(cur, lock)
            plan = build_plan(cfg, snap, st, a.overwrite, a.allow_empty, a.allow_mass_delete)
            if a.json:
                print(json.dumps({'plan_id': plan.plan_id, 'counts': plan.counts(), 'notes': plan.notes,
                                  'warnings': plan.warnings, 'actions': json.loads(plan.canonical())}, indent=2, sort_keys=True))
            elif a.cmd == 'plan':
                render(plan, verbose=a.verbose)
            n_conf = plan.counts().get('conflict', 0)
            if a.cmd == 'plan':
                conn.rollback()
                if a.strict and n_conf:
                    return 3
                return 2 if any(plan.counts().get(k) for k in ('create', 'update', 'delete', 'forget')) else 0
            if a.confirm != plan.plan_id:
                conn.rollback()
                raise SyncError('the plan changed since you reviewed it (now %s). Nothing was written; run plan again.' % plan.plan_id)
            if a.strict and n_conf:
                conn.rollback()
                raise SyncError('%d conflict(s) and --strict; nothing was written' % n_conf)
            try:
                apply_plan(cur, sdb, plan, cfg, st, snap)
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            c = plan.counts()
            print('Applied plan %s: %d created, %d updated, %d deleted, %d conflicts skipped.' % (
                plan.plan_id, c.get('create', 0), c.get('update', 0), c.get('delete', 0), n_conf))
            return 0
        finally:
            conn.close()
    except SyncError as e:
        print('error: %s' % e, file=sys.stderr)
        return 1
    except Exception as e:  # database errors: never echo parameters (they may hold secrets)
        if os.environ.get('GUAC_SYNC_DEBUG'):
            raise
        name = type(e).__name__
        code = e.args[0] if getattr(e, 'args', None) and isinstance(e.args[0], int) else ''
        print('error: %s %s; transaction rolled back, nothing was written' % (name, code), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
