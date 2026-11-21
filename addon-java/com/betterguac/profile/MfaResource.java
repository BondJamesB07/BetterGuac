package com.betterguac.profile;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.Driver;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ConcurrentHashMap;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import javax.ws.rs.Consumes;
import javax.ws.rs.POST;
import javax.ws.rs.Path;
import javax.ws.rs.Produces;
import javax.ws.rs.core.MediaType;
import org.apache.guacamole.GuacamoleClientException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleSecurityException;
import org.apache.guacamole.GuacamoleServerException;
import org.apache.guacamole.environment.Environment;
import org.apache.guacamole.environment.LocalEnvironment;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserContext;
import org.apache.guacamole.net.auth.permission.SystemPermission;
import org.apache.guacamole.properties.StringGuacamoleProperty;

/**
 * Two-factor (TOTP) reset.
 *
 * POST mfa/reset       { "password": "...", "code": "123456" }
 *   Signed-in user, own account. The current password and a current code
 *   from the authenticator app are both checked on the server. The TOTP key
 *   is then removed, so the next sign-in (password first) shows a new QR
 *   code that must be confirmed with a code before the session opens.
 *
 * POST mfa/reset-user  { "username": "..." }
 *   Admins only, for another account (a lost phone). Same removal, and the
 *   account gets a one-time password (returned once, to the admin) that must
 *   be changed at the next sign-in, before the new QR code is shown.
 *
 * Failed self-service attempts are limited to 5 per 15 minutes per account.
 */
public class MfaResource {

    public static final String TOTP_SECRET = "guac-totp-key-secret";
    public static final String TOTP_CONFIRMED = "guac-totp-key-confirmed";

    private static final int MAX_FAILURES = 5;
    private static final long LOCK_MS = 15 * 60 * 1000L;
    private static final Map<String, long[]> FAILURES = new ConcurrentHashMap<>();

    private static final StringGuacamoleProperty prop(final String name) {
        return new StringGuacamoleProperty() {
            @Override
            public String getName() { return name; }
        };
    }

    private final UserContext userContext;

    public MfaResource(UserContext userContext) {
        this.userContext = userContext;
    }

    public static class SelfReset {
        public String password;
        public String code;
    }

    public static class UserReset {
        public String username;
    }

    public static class Result {
        public boolean reset;
        public String message;
        public String temporaryPassword;
        Result(boolean reset, String message) { this.reset = reset; this.message = message; }
    }

    /* ---------------- endpoints ---------------- */

    @POST
    @Path("reset")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Result resetSelf(SelfReset body) throws GuacamoleException {

        User self = userContext.self();
        if (self == null || self.getIdentifier() == null)
            throw new GuacamoleSecurityException("Not signed in.");
        String username = self.getIdentifier();
        String key = userContext.getAuthenticationProvider().getIdentifier() + "/" + username.toLowerCase(Locale.ROOT);

        long[] f = FAILURES.get(key);
        long now = System.currentTimeMillis();
        if (f != null && f[0] >= MAX_FAILURES && now - f[1] < LOCK_MS)
            throw new GuacamoleSecurityException("Too many wrong attempts. Try again in 15 minutes.");

        String password = body == null || body.password == null ? "" : body.password;
        String code = body == null || body.code == null ? "" : body.code.replaceAll("\\s", "");
        if (password.isEmpty() || code.isEmpty())
            throw new GuacamoleClientException("Enter your password and a code from your authenticator app.");

        try (Connection db = connect()) {
            Long userId = userId(db, username);
            if (userId == null)
                throw new GuacamoleSecurityException("This account can't be reset here.");

            boolean passwordOk = checkPassword(db, userId, password);
            String secret = attribute(db, userId, TOTP_SECRET);
            boolean confirmed = "true".equals(attribute(db, userId, TOTP_CONFIRMED));
            boolean codeOk = secret != null && confirmed && checkCode(secret, code);

            if (!passwordOk || !codeOk) {
                long[] nf = (f == null || now - f[1] >= LOCK_MS) ? new long[] { 0, now } : f;
                nf[0]++;
                nf[1] = now;
                FAILURES.put(key, nf);
                if (secret == null || !confirmed)
                    throw new GuacamoleClientException("Two-factor sign-in isn't set up on this account yet.");
                throw new GuacamoleSecurityException("The password or the code is wrong.");
            }

            FAILURES.remove(key);
            removeKey(db, userId);
            return new Result(true, "Two-factor sign-in was reset.");
        }
        catch (SQLException e) {
            throw new GuacamoleServerException("The reset couldn't be saved.", e);
        }
    }

