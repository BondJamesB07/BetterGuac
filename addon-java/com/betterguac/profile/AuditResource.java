package com.betterguac.profile;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import javax.ws.rs.Consumes;
import javax.ws.rs.GET;
import javax.ws.rs.POST;
import javax.ws.rs.PUT;
import javax.ws.rs.Path;
import javax.ws.rs.Produces;
import javax.ws.rs.QueryParam;
import javax.ws.rs.core.MediaType;
import javax.ws.rs.core.Response;
import javax.ws.rs.core.StreamingOutput;
import org.apache.guacamole.GuacamoleClientException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleSecurityException;
import org.apache.guacamole.GuacamoleServerException;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserContext;

/**
 * Admin-only activity log: api/session/ext/{provider}/audit/...
 *
 *   GET  events       one page of the merged log, newest first, with filters
 *   GET  export       the same filters as a CSV file (up to 50,000 rows)
 *   GET  settings     retention settings
 *   PUT  settings     change them (logged)
 *   POST purge        apply retention now (logged)
 *
 * The log is bg_audit_event plus session start and end rows read straight
 * from Guacamole's guacamole_connection_history, so sessions recorded before
 * the activity log existed show up too.
 */
public class AuditResource {

    public static final List<String> CATEGORIES = Arrays.asList(
            "auth", "mfa", "session", "user", "group", "server", "permission", "sync", "audit");

    private static final int MAX_PAGE = 500;
    private static final int MAX_EXPORT = 50000;

    private final UserContext userContext;

    public AuditResource(UserContext userContext) {
        this.userContext = userContext;
    }

    private String requireAdmin() throws GuacamoleException {
        User self = userContext.self();
        if (self == null || !LiveServerAccess.isAdmin(self))
            throw new GuacamoleSecurityException("Only admins can see the activity log.");
        return self.getIdentifier();
    }

    private String remote() {
        return userContext instanceof ProfileUserContext ? ((ProfileUserContext) userContext).remoteAddress() : null;
    }

    /* ---------------- shapes ---------------- */

    public static class Event {
        public String id;
        public long time;
        public String category, action, outcome, actor, remoteAddr, targetType, targetName, detail, source;
    }

    public static class Page {
        public long total;
        public int offset;
        public int limit;
        public List<Event> events = new ArrayList<>();
    }

    public static class Settings {
        public Integer retentionDays;
        public Integer sessionRetentionDays;
        public Long oldestEvent;
        public Long eventCount;
        public Long sessionCount;
    }

    public static class PurgeResult {
        public int activityDeleted;
        public int sessionsDeleted;
    }

    /* ---------------- query building ---------------- */

    /** The filters every read takes. */
    static final class Filter {
        Timestamp from, to;
        Set<String> categories = new HashSet<>();
        String actor, outcome, q;

        static Filter of(String from, String to, String categories, String actor, String outcome, String q)
                throws GuacamoleClientException {
            Filter f = new Filter();
            f.from = parseTime(from, false);
            f.to = parseTime(to, true);
            if (categories != null)
                for (String c : categories.split(",")) {
                    c = c.trim().toLowerCase(Locale.ROOT);
                    if (c.isEmpty())
                        continue;
                    if (!CATEGORIES.contains(c))
                        throw new GuacamoleClientException("Unknown category: " + c);
                    f.categories.add(c);
                }
            f.actor = blankToNull(actor);
            f.outcome = blankToNull(outcome);
            if (f.outcome != null && !Arrays.asList("success", "failure", "info").contains(f.outcome))
                throw new GuacamoleClientException("Outcome is success, failure or info.");
            f.q = blankToNull(q);
            if (f.q != null && f.q.length() > 200)
                f.q = f.q.substring(0, 200);
            return f;
        }
    }

    static String blankToNull(String v) {
        return v == null || v.trim().isEmpty() ? null : v.trim();
    }

