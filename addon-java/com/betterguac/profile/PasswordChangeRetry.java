package com.betterguac.profile;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.environment.Environment;
import org.apache.guacamole.environment.LocalEnvironment;
import org.apache.guacamole.net.auth.Credentials;
import org.apache.guacamole.properties.StringGuacamoleProperty;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Makes Guacamole's "choose a new password" step work together with the TOTP
 * step that follows it.
 *
 * After an admin two-factor reset the account has a one-time password that
 * must be changed at sign-in. The database extension changes the password on
 * the first submit, then the TOTP extension asks for a code. The login page
 * resubmits everything it already had (the one-time password and the new
 * password fields) together with the code, and the one-time password is no
 * longer valid, so the sign-in failed with "Invalid login".
 *
 * Before the database extension checks the password, this swaps in the new
 * password, but only when: the new password and its confirmation match, the
 * submitted password does NOT match the stored one, the new password DOES
 * match the stored one, and the account is not marked expired. In other words
 * the request already proves knowledge of the current password, so nothing is
 * accepted that wouldn't be accepted anyway, and the TOTP step still runs.
 */
final class PasswordChangeRetry {

    private static final Logger logger = LoggerFactory.getLogger(PasswordChangeRetry.class);

    private PasswordChangeRetry() {}

    static void apply(Credentials credentials) {
        try {
            String username = credentials.getUsername();
            String password = credentials.getPassword();
            String newPassword = credentials.getParameter("new-password");
            String confirm = credentials.getParameter("confirm-new-password");
            if (username == null || username.isEmpty() || password == null
                    || newPassword == null || newPassword.isEmpty() || !newPassword.equals(confirm)
                    || newPassword.equals(password))
                return;

            Environment env = LocalEnvironment.getInstance();
            if (env.getProperty(new StringGuacamoleProperty() {
                    @Override public String getName() { return "mysql-database"; }
                }) == null)
                return;

            try (Connection db = MfaResource.connectDatabase()) {
                Long userId = MfaResource.userId(db, username);
                if (userId == null || isExpired(db, userId))
                    return;
                if (MfaResource.checkPassword(db, userId, password))
                    return;
                if (!MfaResource.checkPassword(db, userId, newPassword))
                    return;
                credentials.setPassword(newPassword);
                logger.debug("Password already changed for \"{}\"; continuing sign-in with the new password.", username);
            }
        }
        catch (GuacamoleException | SQLException | RuntimeException e) {
            logger.debug("Password change retry skipped.", e);
        }
    }

    private static boolean isExpired(Connection db, long userId) throws SQLException {
        try (PreparedStatement st = db.prepareStatement(
                "SELECT expired FROM guacamole_user WHERE user_id = ?")) {
            st.setLong(1, userId);
            try (ResultSet rs = st.executeQuery()) {
                return !rs.next() || rs.getBoolean(1);
            }
        }
    }

}