    @POST
    @Path("reset-user")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Result resetUser(UserReset body) throws GuacamoleException {

        User self = userContext.self();
        if (self == null || !self.getEffectivePermissions().getSystemPermissions()
                .hasPermission(SystemPermission.Type.ADMINISTER))
            throw new GuacamoleSecurityException("Only admins can reset another person's two-factor sign-in.");

        String username = body == null || body.username == null ? "" : body.username.trim();
        if (username.isEmpty())
            throw new GuacamoleClientException("No user given.");
        if (username.equals(self.getIdentifier()))
            throw new GuacamoleClientException("Reset your own two-factor sign-in from My profile.");

        // The account must be visible to this admin through the normal API
        if (userContext.getUserDirectory().get(username) == null)
            throw new GuacamoleClientException("No such user.");

        // Closing the reset gap: the old password stops working. The person gets
        // a one-time password from the admin (in person or by phone), must choose
        // a new password at sign-in (Guacamole's own expired-password step, which
        // runs before the TOTP step), and only then sees the new QR code. Someone
        // who only knows the old password can't reach the QR code.
        String temporary = temporaryPassword();
        try (Connection db = connect()) {
            Long userId = userId(db, username);
            if (userId == null)
                throw new GuacamoleClientException("No such user.");
            boolean autoCommit = db.getAutoCommit();
            db.setAutoCommit(false);
            try {
                setOneTimePassword(db, userId, temporary);
                removeKey(db, userId);
                db.commit();
            }
            catch (SQLException e) {
                db.rollback();
                throw e;
            }
            finally {
                db.setAutoCommit(autoCommit);
            }
            Result r = new Result(true, "Two-factor sign-in was reset for " + username + ".");
            r.temporaryPassword = temporary;
            return r;
        }
        catch (SQLException e) {
            throw new GuacamoleServerException("The reset couldn't be saved.", e);
        }
    }

    /* ---------------- database ---------------- */

    private Connection connect() throws GuacamoleException, SQLException {
        String provider = userContext.getAuthenticationProvider().getIdentifier();
        if (!"mysql".equals(provider))
            throw new GuacamoleServerException("Two-factor reset needs the MySQL / MariaDB database.");
        return connectDatabase();
    }

    /** A direct connection to the MySQL / MariaDB database named in guacamole.properties. */
    static Connection connectDatabase() throws GuacamoleException, SQLException {
        Environment env = LocalEnvironment.getInstance();
        String host = env.getProperty(prop("mysql-hostname"), "localhost");
        String port = env.getProperty(prop("mysql-port"), "3306");
        String database = env.getRequiredProperty(prop("mysql-database"));
        String user = env.getRequiredProperty(prop("mysql-username"));
        String password = env.getRequiredProperty(prop("mysql-password"));
        String driverName = env.getProperty(prop("mysql-driver"), "mysql");

        String className, url;
        if ("mariadb".equalsIgnoreCase(driverName)) {
            className = "org.mariadb.jdbc.Driver";
            url = "jdbc:mariadb://" + host + ":" + port + "/" + database;
        }
        else {
            className = "com.mysql.cj.jdbc.Driver";
            url = "jdbc:mysql://" + host + ":" + port + "/" + database;
        }
        Driver driver;
        try {
            driver = (Driver) Class.forName(className, true, MfaResource.class.getClassLoader())
                    .getDeclaredConstructor().newInstance();
        }
        catch (ReflectiveOperationException e) {
            throw new GuacamoleServerException("The database driver isn't available.", e);
        }
        Properties props = new Properties();
        props.setProperty("user", user);
        props.setProperty("password", password);
        Connection c = driver.connect(url, props);
        if (c == null)
            throw new GuacamoleServerException("The database driver refused the connection URL.");
        return c;
    }

    static Long userId(Connection db, String username) throws SQLException {
        try (PreparedStatement st = db.prepareStatement(
                "SELECT u.user_id FROM guacamole_user u JOIN guacamole_entity e ON e.entity_id = u.entity_id "
              + "WHERE e.type = 'USER' AND e.name = ?")) {
            st.setString(1, username);
            try (ResultSet rs = st.executeQuery()) {
                return rs.next() ? rs.getLong(1) : null;
            }
        }
    }

    private static String attribute(Connection db, long userId, String name) throws SQLException {
        try (PreparedStatement st = db.prepareStatement(
                "SELECT attribute_value FROM guacamole_user_attribute WHERE user_id = ? AND attribute_name = ?")) {
            st.setLong(1, userId);
            st.setString(2, name);
            try (ResultSet rs = st.executeQuery()) {
                return rs.next() ? rs.getString(1) : null;
            }
        }
    }

    private static void removeKey(Connection db, long userId) throws SQLException {
        try (PreparedStatement st = db.prepareStatement(
                "DELETE FROM guacamole_user_attribute WHERE user_id = ? AND attribute_name IN (?, ?)")) {
            st.setLong(1, userId);
            st.setString(2, TOTP_SECRET);
            st.setString(3, TOTP_CONFIRMED);
            st.executeUpdate();
        }
    }

    private static final java.security.SecureRandom RANDOM = new java.security.SecureRandom();
    private static final String TEMP_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";