    /** Accepts epoch milliseconds, YYYY-MM-DD, or YYYY-MM-DDTHH:MM[:SS] (server time). */
    static Timestamp parseTime(String v, boolean endOfDay) throws GuacamoleClientException {
        v = blankToNull(v);
        if (v == null)
            return null;
        try {
            if (v.matches("[0-9]{10,14}"))
                return new Timestamp(Long.parseLong(v));
            if (v.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) {
                Timestamp t = Timestamp.valueOf(v + " 00:00:00");
                return endOfDay ? new Timestamp(t.getTime() + 24L * 3600 * 1000 - 1) : t;
            }
            String s = v.replace('T', ' ');
            if (s.matches("[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}"))
                s += ":00";
            return Timestamp.valueOf(s);
        }
        catch (IllegalArgumentException e) {
            throw new GuacamoleClientException("Couldn't read the date '" + v + "'.");
        }
    }

    private static final String EVENTS =
        "SELECT CONCAT('e', event_id) AS id, event_time AS t, category, action, outcome, actor, "
      + "remote_addr, target_type, target_name, detail, source FROM bg_audit_event WHERE 1=1";

    private static final String STARTS =
        "SELECT CONCAT('s', history_id) AS id, start_date AS t, 'session' AS category, 'session.start' AS action, "
      + "'success' AS outcome, username AS actor, remote_host AS remote_addr, 'server' AS target_type, "
      + "connection_name AS target_name, "
      + "CASE WHEN sharing_profile_name IS NOT NULL THEN CONCAT('Joined a shared session (', sharing_profile_name, ')') "
      + "WHEN end_date IS NULL THEN 'Session started (still open)' ELSE 'Session started' END AS detail, "
      + "'web' AS source FROM guacamole_connection_history WHERE 1=1";

    private static final String ENDS =
        "SELECT CONCAT('x', history_id) AS id, end_date AS t, 'session' AS category, 'session.end' AS action, "
      + "'info' AS outcome, username AS actor, remote_host AS remote_addr, 'server' AS target_type, "
      + "connection_name AS target_name, "
      + "CONCAT('Session ended after ', "
      + "CASE WHEN TIMESTAMPDIFF(SECOND, start_date, end_date) < 60 THEN CONCAT(TIMESTAMPDIFF(SECOND, start_date, end_date), ' s') "
      + "WHEN TIMESTAMPDIFF(SECOND, start_date, end_date) < 3600 THEN CONCAT(TIMESTAMPDIFF(MINUTE, start_date, end_date), ' min') "
      + "ELSE CONCAT(TIMESTAMPDIFF(HOUR, start_date, end_date), ' h ', MOD(TIMESTAMPDIFF(MINUTE, start_date, end_date), 60), ' min') END) AS detail, "
      + "'web' AS source FROM guacamole_connection_history WHERE end_date IS NOT NULL";

    /**
     * The merged log as one SELECT, with filters pushed into each branch so
     * the time indexes are used. Parameters are appended to args in order.
     */
    static String merged(Filter f, List<Object> args) {
        List<String> parts = new ArrayList<>();
        boolean anyCat = f.categories.isEmpty();
        boolean wantEvents = anyCat || !(f.categories.size() == 1 && f.categories.contains("session"));
        boolean wantSessions = anyCat || f.categories.contains("session");

        if (wantEvents) {
            StringBuilder s = new StringBuilder(EVENTS);
            if (!anyCat) {
                s.append(" AND category IN (");
                int i = 0;
                for (String c : f.categories) {
                    s.append(i++ == 0 ? "?" : ",?");
                    args.add(c);
                }
                s.append(")");
            }
            common(s, f, args, "event_time", "actor", "outcome",
                    new String[] { "actor", "target_name", "detail", "remote_addr", "action" });
            parts.add(s.toString());
        }
        if (wantSessions) {
            if (f.outcome == null || f.outcome.equals("success")) {
                StringBuilder s = new StringBuilder(STARTS);
                common(s, f, args, "start_date", "username", null,
                        new String[] { "username", "connection_name", "remote_host" });
                parts.add(s.toString());
            }
            if (f.outcome == null || f.outcome.equals("info")) {
                StringBuilder s = new StringBuilder(ENDS);
                common(s, f, args, "end_date", "username", null,
                        new String[] { "username", "connection_name", "remote_host" });
                parts.add(s.toString());
            }
        }
        if (parts.isEmpty())
            return EVENTS + " AND 1=0";
        return String.join(" UNION ALL ", parts);
    }

