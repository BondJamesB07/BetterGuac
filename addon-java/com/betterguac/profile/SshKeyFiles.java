package com.betterguac.profile;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.PosixFilePermission;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import org.apache.guacamole.GuacamoleClientException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleServerException;
import org.apache.guacamole.environment.Environment;
import org.apache.guacamole.environment.LocalEnvironment;
import org.apache.guacamole.net.GuacamoleTunnel;
import org.apache.guacamole.net.auth.Connection;
import org.apache.guacamole.net.auth.DelegatingConnection;
import org.apache.guacamole.net.auth.DelegatingDirectory;
import org.apache.guacamole.net.auth.Directory;
import org.apache.guacamole.properties.StringGuacamoleProperty;
import org.apache.guacamole.protocol.GuacamoleClientInformation;
import org.apache.guacamole.protocol.GuacamoleConfiguration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * SSH private keys as file paths.
 *
 * Stock Guacamole (and guacd) only take the key text itself in the
 * "private-key" parameter, so it ends up in the database. BetterGuac stores
 * the path in a "private-key-file" parameter instead, and "private-key" only
 * holds the placeholder ${BETTERGUAC_SSH_PRIVATE_KEY}. When someone opens the
 * server, this class reads the file (as Tomcat, on the BetterGuac server) and
 * hands the text to guacd through Guacamole's own parameter-token mechanism.
 * The key text never goes into the database, the REST API or the browser.
 *
 * Key files must sit under the key folder (property betterguac-ssh-key-dir,
 * default /etc/betterguac/keys), be readable by Tomcat and not readable by
 * everyone. Pasted key text is refused.
 */
final class SshKeyFiles {

    private static final Logger logger = LoggerFactory.getLogger(SshKeyFiles.class);

    static final String PARAM_FILE = "private-key-file";
    static final String PARAM_KEY = "private-key";
    static final String TOKEN = "BETTERGUAC_SSH_PRIVATE_KEY";
    static final String PLACEHOLDER = "${" + TOKEN + "}";
    static final String DEFAULT_DIR = "/etc/betterguac/keys";
    static final long MAX_BYTES = 64 * 1024;

    private static final Pattern BEGIN = Pattern.compile("-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----");

    private SshKeyFiles() { }

    /** What a check found: the clean path plus a short description of the key. */
    static final class Checked {
        final Path path;
        final String format;
        final boolean encrypted;
        Checked(Path path, String format, boolean encrypted) {
            this.path = path;
            this.format = format;
            this.encrypted = encrypted;
        }
    }

    static Path keyDir() {
        String dir = DEFAULT_DIR;
        try {
            Environment env = LocalEnvironment.getInstance();
            dir = env.getProperty(new StringGuacamoleProperty() {
                @Override public String getName() { return "betterguac-ssh-key-dir"; }
            }, DEFAULT_DIR);
        }
        catch (GuacamoleException e) {
            logger.warn("Couldn't read betterguac-ssh-key-dir, using {}: {}", DEFAULT_DIR, e.getMessage());
        }
        return Paths.get(dir);
    }

