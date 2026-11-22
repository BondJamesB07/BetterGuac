package com.betterguac.profile;

import java.util.Collection;
import java.util.Set;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.net.auth.DelegatingUser;
import org.apache.guacamole.net.auth.DelegatingUserGroup;
import org.apache.guacamole.net.auth.RelatedObjectSet;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserGroup;
import org.apache.guacamole.net.auth.permission.ObjectPermission;
import org.apache.guacamole.net.auth.permission.ObjectPermissionSet;
import org.apache.guacamole.net.auth.permission.SystemPermission;
import org.apache.guacamole.net.auth.permission.SystemPermissionSet;

/**
 * Logs permission and membership changes, which Guacamole makes through the
 * permission and group sets of a user or group object and never reports as
 * an event. The user and group directories of ProfileUserContext hand out
 * these wrappers; everything else passes straight through to the database
 * extension's own objects, and update() unwraps them before saving.
 */
final class AuditedObjects {

    private AuditedObjects() {}

    /** Who is making the change, and where they signed in from. */
    static final class Who {
        final String actor, remote;
        Who(String actor, String remote) { this.actor = actor; this.remote = remote; }
    }

    static User unwrap(User user) {
        return user instanceof AuditedUser ? ((AuditedUser) user).undecorated() : user;
    }

    static UserGroup unwrap(UserGroup group) {
        return group instanceof AuditedGroup ? ((AuditedGroup) group).undecorated() : group;
    }

    private static String label(String kind) {
        switch (kind) {
            case "server":  return "Server";
            case "folder":  return "Server folder";
            case "user":    return "User";
            case "group":   return "Server group";
            case "sharing": return "Sharing profile";
            case "session": return "Open session";
            default:        return kind;
        }
    }

    private static void objectRows(Who who, String subjectType, String subjectId, String kind,
            boolean granted, Set<ObjectPermission> perms) {
        if (perms == null)
            return;
        for (ObjectPermission p : perms) {
            AuditLog.event("permission", granted ? "permission.granted" : "permission.revoked")
                    .actor(who.actor).remote(who.remote)
                    .target(subjectType, subjectId, subjectId)
                    .detail(label(kind) + " " + objectRef(kind, p.getObjectIdentifier()) + ": " + p.getType())
                    .record();
        }
    }

    /** Servers and folders are stored by number; AuditLog turns {server:3} into its name. */
    private static String objectRef(String kind, String id) {
        if ("server".equals(kind) || "folder".equals(kind))
            return "{" + kind + ":" + id + "}";
        return "'" + id + "'";
    }

    private static void systemRows(Who who, String subjectType, String subjectId,
            boolean granted, Set<SystemPermission> perms) {
        if (perms == null)
            return;
        for (SystemPermission p : perms) {
            AuditLog.Event row;
            if (p.getType() == SystemPermission.Type.ADMINISTER)
                row = AuditLog.event(subjectType, subjectType + ".role_changed")
                        .detail(granted ? "Admin role granted" : "Admin role removed");
            else
                row = AuditLog.event("permission", granted ? "permission.granted" : "permission.revoked")
                        .detail("System permission: " + p.getType());
            row.actor(who.actor).remote(who.remote).target(subjectType, subjectId, subjectId).record();
        }
    }

    static ObjectPermissionSet objects(final ObjectPermissionSet d, final Who who,
            final String subjectType, final String subjectId, final String kind) {
        if (d == null)
            return null;
        return new ObjectPermissionSet() {
            public boolean hasPermission(ObjectPermission.Type t, String id) throws GuacamoleException {
                return d.hasPermission(t, id);
            }
            public void addPermission(ObjectPermission.Type t, String id) throws GuacamoleException {
                d.addPermission(t, id);
                objectRows(who, subjectType, subjectId, kind, true,
                        java.util.Collections.singleton(new ObjectPermission(t, id)));
            }
            public void removePermission(ObjectPermission.Type t, String id) throws GuacamoleException {
                d.removePermission(t, id);
                objectRows(who, subjectType, subjectId, kind, false,
                        java.util.Collections.singleton(new ObjectPermission(t, id)));
            }
            public Collection<String> getAccessibleObjects(Collection<ObjectPermission.Type> t,
                    Collection<String> ids) throws GuacamoleException {
                return d.getAccessibleObjects(t, ids);
            }
            public Set<ObjectPermission> getPermissions() throws GuacamoleException {
                return d.getPermissions();
            }
            public void addPermissions(Set<ObjectPermission> p) throws GuacamoleException {
                d.addPermissions(p);
                objectRows(who, subjectType, subjectId, kind, true, p);
            }
            public void removePermissions(Set<ObjectPermission> p) throws GuacamoleException {
                d.removePermissions(p);
                objectRows(who, subjectType, subjectId, kind, false, p);
            }
        };
    }

