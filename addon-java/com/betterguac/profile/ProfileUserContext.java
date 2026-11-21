package com.betterguac.profile;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import org.apache.guacamole.GuacamoleClientException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.form.Field;
import org.apache.guacamole.form.Form;
import org.apache.guacamole.form.TextField;
import org.apache.guacamole.net.auth.DelegatingDirectory;
import org.apache.guacamole.net.auth.DelegatingUserContext;
import org.apache.guacamole.net.auth.Directory;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserContext;

public class ProfileUserContext extends DelegatingUserContext {

    public static final String FIRST_NAME = "bg-first-name";
    public static final String LAST_NAME = "bg-last-name";
    public static final String NICKNAME = "bg-nickname";
    public static final String AVATAR = "bg-avatar";
    public static final String EMAIL = "guac-email-address";

    /** guacamole_user_attribute.attribute_value is VARCHAR(4096). */
    public static final int MAX_AVATAR_LENGTH = 4096;
    public static final int MAX_NAME_LENGTH = 64;

    private static final Pattern AVATAR_PATTERN = Pattern.compile(
            "^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$");

    private static final Pattern EMAIL_PATTERN = Pattern.compile(
            "^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$");

    private static final Pattern CONTROL_CHARS = Pattern.compile("[\\p{Cntrl}]");

    public static final Form PROFILE_FORM = new Form("betterguac-profile",
            Arrays.<Field>asList(
                new TextField(FIRST_NAME),
                new TextField(LAST_NAME),
                new TextField(NICKNAME)
            ));

    public static final Form AVATAR_FORM = new Form("betterguac-avatar",
            Collections.<Field>singletonList(new TextField(AVATAR)));

    public ProfileUserContext(UserContext userContext) {
        super(userContext);
    }

    private static Collection<Form> withProfile(Collection<Form> forms) {
        List<Form> all = new ArrayList<>(forms);
        all.add(PROFILE_FORM);
        all.add(AVATAR_FORM);
        return Collections.unmodifiableList(all);
    }

    @Override
    public Collection<Form> getUserAttributes() {
        return withProfile(super.getUserAttributes());
    }

    @Override
    public Collection<Form> getUserPreferenceAttributes() {
        return withProfile(super.getUserPreferenceAttributes());
    }

    static void validateName(Map<String, String> attributes, String name, String label)
            throws GuacamoleException {
        String value = attributes.get(name);
        if (value == null)
            return;
        if (value.length() > MAX_NAME_LENGTH)
            throw new GuacamoleClientException(label + " can be at most "
                    + MAX_NAME_LENGTH + " characters.");
        if (CONTROL_CHARS.matcher(value).find())
            throw new GuacamoleClientException(label + " contains characters that aren't allowed.");
    }

    static void validateProfile(Map<String, String> attributes) throws GuacamoleException {
        if (attributes == null)
            return;
        validateName(attributes, FIRST_NAME, "First name");
        validateName(attributes, LAST_NAME, "Last name");
        validateName(attributes, NICKNAME, "Nickname");
        String avatar = attributes.get(AVATAR);
        if (avatar != null && !avatar.isEmpty()) {
            if (avatar.length() > MAX_AVATAR_LENGTH)
                throw new GuacamoleClientException("The profile picture is too large. "
                        + "Please choose a smaller picture.");
            if (!AVATAR_PATTERN.matcher(avatar).matches())
                throw new GuacamoleClientException("The profile picture must be a PNG, JPEG or WebP image.");
        }
    }

    static boolean isEmail(String value) {
        return value != null && value.length() <= 128 && EMAIL_PATTERN.matcher(value).matches();
    }

    /**
     * Admin-only server reachability check. Served at
     * api/session/ext/{provider}/connectivity, where {provider} is the
     * database provider this context decorates (for example "mysql").
     */
    @Override
    public Object getResource() throws GuacamoleException {
        return new ExtensionResource(this);
    }

    /**
     * Server lookups for people who aren't admins are checked against their
     * groups as they are now, so taking someone out of a group takes effect
     * at once instead of at their next sign-in. See LiveServerAccess.
     */
    @Override
    public Directory<org.apache.guacamole.net.auth.Connection> getConnectionDirectory()
            throws GuacamoleException {
        Directory<org.apache.guacamole.net.auth.Connection> directory = super.getConnectionDirectory();
        if (!"mysql".equals(getAuthenticationProvider().getIdentifier()))
            return directory;
        directory = SshKeyFiles.wrap(directory);
        User self = self();
        if (self == null || self.getIdentifier() == null || LiveServerAccess.isAdmin(self))
            return directory;
        return LiveServerAccess.wrap(directory, self.getIdentifier());
    }