    /**
     * Checks a key path the way it will be used when someone connects.
     * Throws GuacamoleClientException with a message an admin can act on.
     */
    static Checked check(String raw) throws GuacamoleClientException {
        String value = raw == null ? "" : raw.trim();
        Path dir = keyDir();
        if (value.isEmpty())
            throw new GuacamoleClientException("Enter the path to the private key file.");
        if (value.contains("-----BEGIN") || value.indexOf('\n') >= 0)
            throw new GuacamoleClientException("That looks like the key itself. Save the key as a file in "
                    + dir + " on the BetterGuac server and enter its path, like " + dir + "/web-01.");
        if (value.startsWith("~"))
            throw new GuacamoleClientException("Use the full path, like " + dir + "/web-01. A path starting with ~ isn't supported.");
        Path path = Paths.get(value);
        if (!path.isAbsolute())
            throw new GuacamoleClientException("Use the full path starting with /, like " + dir + "/web-01.");
        path = path.normalize();

        Path realDir;
        try {
            realDir = dir.toRealPath();
        }
        catch (IOException e) {
            throw new GuacamoleClientException("The key folder " + dir + " doesn't exist on the BetterGuac server, "
                    + "or Tomcat can't open it.");
        }
        if (!path.startsWith(dir) && !path.startsWith(realDir))
            throw new GuacamoleClientException("Key files must be in " + dir + " on the BetterGuac server. "
                    + path + " isn't.");

        Path real;
        try {
            real = path.toRealPath();
        }
        catch (NoSuchFileException e) {
            throw new GuacamoleClientException("There's no file at " + path + " on the BetterGuac server.");
        }
        catch (IOException e) {
            throw new GuacamoleClientException("Tomcat can't open " + path + ". Check the folder permissions.");
        }
        if (!real.startsWith(realDir))
            throw new GuacamoleClientException(path + " links to a file outside " + dir + ".");
        if (!Files.isRegularFile(real))
            throw new GuacamoleClientException(path + " isn't a file.");
        if (!Files.isReadable(real))
            throw new GuacamoleClientException("Tomcat can't read " + path
                    + ". Make it owned by root, group tomcat, mode 640: "
                    + "sudo chown root:tomcat " + path + " && sudo chmod 640 " + path);
        try {
            Set<PosixFilePermission> perms = Files.getPosixFilePermissions(real, LinkOption.NOFOLLOW_LINKS);
            if (perms.contains(PosixFilePermission.OTHERS_READ) || perms.contains(PosixFilePermission.OTHERS_WRITE)
                    || perms.contains(PosixFilePermission.GROUP_WRITE))
                throw new GuacamoleClientException(path + " can be read or changed by other accounts on the server. "
                        + "Fix it with: sudo chown root:tomcat " + path + " && sudo chmod 640 " + path);
        }
        catch (UnsupportedOperationException | IOException e) {
            // Not a POSIX file system: nothing to check
        }

        String text;
        try {
            if (Files.size(real) > MAX_BYTES)
                throw new GuacamoleClientException(path + " is too big to be an SSH private key.");
            text = new String(Files.readAllBytes(real), StandardCharsets.US_ASCII);
        }
        catch (IOException e) {
            throw new GuacamoleClientException("Tomcat couldn't read " + path + ".");
        }
        java.util.regex.Matcher m = BEGIN.matcher(text);
        if (!m.find())
            throw new GuacamoleClientException(path + " isn't a private key. It should start with -----BEGIN ... PRIVATE KEY-----. "
                    + "(A .pub file is the public half.)");
        String kind = m.group(1).trim();
        boolean encrypted = text.contains("ENCRYPTED") || text.contains("Proc-Type: 4,ENCRYPTED");
        String format;
        if (kind.equals("OPENSSH"))
            format = "OpenSSH format";
        else if (kind.isEmpty())
            format = "PKCS#8 (PEM)";
        else
            format = kind + " (PEM)";
        return new Checked(real, format, encrypted);
    }

    /** The key text, for connect time. */
    static String read(String raw) throws GuacamoleException {
        Checked c;
        try {
            c = check(raw);
        }
        catch (GuacamoleClientException e) {
            throw new GuacamoleServerException("SSH key file problem: " + e.getMessage());
        }
        try {
            return new String(Files.readAllBytes(c.path), StandardCharsets.US_ASCII);
        }
        catch (IOException e) {
            throw new GuacamoleServerException("Couldn't read the SSH key file " + c.path + ".", e);
        }
    }