    private static void common(StringBuilder s, Filter f, List<Object> args, String time,
            String actorCol, String outcomeCol, String[] searchCols) {
        if (f.from != null) {
            s.append(" AND ").append(time).append(" >= ?");
            args.add(f.from);
        }
        if (f.to != null) {
            s.append(" AND ").append(time).append(" <= ?");
            args.add(f.to);
        }
        if (f.actor != null) {
            s.append(" AND ").append(actorCol).append(" = ?");
            args.add(f.actor);
        }
        if (f.outcome != null && outcomeCol != null) {
            s.append(" AND ").append(outcomeCol).append(" = ?");
            args.add(f.outcome);
        }
        if (f.q != null) {
            String like = "%" + f.q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
            s.append(" AND (");
            for (int i = 0; i < searchCols.length; i++) {
                s.append(i == 0 ? "" : " OR ").append(searchCols[i]).append(" LIKE ?");
                args.add(like);
            }
            s.append(")");
        }
    }

    private static void bind(PreparedStatement st, List<Object> args) throws SQLException {
        for (int i = 0; i < args.size(); i++) {
            Object a = args.get(i);
            if (a instanceof Timestamp)
                st.setTimestamp(i + 1, (Timestamp) a);
            else if (a instanceof Integer)
                st.setInt(i + 1, (Integer) a);
            else
                st.setString(i + 1, String.valueOf(a));
        }
    }

    private static Event row(ResultSet rs) throws SQLException {
        Event e = new Event();
        e.id = rs.getString(1);
        Timestamp t = rs.getTimestamp(2);
        e.time = t == null ? 0 : t.getTime();
        e.category = rs.getString(3);
        e.action = rs.getString(4);
        e.outcome = rs.getString(5);
        e.actor = rs.getString(6);
        e.remoteAddr = rs.getString(7);
        e.targetType = rs.getString(8);
        e.targetName = rs.getString(9);
        e.detail = rs.getString(10);
        e.source = rs.getString(11);
        return e;
    }

    private static GuacamoleException dbError(SQLException e) {
        if ("42S02".equals(e.getSQLState()))
            return new GuacamoleServerException("The activity log table is missing. "
                    + "Run: sudo betterguac-admin migrate", e);
        return new GuacamoleServerException("Couldn't read the activity log.", e);
    }

    /* ---------------- endpoints ---------------- */

    @GET
    @Path("events")
    @Produces(MediaType.APPLICATION_JSON)
    public Page events(@QueryParam("from") String from, @QueryParam("to") String to,
            @QueryParam("category") String category, @QueryParam("actor") String actor,
            @QueryParam("outcome") String outcome, @QueryParam("q") String q,
            @QueryParam("limit") Integer limit, @QueryParam("offset") Integer offset)
            throws GuacamoleException {
        requireAdmin();
        Filter f = Filter.of(from, to, category, actor, outcome, q);
        Page page = new Page();
        page.limit = Math.max(1, Math.min(limit == null ? 100 : limit, MAX_PAGE));
        page.offset = Math.max(0, offset == null ? 0 : offset);

        try (Connection db = MfaResource.connectDatabase()) {
            List<Object> args = new ArrayList<>();
            String union = merged(f, args);
            try (PreparedStatement st = db.prepareStatement("SELECT COUNT(*) FROM (" + union + ") a")) {
                bind(st, args);
                try (ResultSet rs = st.executeQuery()) {
                    rs.next();
                    page.total = rs.getLong(1);
                }
            }
            args.add(page.limit);
            args.add(page.offset);
            try (PreparedStatement st = db.prepareStatement(
                    "SELECT * FROM (" + union + ") a ORDER BY t DESC, id DESC LIMIT ? OFFSET ?")) {
                bind(st, args);
                try (ResultSet rs = st.executeQuery()) {
                    while (rs.next())
                        page.events.add(row(rs));
                }
            }
        }
        catch (SQLException e) {
            throw dbError(e);
        }
        return page;
    }

