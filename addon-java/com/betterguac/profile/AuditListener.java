package com.betterguac.profile;

import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.net.auth.ActiveConnection;
import org.apache.guacamole.net.auth.AuthenticatedUser;
import org.apache.guacamole.net.auth.Connection;
import org.apache.guacamole.net.auth.ConnectionGroup;
import org.apache.guacamole.net.auth.Credentials;
import org.apache.guacamole.net.auth.Directory;
import org.apache.guacamole.net.auth.Identifiable;
import org.apache.guacamole.net.auth.SharingProfile;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.credentials.GuacamoleInsufficientCredentialsException;
import org.apache.guacamole.net.event.ApplicationShutdownEvent;
import org.apache.guacamole.net.event.AuthenticationFailureEvent;
import org.apache.guacamole.net.event.AuthenticationSuccessEvent;
import org.apache.guacamole.net.event.DirectoryEvent;
import org.apache.guacamole.net.event.DirectoryFailureEvent;
import org.apache.guacamole.net.event.DirectorySuccessEvent;
import org.apache.guacamole.net.event.UserSessionInvalidatedEvent;
import org.apache.guacamole.net.event.listener.Listener;

/**
 * Turns Guacamole's own events into activity-log rows: sign-ins, failed
 * sign-ins, two-factor steps, sign-outs, and adds/changes/deletes of users,
 * server groups, servers, folders and open sessions. Registered under
 * "listeners" in guac-manifest.json.
 *
 * Permission and membership changes don't raise Guacamole events; they are
 * logged by AuditedObjects, which wraps the users and groups the REST API
 * edits. Sessions on servers are read from guacamole_connection_history when
 * the log is shown, so they aren't logged here.
 *
 * Nothing in here may stop a sign-in or a save: every path catches its own
 * errors, and the rows are written on a background thread (AuditLog).
 */
public class AuditListener implements Listener {

    /** Request parameter the TOTP extension reads the six-digit code from. */
    private static final String TOTP_PARAMETER = "guac-totp";

    @Override
    public void handleEvent(Object event) throws GuacamoleException {
        try {
            if (event instanceof AuthenticationSuccessEvent)
                success((AuthenticationSuccessEvent) event);
            else if (event instanceof AuthenticationFailureEvent)
                failure((AuthenticationFailureEvent) event);
            else if (event instanceof UserSessionInvalidatedEvent)
                signedOut((UserSessionInvalidatedEvent) event);
            else if (event instanceof DirectorySuccessEvent)
                directory((DirectoryEvent<?>) event, null);
            else if (event instanceof DirectoryFailureEvent)
                directory((DirectoryEvent<?>) event, ((DirectoryFailureEvent<?>) event).getFailure());
            else if (event instanceof ApplicationShutdownEvent)
                AuditLog.flush(3000);
        }
        catch (RuntimeException e) {
            org.slf4j.LoggerFactory.getLogger(AuditListener.class)
                    .warn("Activity log: couldn't record an event: {}", e.getMessage());
        }
    }

    static String remoteOf(Credentials c) {
        if (c == null)
            return null;
        String addr = c.getRemoteAddress();
        return addr != null ? addr : c.getRemoteHostname();
    }

    static String remoteOf(AuthenticatedUser u) {
        return u == null ? null : remoteOf(u.getCredentials());
    }

    static String nameOf(AuthenticatedUser u) {
        if (u == null)
            return null;
        String id = u.getIdentifier();
        return id == null || id.isEmpty() || AuthenticatedUser.ANONYMOUS_IDENTIFIER.equals(id) ? null : id;
    }

    private static boolean hasCode(Credentials c) {
        String code = c == null ? null : c.getParameter(TOTP_PARAMETER);
        return code != null && !code.trim().isEmpty();
    }

    private void success(AuthenticationSuccessEvent e) {
        if (e.isExistingSession())
            return;
        String who = nameOf(e.getAuthenticatedUser());
        if (who == null)
            return;
        Credentials c = e.getCredentials();
        AuditLog.event("auth", "auth.login")
                .actor(who)
                .remote(remoteOf(c))
                .target("user", who, who)
                .detail(hasCode(c) ? "Signed in with password and two-factor code" : "Signed in")
                .record();
    }

