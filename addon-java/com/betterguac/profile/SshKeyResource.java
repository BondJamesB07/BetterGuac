package com.betterguac.profile;

import javax.ws.rs.Consumes;
import javax.ws.rs.POST;
import javax.ws.rs.Path;
import javax.ws.rs.Produces;
import javax.ws.rs.core.MediaType;
import org.apache.guacamole.GuacamoleClientException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleSecurityException;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserContext;

/**
 * Admin-only check of SSH key file paths, for the Servers page.
 *
 * POST api/session/ext/{provider}/sshkey/check  ["/etc/betterguac/keys/web-01", ...]
 * Answers, for each path: ok, and a message (the problem, or the key's format).
 * Never returns the key itself.
 */
public class SshKeyResource {

    public static final int MAX_PATHS = 200;

    private final UserContext userContext;

    public SshKeyResource(UserContext userContext) {
        this.userContext = userContext;
    }

    public static class Result {
        public String path;
        public boolean ok;
        public String detail;
        public boolean warning;
    }

    public static class Info {
        public String keyDir;
    }

    private void requireAdmin() throws GuacamoleException {
        User self = userContext.self();
        if (!LiveServerAccess.isAdmin(self))
            throw new GuacamoleSecurityException("Only admins can check SSH key files.");
    }

    @POST
    @Path("info")
    @Produces(MediaType.APPLICATION_JSON)
    public Info info() throws GuacamoleException {
        requireAdmin();
        Info i = new Info();
        i.keyDir = SshKeyFiles.keyDir().toString();
        return i;
    }

    @POST
    @Path("check")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public java.util.List<Result> check(java.util.List<String> paths) throws GuacamoleException {
        requireAdmin();
        java.util.List<Result> out = new java.util.ArrayList<>();
        if (paths == null)
            return out;
        if (paths.size() > MAX_PATHS)
            throw new GuacamoleClientException("At most " + MAX_PATHS + " paths can be checked at once.");
        for (String p : paths) {
            Result r = new Result();
            r.path = p;
            try {
                SshKeyFiles.Checked c = SshKeyFiles.check(p);
                r.ok = true;
                if (c.encrypted) {
                    r.warning = true;
                    r.detail = "Key file found (" + c.format + "). It's protected by a passphrase, so put the passphrase in the server's settings.";
                }
                else
                    r.detail = "Key file found and readable (" + c.format + ").";
            }
            catch (GuacamoleClientException e) {
                r.ok = false;
                r.detail = e.getMessage();
            }
            out.add(r);
        }
        return out;
    }

}