    @Override
    public Directory<User> getUserDirectory() throws GuacamoleException {
        return new DelegatingDirectory<User>(super.getUserDirectory()) {

            @Override
            public void add(User user) throws GuacamoleException {

                // New accounts sign in with an email address
                String identifier = user.getIdentifier();
                String email = identifier == null ? null : identifier.trim().toLowerCase(Locale.ROOT);
                if (!isEmail(email))
                    throw new GuacamoleClientException("Please enter a valid email address. "
                            + "New accounts sign in with their email address.");
                user.setIdentifier(email);

                Map<String, String> attributes = user.getAttributes();
                validateProfile(attributes);

                // Keep the stock email attribute in step with the sign-in email
                if (attributes != null) {
                    attributes.put(EMAIL, email);
                    user.setAttributes(attributes);
                }

                super.add(user);
            }

            @Override
            public void update(User user) throws GuacamoleException {
                validateProfile(user.getAttributes());
                guardTotpKey(user);
                super.update(user);
            }

            /**
             * Stock Guacamole lets an admin clear another person's TOTP key by
             * unticking "key generated" / "key confirmed" on the user editor.
             * That reset leaves the account open to anyone who knows the old
             * password until the owner signs in again. BetterGuac resets
             * two-factor only through mfa/reset-user (one-time password, must be
             * changed at sign-in) and mfa/reset (password + current code), so a
             * plain user update may not remove or unconfirm an existing key.
             */
            private static final String TOTP_GENERATED = "guac-totp-key-generated";

            private void guardTotpKey(User user) throws GuacamoleException {
                Map<String, String> incoming = user.getAttributes();
                if (incoming == null || user.getIdentifier() == null)
                    return;
                // Read the stored key straight from the database: the TOTP
                // extension hides the secret from the user objects other layers see.
                String secret = null;
                boolean confirmed = false;
                try (java.sql.Connection db = MfaResource.connectDatabase()) {
                    Long userId = MfaResource.userId(db, user.getIdentifier());
                    if (userId == null)
                        return;
                    try (java.sql.PreparedStatement st = db.prepareStatement(
                            "SELECT attribute_name, attribute_value FROM guacamole_user_attribute "
                          + "WHERE user_id = ? AND attribute_name IN (?, ?)")) {
                        st.setLong(1, userId);
                        st.setString(2, MfaResource.TOTP_SECRET);
                        st.setString(3, MfaResource.TOTP_CONFIRMED);
                        try (java.sql.ResultSet rs = st.executeQuery()) {
                            while (rs.next()) {
                                if (MfaResource.TOTP_SECRET.equals(rs.getString(1)))
                                    secret = rs.getString(2);
                                else
                                    confirmed = "true".equals(rs.getString(2));
                            }
                        }
                    }
                }
                catch (java.sql.SQLException e) {
                    throw new org.apache.guacamole.GuacamoleServerException("Couldn't check two-factor state.", e);
                }
                if (secret == null || secret.isEmpty())
                    return;
                // The object reaching this layer is the database extension's own
                // user, which carries every stored attribute. The TOTP extension
                // above turns an unticked "key generated" box into null values,
                // which drop out of the map, so a missing key means "removed".
                String newSecret = incoming.get(MfaResource.TOTP_SECRET);
                boolean secretChanged = !secret.equals(newSecret);
                boolean unconfirmed = confirmed
                        && !"true".equals(incoming.get(MfaResource.TOTP_CONFIRMED));
                boolean ungenerated = incoming.containsKey(TOTP_GENERATED)
                        && !"true".equals(incoming.get(TOTP_GENERATED));
                if (secretChanged || unconfirmed || ungenerated)
                    throw new GuacamoleClientException("Two-factor sign-in can't be reset from these "
                            + "fields. Use \"Reset two-factor sign-in\" on this person's page, "
                            + "or \"Set up a new authenticator\" on My profile.");
            }

        };
    }

}
