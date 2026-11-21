package com.betterguac.profile;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Set;
import javax.ws.rs.DELETE;
import javax.ws.rs.GET;
import javax.ws.rs.Path;
import javax.ws.rs.PathParam;
import javax.ws.rs.Produces;
import javax.ws.rs.core.MediaType;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleResourceNotFoundException;
import org.apache.guacamole.net.GuacamoleTunnel;
import org.apache.guacamole.net.auth.ActiveConnection;
import org.apache.guacamole.net.auth.Directory;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserContext;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * The caller's own open sessions, for Resume and Disconnect on the home page.
 *
 * GET    api/session/ext/{provider}/sessions        lists the caller's sessions
 * DELETE api/session/ext/{provider}/sessions/{id}   ends one of them
 *
 * Admins and standard users alike only ever get and end their own sessions
 * here. (Admins still manage everyone's from Guacamole's session list.)
 */
public class SessionsResource {

    private static final Logger logger = LoggerFactory.getLogger(SessionsResource.class);

    private final UserContext userContext;

    public SessionsResource(UserContext userContext) {
        this.userContext = userContext;
    }

    public static class Session {
        public String id;
        public String connectionIdentifier;
        public Long startDate;
        public String remoteHost;
    }

    private String me() throws GuacamoleException {
        User self = userContext.self();
        return self == null ? null : self.getIdentifier();
    }

    private static boolean mine(ActiveConnection ac, String me) {
        return ac != null && me != null && me.equals(ac.getUsername());
    }

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public List<Session> list() throws GuacamoleException {
        String me = me();
        if (me == null)
            return Collections.emptyList();
        Directory<ActiveConnection> dir = userContext.getActiveConnectionDirectory();
        Set<String> ids = dir.getIdentifiers();
        List<Session> out = new ArrayList<>();
        if (ids.isEmpty())
            return out;
        Collection<ActiveConnection> all = dir.getAll(ids);
        for (ActiveConnection ac : all) {
            if (!mine(ac, me) || ac.getConnectionIdentifier() == null)
                continue;
            Session s = new Session();
            s.id = ac.getIdentifier();
            s.connectionIdentifier = ac.getConnectionIdentifier();
            Date start = ac.getStartDate();
            s.startDate = start == null ? null : start.getTime();
            s.remoteHost = ac.getRemoteHost();
            out.add(s);
        }
        return out;
    }

    @DELETE
    @Path("{id}")
    public void end(@PathParam("id") String id) throws GuacamoleException {
        String me = me();
        Directory<ActiveConnection> dir = userContext.getActiveConnectionDirectory();
        ActiveConnection ac = id == null ? null : dir.get(id);
        // Someone else's session reads the same as one that doesn't exist
        if (!mine(ac, me))
            throw new GuacamoleResourceNotFoundException("No such session.");
        GuacamoleTunnel tunnel = ac.getTunnel();
        if (tunnel != null && tunnel.isOpen()) {
            tunnel.close();
            logger.info("{} ended their session {} on server {}", me, id, ac.getConnectionIdentifier());
            return;
        }
        dir.remove(id);
    }

}
