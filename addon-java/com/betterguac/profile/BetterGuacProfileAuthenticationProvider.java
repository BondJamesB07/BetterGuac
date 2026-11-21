package com.betterguac.profile;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.net.auth.AbstractAuthenticationProvider;
import org.apache.guacamole.net.auth.AuthenticatedUser;
import org.apache.guacamole.net.auth.Credentials;
import org.apache.guacamole.net.auth.UserContext;

/**
 * BetterGuac profile support. Authenticates nobody and stores nothing itself.
 * It only decorates the database (JDBC) user context so that:
 *  - users can save their own first name, last name, nickname and picture
 *    through Guacamole's native "preference attributes" path (self-only),
 *  - admins see and edit the same fields on the user editor,
 *  - those values are validated server-side, and
 *  - accounts created through the web UI / REST API use an email address
 *    as their sign-in name.
 */
public class BetterGuacProfileAuthenticationProvider extends AbstractAuthenticationProvider {

    private static final Set<String> DATABASE_PROVIDERS = new HashSet<>(
            Arrays.asList("mysql", "postgresql", "sqlserver"));

    @Override
    public String getIdentifier() {
        return "betterguac-profile";
    }

    private UserContext wrap(UserContext context) {
        if (context == null || context.getAuthenticationProvider() == null)
            return context;
        if (!DATABASE_PROVIDERS.contains(context.getAuthenticationProvider().getIdentifier()))
            return context;
        return new ProfileUserContext(context);
    }

    /**
     * Authenticates nobody (returns null so the database extension decides),
     * but first lets a sign-in that already changed an expired password
     * continue to the two-factor step. See PasswordChangeRetry.
     */
    @Override
    public AuthenticatedUser authenticateUser(Credentials credentials)
            throws GuacamoleException {
        if (credentials != null)
            PasswordChangeRetry.apply(credentials);
        return null;
    }

    @Override
    public UserContext decorate(UserContext context,
            AuthenticatedUser authenticatedUser, Credentials credentials)
            throws GuacamoleException {
        return wrap(context);
    }

    @Override
    public UserContext redecorate(UserContext decorated, UserContext context,
            AuthenticatedUser authenticatedUser, Credentials credentials)
            throws GuacamoleException {
        return wrap(context);
    }

}
