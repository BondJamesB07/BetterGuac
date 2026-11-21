package com.betterguac.profile;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Deque;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleServerException;
import org.apache.guacamole.net.auth.DelegatingDirectory;
import org.apache.guacamole.net.auth.Directory;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.permission.SystemPermission;

/**
 * Makes removing someone from a server group take effect at once.
 *
 * The database extension works out a person's groups when they sign in and
 * keeps that list for the whole session, so taking them out of a group only
 * mattered after they signed out. For people who aren't admins, this checks
 * the database on every server lookup (list, open, read) and hides any server
 * they can no longer reach through their own permissions or the groups they
 * are in right now. It only ever hides; it never grants anything.
 */
final class LiveServerAccess {

    private LiveServerAccess() {}

    static boolean isAdmin(User self) throws GuacamoleException {
        return self != null && self.getEffectivePermissions().getSystemPermissions()
                .hasPermission(SystemPermission.Type.ADMINISTER);
    }

    /** Server ids the person can read right now, straight from the database. */
    static Set<String> readableNow(String username) throws GuacamoleException {
        try (Connection db = MfaResource.connectDatabase()) {
            Long entityId = null;
            try (PreparedStatement st = db.prepareStatement(
                    "SELECT entity_id FROM guacamole_entity WHERE type = 'USER' AND name = ?")) {
                st.setString(1, username);
                try (ResultSet rs = st.executeQuery()) {
                    if (rs.next())
                        entityId = rs.getLong(1);
                }
            }
            if (entityId == null)
                return Collections.emptySet();

            // The person plus every enabled group they are in now, nested groups included
            Set<Long> entities = new HashSet<>();
            entities.add(entityId);
            Deque<Long> todo = new ArrayDeque<>();
            todo.add(entityId);
            try (PreparedStatement st = db.prepareStatement(
                    "SELECT ug.entity_id FROM guacamole_user_group_member m "
                  + "JOIN guacamole_user_group ug ON ug.user_group_id = m.user_group_id "
                  + "WHERE m.member_entity_id = ? AND ug.disabled = 0")) {
                while (!todo.isEmpty()) {
                    st.setLong(1, todo.poll());
                    try (ResultSet rs = st.executeQuery()) {
                        while (rs.next()) {
                            long g = rs.getLong(1);
                            if (entities.add(g))
                                todo.add(g);
                        }
                    }
                }
            }

            StringBuilder in = new StringBuilder();
            for (int i = 0; i < entities.size(); i++)
                in.append(i == 0 ? "?" : ",?");
            Set<String> ids = new HashSet<>();
            try (PreparedStatement st = db.prepareStatement(
                    "SELECT DISTINCT connection_id FROM guacamole_connection_permission "
                  + "WHERE permission = 'READ' AND entity_id IN (" + in + ")")) {
                int i = 1;
                for (Long e : entities)
                    st.setLong(i++, e);
                try (ResultSet rs = st.executeQuery()) {
                    while (rs.next())
                        ids.add(Long.toString(rs.getLong(1)));
                }
            }
            return ids;
        }
        catch (SQLException e) {
            throw new GuacamoleServerException("Couldn't check server access.", e);
        }
    }

    /** Wraps a connection directory so non-admins only get servers they can reach right now. */
    static Directory<org.apache.guacamole.net.auth.Connection> wrap(
            Directory<org.apache.guacamole.net.auth.Connection> directory, String username) {

        return new DelegatingDirectory<org.apache.guacamole.net.auth.Connection>(directory) {

            @Override
            public org.apache.guacamole.net.auth.Connection get(String identifier) throws GuacamoleException {
                org.apache.guacamole.net.auth.Connection c = super.get(identifier);
                if (c == null || !readableNow(username).contains(identifier))
                    return null;
                return c;
            }

            @Override
            public Collection<org.apache.guacamole.net.auth.Connection> getAll(Collection<String> identifiers)
                    throws GuacamoleException {
                Set<String> allowed = readableNow(username);
                List<String> keep = new ArrayList<>();
                for (String id : identifiers)
                    if (allowed.contains(id))
                        keep.add(id);
                if (keep.isEmpty())
                    return Collections.emptyList();
                return super.getAll(keep);
            }

            @Override
            public Set<String> getIdentifiers() throws GuacamoleException {
                Set<String> ids = new HashSet<>(super.getIdentifiers());
                ids.retainAll(readableNow(username));
                return ids;
            }

        };
    }

}