    /**
     * Puts a configuration about to be saved into the key-path form:
     * private-key-file holds the checked path and private-key the placeholder.
     * Pasted key text is refused.
     */
    static GuacamoleConfiguration normalize(GuacamoleConfiguration config) throws GuacamoleException {
        if (config == null)
            return null;
        GuacamoleConfiguration out = new GuacamoleConfiguration(config);
        String file = out.getParameter(PARAM_FILE);
        String key = out.getParameter(PARAM_KEY);
        if (file != null && !file.trim().isEmpty()) {
            check(file);
            out.setParameter(PARAM_FILE, Paths.get(file.trim()).normalize().toString());
            out.setParameter(PARAM_KEY, PLACEHOLDER);
        }
        else {
            out.unsetParameter(PARAM_FILE);
            if (key != null && !key.isEmpty() && !PLACEHOLDER.equals(key))
                throw new GuacamoleClientException("SSH keys are entered as a file path now, not pasted. Save the key in "
                        + keyDir() + " on the BetterGuac server and put its path in Private key file.");
            out.unsetParameter(PARAM_KEY);
        }
        return out;
    }

    /** The key path saved for one server, straight from the database (any user may connect). */
    static String storedPath(String connectionId) throws GuacamoleException {
        int id;
        try {
            id = Integer.parseInt(connectionId);
        }
        catch (NumberFormatException e) {
            return null;
        }
        try (java.sql.Connection db = MfaResource.connectDatabase();
             PreparedStatement st = db.prepareStatement(
                "SELECT parameter_value FROM guacamole_connection_parameter "
              + "WHERE connection_id = ? AND parameter_name = ?")) {
            st.setInt(1, id);
            st.setString(2, PARAM_FILE);
            try (ResultSet rs = st.executeQuery()) {
                return rs.next() ? rs.getString(1) : null;
            }
        }
        catch (SQLException e) {
            throw new GuacamoleServerException("Couldn't look up the server's SSH key file.", e);
        }
    }

    /** A server that, when opened, supplies its key file's text to guacd. */
    static final class KeyFileConnection extends DelegatingConnection {

        KeyFileConnection(Connection connection) {
            super(connection);
        }

        Connection unwrap() {
            return getDelegateConnection();
        }

        @Override
        public GuacamoleTunnel connect(GuacamoleClientInformation info, Map<String, String> tokens)
                throws GuacamoleException {
            String path = storedPath(getIdentifier());
            if (path == null || path.trim().isEmpty())
                return super.connect(info, tokens);
            Map<String, String> withKey = new HashMap<>(tokens == null ? Map.of() : tokens);
            try {
                withKey.put(TOKEN, read(path));
            }
            catch (GuacamoleException e) {
                logger.warn("Server \"{}\" ({}): {}", getName(), getIdentifier(), e.getMessage());
                throw e;
            }
            return super.connect(info, withKey);
        }

    }

    static Connection unwrap(Connection c) {
        return c instanceof KeyFileConnection ? ((KeyFileConnection) c).unwrap() : c;
    }

    /** Wraps the connection directory: checks key paths on save, supplies keys on connect. */
    static Directory<Connection> wrap(Directory<Connection> directory) {
        return new DelegatingDirectory<Connection>(directory) {

            @Override
            public Connection get(String identifier) throws GuacamoleException {
                Connection c = super.get(identifier);
                return c == null ? null : new KeyFileConnection(c);
            }

            @Override
            public Collection<Connection> getAll(Collection<String> identifiers) throws GuacamoleException {
                Collection<Connection> all = super.getAll(identifiers);
                java.util.List<Connection> out = new java.util.ArrayList<>(all.size());
                for (Connection c : all)
                    out.add(new KeyFileConnection(c));
                return out;
            }

            @Override
            public void add(Connection object) throws GuacamoleException {
                final GuacamoleConfiguration config = normalize(object.getConfiguration());
                super.add(new DelegatingConnection(object) {
                    @Override public GuacamoleConfiguration getConfiguration() { return config; }
                });
            }

            @Override
            public void update(Connection object) throws GuacamoleException {
                Connection real = unwrap(object);
                real.setConfiguration(normalize(real.getConfiguration()));
                super.update(real);
            }

        };
    }

}