    static SystemPermissionSet system(final SystemPermissionSet d, final Who who,
            final String subjectType, final String subjectId) {
        if (d == null)
            return null;
        return new SystemPermissionSet() {
            public boolean hasPermission(SystemPermission.Type t) throws GuacamoleException {
                return d.hasPermission(t);
            }
            public void addPermission(SystemPermission.Type t) throws GuacamoleException {
                d.addPermission(t);
                systemRows(who, subjectType, subjectId, true, java.util.Collections.singleton(new SystemPermission(t)));
            }
            public void removePermission(SystemPermission.Type t) throws GuacamoleException {
                d.removePermission(t);
                systemRows(who, subjectType, subjectId, false, java.util.Collections.singleton(new SystemPermission(t)));
            }
            public Set<SystemPermission> getPermissions() throws GuacamoleException {
                return d.getPermissions();
            }
            public void addPermissions(Set<SystemPermission> p) throws GuacamoleException {
                d.addPermissions(p);
                systemRows(who, subjectType, subjectId, true, p);
            }
            public void removePermissions(Set<SystemPermission> p) throws GuacamoleException {
                d.removePermissions(p);
                systemRows(who, subjectType, subjectId, false, p);
            }
        };
    }

    /**
     * relation: "member-of" (subject joins/leaves the listed groups) or
     * "members" / "member-groups" (the listed users or groups join/leave the subject group).
     */
    static RelatedObjectSet related(final RelatedObjectSet d, final Who who,
            final String subjectType, final String subjectId, final String relation) {
        if (d == null)
            return null;
        return new RelatedObjectSet() {
            public Set<String> getObjects() throws GuacamoleException {
                return d.getObjects();
            }
            public void addObjects(Set<String> ids) throws GuacamoleException {
                d.addObjects(ids);
                rows(true, ids);
            }
            public void removeObjects(Set<String> ids) throws GuacamoleException {
                d.removeObjects(ids);
                rows(false, ids);
            }
            private void rows(boolean added, Set<String> ids) {
                if (ids == null)
                    return;
                for (String id : ids) {
                    String group, member, memberType;
                    if ("member-of".equals(relation)) {
                        group = id; member = subjectId; memberType = subjectType;
                    }
                    else {
                        group = subjectId; member = id;
                        memberType = "members".equals(relation) ? "user" : "group";
                    }
                    AuditLog.event("group", added ? "group.member_added" : "group.member_removed")
                            .actor(who.actor).remote(who.remote)
                            .target("group", group, group)
                            .detail((memberType.equals("user") ? "User " : "Group ") + "'" + member + "' "
                                    + (added ? "added to" : "removed from") + " '" + group + "'")
                            .record();
                }
            }
        };
    }

    static final class AuditedUser extends DelegatingUser {
        private final Who who;
        AuditedUser(User user, Who who) { super(user); this.who = who; }
        User undecorated() { return getDelegateUser(); }
        private String id() { return getIdentifier(); }
        @Override public SystemPermissionSet getSystemPermissions() throws GuacamoleException {
            return system(super.getSystemPermissions(), who, "user", id());
        }
        @Override public ObjectPermissionSet getConnectionPermissions() throws GuacamoleException {
            return objects(super.getConnectionPermissions(), who, "user", id(), "server");
        }
        @Override public ObjectPermissionSet getConnectionGroupPermissions() throws GuacamoleException {
            return objects(super.getConnectionGroupPermissions(), who, "user", id(), "folder");
        }
        @Override public ObjectPermissionSet getSharingProfilePermissions() throws GuacamoleException {
            return objects(super.getSharingProfilePermissions(), who, "user", id(), "sharing");
        }
        @Override public ObjectPermissionSet getUserPermissions() throws GuacamoleException {
            return objects(super.getUserPermissions(), who, "user", id(), "user");
        }
        @Override public ObjectPermissionSet getUserGroupPermissions() throws GuacamoleException {
            return objects(super.getUserGroupPermissions(), who, "user", id(), "group");
        }
        @Override public RelatedObjectSet getUserGroups() throws GuacamoleException {
            return related(super.getUserGroups(), who, "user", id(), "member-of");
        }
    }

    static final class AuditedGroup extends DelegatingUserGroup {
        private final Who who;
        AuditedGroup(UserGroup group, Who who) { super(group); this.who = who; }
        UserGroup undecorated() { return getDelegateUserGroupGroup(); }
        private String id() { return getIdentifier(); }
        @Override public SystemPermissionSet getSystemPermissions() throws GuacamoleException {
            return system(super.getSystemPermissions(), who, "group", id());
        }
        @Override public ObjectPermissionSet getConnectionPermissions() throws GuacamoleException {
            return objects(super.getConnectionPermissions(), who, "group", id(), "server");
        }
        @Override public ObjectPermissionSet getConnectionGroupPermissions() throws GuacamoleException {
            return objects(super.getConnectionGroupPermissions(), who, "group", id(), "folder");
        }
        @Override public ObjectPermissionSet getSharingProfilePermissions() throws GuacamoleException {
            return objects(super.getSharingProfilePermissions(), who, "group", id(), "sharing");
        }
        @Override public ObjectPermissionSet getUserPermissions() throws GuacamoleException {
            return objects(super.getUserPermissions(), who, "group", id(), "user");
        }
        @Override public ObjectPermissionSet getUserGroupPermissions() throws GuacamoleException {
            return objects(super.getUserGroupPermissions(), who, "group", id(), "group");
        }
        @Override public RelatedObjectSet getUserGroups() throws GuacamoleException {
            return related(super.getUserGroups(), who, "group", id(), "member-of");
        }
        @Override public RelatedObjectSet getMemberUsers() throws GuacamoleException {
            return related(super.getMemberUsers(), who, "group", id(), "members");
        }
        @Override public RelatedObjectSet getMemberUserGroups() throws GuacamoleException {
            return related(super.getMemberUserGroups(), who, "group", id(), "member-groups");
        }
    }

}