    /** 16 random characters (about 92 bits), shown as four groups of four. */
    static String temporaryPassword() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 16; i++) {
            if (i > 0 && i % 4 == 0)
                sb.append('-');
            sb.append(TEMP_ALPHABET.charAt(RANDOM.nextInt(TEMP_ALPHABET.length())));
        }
        return sb.toString();
    }

    /** Sets a one-time password, stored like guacamole-auth-jdbc does, and marks it expired. */
    private static void setOneTimePassword(Connection db, long userId, String password) throws SQLException {
        byte[] salt = new byte[32];
        RANDOM.nextBytes(salt);
        byte[] hash;
        try {
            hash = MessageDigest.getInstance("SHA-256")
                    .digest((password + hex(salt)).getBytes(StandardCharsets.UTF_8));
        }
        catch (java.security.NoSuchAlgorithmException e) {
            throw new SQLException("SHA-256 isn't available", e);
        }
        try (PreparedStatement st = db.prepareStatement(
                "UPDATE guacamole_user SET password_hash = ?, password_salt = ?, password_date = NOW(), "
              + "expired = 1 WHERE user_id = ?")) {
            st.setBytes(1, hash);
            st.setBytes(2, salt);
            st.setLong(3, userId);
            if (st.executeUpdate() != 1)
                throw new SQLException("user row not updated");
        }
    }

    /** Same scheme as guacamole-auth-jdbc: SHA-256(password + HEX(salt)). */
    static boolean checkPassword(Connection db, long userId, String password) throws SQLException {
        try (PreparedStatement st = db.prepareStatement(
                "SELECT password_hash, password_salt FROM guacamole_user WHERE user_id = ? AND disabled = 0")) {
            st.setLong(1, userId);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next())
                    return false;
                byte[] hash = rs.getBytes(1);
                byte[] salt = rs.getBytes(2);
                if (hash == null)
                    return false;
                StringBuilder input = new StringBuilder(password);
                if (salt != null)
                    input.append(hex(salt));
                byte[] computed = MessageDigest.getInstance("SHA-256")
                        .digest(input.toString().getBytes(StandardCharsets.UTF_8));
                return MessageDigest.isEqual(computed, hash);
            }
            catch (java.security.NoSuchAlgorithmException e) {
                return false;
            }
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes)
            sb.append(String.format("%02X", b));
        return sb.toString();
    }

    /* ---------------- TOTP (RFC 6238), settings as the TOTP extension ---------------- */

    private static boolean checkCode(String base32Secret, String code) throws GuacamoleException {
        Environment env = LocalEnvironment.getInstance();
        String mode = env.getProperty(prop("totp-mode"), "sha1").toLowerCase(Locale.ROOT);
        int digits = Integer.parseInt(env.getProperty(prop("totp-digits"), "6"));
        int period = Integer.parseInt(env.getProperty(prop("totp-period"), "30"));
        if (!code.matches("\\d{" + digits + "}"))
            return false;
        String alg = "sha256".equals(mode) ? "HmacSHA256" : "sha512".equals(mode) ? "HmacSHA512" : "HmacSHA1";
        byte[] key = base32(base32Secret);
        if (key.length == 0)
            return false;
        long counter = System.currentTimeMillis() / 1000L / period;
        boolean match = false;
        for (long c = counter - 1; c <= counter + 1; c++)
            match |= MessageDigest.isEqual(
                    totp(alg, key, c, digits).getBytes(StandardCharsets.US_ASCII),
                    code.getBytes(StandardCharsets.US_ASCII));
        return match;
    }

    private static String totp(String alg, byte[] key, long counter, int digits) {
        try {
            Mac mac = Mac.getInstance(alg);
            mac.init(new SecretKeySpec(key, alg));
            byte[] msg = new byte[8];
            for (int i = 7; i >= 0; i--) {
                msg[i] = (byte) (counter & 0xff);
                counter >>= 8;
            }
            byte[] h = mac.doFinal(msg);
            int o = h[h.length - 1] & 0x0f;
            int bin = ((h[o] & 0x7f) << 24) | ((h[o + 1] & 0xff) << 16) | ((h[o + 2] & 0xff) << 8) | (h[o + 3] & 0xff);
            int mod = 1;
            for (int i = 0; i < digits; i++)
                mod *= 10;
            String s = Integer.toString(bin % mod);
            while (s.length() < digits)
                s = "0" + s;
            return s;
        }
        catch (Exception e) {
            return "";
        }
    }

    private static byte[] base32(String s) {
        String alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        s = s.replaceAll("[\\s=-]", "").toUpperCase(Locale.ROOT);
        byte[] out = new byte[s.length() * 5 / 8];
        int buffer = 0, bits = 0, n = 0;
        for (char ch : s.toCharArray()) {
            int v = alphabet.indexOf(ch);
            if (v < 0)
                return new byte[0];
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8) {
                out[n++] = (byte) ((buffer >> (bits - 8)) & 0xff);
                bits -= 8;
            }
        }
        return out;
    }

}
