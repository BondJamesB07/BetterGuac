package com.betterguac.profile;

import javax.ws.rs.Path;
import org.apache.guacamole.net.auth.UserContext;

/**
 * Root of BetterGuac's REST endpoints, served under
 * api/session/ext/{database provider}/ (for example api/session/ext/mysql/).
 */
public class ExtensionResource {

    private final UserContext userContext;

    public ExtensionResource(UserContext userContext) {
        this.userContext = userContext;
    }

    /** POST connectivity: admin-only reachability test. */
    @Path("connectivity")
    public ConnectivityResource connectivity() {
        return new ConnectivityResource(userContext);
    }

    /** POST sshkey/check: admin-only check of an SSH key file path. */
    @Path("sshkey")
    public SshKeyResource sshkey() {
        return new SshKeyResource(userContext);
    }

    /** GET sessions, DELETE sessions/{id}: the caller's own open sessions. */
    @Path("sessions")
    public SessionsResource sessions() {
        return new SessionsResource(userContext);
    }

    /** Admin-only activity log: audit/events, audit/export, audit/settings, audit/purge. */
    @Path("audit")
    public AuditResource audit() {
        return new AuditResource(userContext);
    }

    /** POST mfa/reset (own account) and mfa/reset-user (admins). */
    @Path("mfa")
    public MfaResource mfa() {
        return new MfaResource(userContext);
    }

}