    private void failure(AuthenticationFailureEvent e) {
        Credentials c = e.getCredentials();
        if (c == null)
            return;
        String user = c.getUsername();
        boolean code = hasCode(c);
        // The sign-in page asks for a token with no credentials on every load,
        // and expired tokens fail the same way: not worth a row.
        if ((user == null || user.trim().isEmpty()) && !code)
            return;
        Throwable why = e.getFailure();
        String message = why == null || why.getMessage() == null ? "" : why.getMessage();

        AuditLog.Event row;
        if (why instanceof GuacamoleInsufficientCredentialsException) {
            // Not a failure as such: Guacamole asks for one more thing
            if (message.contains("PASSWORD_EXPIRED") || message.contains("PASSWORD_CHANGE"))
                row = AuditLog.event("auth", "auth.password_change_required").outcome("info")
                        .detail("Password accepted; a new password is required before signing in");
            else if (code)
                row = AuditLog.event("mfa", "mfa.failed").outcome("failure")
                        .detail("Two-factor code was rejected");
            else if (message.toUpperCase().contains("ENROLL"))
                row = AuditLog.event("mfa", "mfa.enroll_prompt").outcome("info")
                        .detail("Password accepted; asked to set up two-factor sign-in");
            else
                row = AuditLog.event("mfa", "mfa.challenge").outcome("info")
                        .detail("Password accepted; asked for a two-factor code");
        }
        else if (code) {
            // The password was accepted on the step before; the code was wrong
            row = AuditLog.event("mfa", "mfa.failed").outcome("failure")
                    .detail("Two-factor code was rejected");
        }
        else {
            row = AuditLog.event("auth", "auth.failed").outcome("failure")
                    .detail("Wrong username or password, or the account is disabled");
        }
        String name = user == null ? null : user.trim();
        row.actor(name).remote(remoteOf(c)).target("user", name, name).record();
    }

    private void signedOut(UserSessionInvalidatedEvent e) {
        String who = nameOf(e.getAuthenticatedUser());
        if (who == null)
            return;
        AuditLog.event("auth", "auth.logout")
                .outcome("info")
                .actor(who)
                .remote(remoteOf(e.getAuthenticatedUser()))
                .target("user", who, who)
                .detail("Signed out, or the session timed out")
                .record();
    }

    private static String verb(DirectoryEvent.Operation op) {
        switch (op) {
            case ADD:    return "created";
            case UPDATE: return "updated";
            case REMOVE: return "deleted";
            default:     return null;
        }
    }

    private void directory(DirectoryEvent<?> e, Throwable failure) {
        String verb = verb(e.getOperation());
        if (verb == null)
            return;
        Directory.Type type = e.getDirectoryType();
        Identifiable object = e.getObject();
        String id = e.getObjectIdentifier();
        String actor = nameOf(e.getAuthenticatedUser());

        String category, targetType, name = null;
        StringBuilder detail = new StringBuilder();
        switch (type) {
            case USER:
                category = "user"; targetType = "user"; name = id;
                if (object instanceof User && e.getOperation() == DirectoryEvent.Operation.UPDATE) {
                    User u = (User) object;
                    if (id != null && id.equals(actor))
                        detail.append("Own profile. ");
                    if (u.getPassword() != null)
                        detail.append("Password changed. ");
                    if (u.isDisabled())
                        detail.append("Account is disabled. ");
                }
                break;
            case USER_GROUP:
                category = "group"; targetType = "group"; name = id;
                break;
            case CONNECTION:
                category = "server"; targetType = "server";
                if (object instanceof Connection) {
                    Connection c = (Connection) object;
                    name = c.getName();
                    if (c.getConfiguration() != null && c.getConfiguration().getProtocol() != null)
                        detail.append(c.getConfiguration().getProtocol().toUpperCase()).append(". ");
                }
                break;
            case CONNECTION_GROUP:
                category = "server"; targetType = "folder";
                if (object instanceof ConnectionGroup)
                    name = ((ConnectionGroup) object).getName();
                break;
            case SHARING_PROFILE:
                category = "server"; targetType = "sharing";
                if (object instanceof SharingProfile)
                    name = ((SharingProfile) object).getName();
                break;
            case ACTIVE_CONNECTION:
                if (e.getOperation() != DirectoryEvent.Operation.REMOVE)
                    return;
                category = "session"; targetType = "session";
                if (object instanceof ActiveConnection) {
                    ActiveConnection a = (ActiveConnection) object;
                    detail.append("Session of ").append(a.getUsername())
                          .append(" on server id ").append(a.getConnectionIdentifier()).append(" was ended. ");
                }
                AuditLog.Event k = AuditLog.event(category, "session.killed")
                        .actor(actor).remote(remoteOf(e.getAuthenticatedUser()))
                        .target(targetType, id, null)
                        .detail(detail.toString().trim());
                if (failure != null)
                    k.outcome("failure").detail("Couldn't end the session: " + failure.getMessage());
                k.record();
                return;
            default:
                return;
        }

        AuditLog.Event row = AuditLog.event(category, targetType + "." + verb)
                .actor(actor)
                .remote(remoteOf(e.getAuthenticatedUser()))
                .target(targetType, id, name);
        if (failure != null) {
            row.outcome("failure");
            detail.append("Failed: ").append(failure.getMessage() == null ? failure.getClass().getSimpleName() : failure.getMessage());
        }
        String d = detail.toString().trim();
        row.detail(d.isEmpty() ? null : d).record();
    }

}