    static String csv(String v) {
        if (v == null)
            return "";
        // Keep spreadsheets from running a cell as a formula
        if (!v.isEmpty() && "=+-@\t\r".indexOf(v.charAt(0)) >= 0)
            v = "'" + v;
        if (v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r"))
            return "\"" + v.replace("\"", "\"\"") + "\"";
        return v;
    }

    @GET
    @Path("export")
    @Produces("text/csv")
    public Response export(@QueryParam("from") String from, @QueryParam("to") String to,
            @QueryParam("category") String category, @QueryParam("actor") String actor,
            @QueryParam("outcome") String outcome, @QueryParam("q") String q)
            throws GuacamoleException {
        String me = requireAdmin();
        Filter f = Filter.of(from, to, category, actor, outcome, q);
        final List<Event> rows = new ArrayList<>();
        try (Connection db = MfaResource.connectDatabase()) {
            List<Object> args = new ArrayList<>();
            String union = merged(f, args);
            args.add(MAX_EXPORT);
            try (PreparedStatement st = db.prepareStatement(
                    "SELECT * FROM (" + union + ") a ORDER BY t DESC, id DESC LIMIT ?")) {
                bind(st, args);
                try (ResultSet rs = st.executeQuery()) {
                    while (rs.next())
                        rows.add(row(rs));
                }
            }
        }
        catch (SQLException e) {
            throw dbError(e);
        }

        StringBuilder what = new StringBuilder("Exported " + rows.size() + " rows as CSV");
        if (!f.categories.isEmpty()) what.append("; categories ").append(String.join(",", f.categories));
        if (f.actor != null) what.append("; user ").append(f.actor);
        if (f.from != null) what.append("; from ").append(f.from);
        if (f.to != null) what.append("; to ").append(f.to);
        if (f.q != null) what.append("; search '").append(f.q).append("'");
        AuditLog.event("audit", "audit.exported").actor(me).remote(remote()).detail(what.toString()).record();

        final SimpleDateFormat iso = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX");
        iso.setTimeZone(TimeZone.getDefault());
        StreamingOutput body = out -> {
            StringBuilder sb = new StringBuilder("time,category,action,outcome,user,from,target_type,target,detail,source\r\n");
            for (Event e : rows) {
                sb.append(csv(iso.format(new Date(e.time)))).append(',')
                  .append(csv(e.category)).append(',').append(csv(e.action)).append(',')
                  .append(csv(e.outcome)).append(',').append(csv(e.actor)).append(',')
                  .append(csv(e.remoteAddr)).append(',').append(csv(e.targetType)).append(',')
                  .append(csv(e.targetName)).append(',').append(csv(e.detail)).append(',')
                  .append(csv(e.source)).append("\r\n");
                if (sb.length() > 65536) {
                    out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
                    sb.setLength(0);
                }
            }
            out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        };
        String name = "betterguac-activity-" + new SimpleDateFormat("yyyyMMdd-HHmmss").format(new Date()) + ".csv";
        return Response.ok(body, "text/csv; charset=utf-8")
                .header("Content-Disposition", "attachment; filename=\"" + name + "\"")
                .header("Cache-Control", "no-store")
                .build();
    }

    @GET
    @Path("settings")
    @Produces(MediaType.APPLICATION_JSON)
    public Settings settings() throws GuacamoleException {
        requireAdmin();
        Settings s = new Settings();
        try (Connection db = MfaResource.connectDatabase()) {
            s.retentionDays = AuditLog.setting(db, AuditLog.RETENTION, 365);
            s.sessionRetentionDays = AuditLog.setting(db, AuditLog.SESSION_RETENTION, 0);
            try (PreparedStatement st = db.prepareStatement(
                    "SELECT (SELECT MIN(event_time) FROM bg_audit_event), (SELECT COUNT(*) FROM bg_audit_event), "
                  + "(SELECT COUNT(*) FROM guacamole_connection_history)");
                 ResultSet rs = st.executeQuery()) {
                rs.next();
                Timestamp t = rs.getTimestamp(1);
                s.oldestEvent = t == null ? null : t.getTime();
                s.eventCount = rs.getLong(2);
                s.sessionCount = rs.getLong(3);
            }
        }
        catch (SQLException e) {
            throw dbError(e);
        }
        return s;
    }

    private static int checkDays(Integer v, String what) throws GuacamoleClientException {
        if (v == null || v < 0 || v > 3650)
            throw new GuacamoleClientException(what + " must be a number of days from 0 to 3650 (0 keeps everything).");
        return v;
    }

    private static void put(Connection db, String name, int value, String by) throws SQLException {
        try (PreparedStatement st = db.prepareStatement(
                "INSERT INTO bg_setting (name, value, updated_by) VALUES (?, ?, ?) "
              + "ON DUPLICATE KEY UPDATE value = VALUES(value), updated_by = VALUES(updated_by)")) {
            st.setString(1, name);
            st.setString(2, Integer.toString(value));
            st.setString(3, by);
            st.executeUpdate();
        }
    }

    @PUT
    @Path("settings")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Settings saveSettings(Settings body) throws GuacamoleException {
        String me = requireAdmin();
        if (body == null)
            throw new GuacamoleClientException("Nothing to save.");
        int days = checkDays(body.retentionDays, "Activity retention");
        int sessionDays = checkDays(body.sessionRetentionDays, "Session history retention");
        if (days > 0 && days < 7)
            throw new GuacamoleClientException("Keep activity for at least 7 days, or 0 to keep everything.");
        try (Connection db = MfaResource.connectDatabase()) {
            int oldDays = AuditLog.setting(db, AuditLog.RETENTION, 365);
            int oldSession = AuditLog.setting(db, AuditLog.SESSION_RETENTION, 0);
            put(db, AuditLog.RETENTION, days, me);
            put(db, AuditLog.SESSION_RETENTION, sessionDays, me);
            if (oldDays != days || oldSession != sessionDays)
                AuditLog.event("audit", "audit.settings_changed").actor(me).remote(remote())
                        .detail("Activity retention " + label(oldDays) + " -> " + label(days)
                                + "; session history " + label(oldSession) + " -> " + label(sessionDays))
                        .record();
        }
        catch (SQLException e) {
            throw dbError(e);
        }
        return settings();
    }

    private static String label(int days) {
        return days == 0 ? "forever" : days + " days";
    }

    @POST
    @Path("purge")
    @Produces(MediaType.APPLICATION_JSON)
    public PurgeResult purge() throws GuacamoleException {
        String me = requireAdmin();
        PurgeResult r = new PurgeResult();
        try (Connection db = MfaResource.connectDatabase()) {
            int[] n = AuditLog.purge(db);
            r.activityDeleted = n[0];
            r.sessionsDeleted = n[1];
        }
        catch (SQLException e) {
            throw dbError(e);
        }
        AuditLog.event("audit", "audit.purged").actor(me).remote(remote())
                .detail("Applied retention now: deleted " + r.activityDeleted + " activity rows and "
                        + r.sessionsDeleted + " session history rows")
                .record();
        return r;
    }

}
