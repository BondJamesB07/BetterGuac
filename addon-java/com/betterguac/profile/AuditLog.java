package com.betterguac.profile;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Writes activity-log rows to bg_audit_event (schema migration 001).
 *
 * Writes happen on one background thread so a slow database never holds up a
 * sign-in or a save. A full queue (10,000 rows waiting) drops the row and says
 * so in the Tomcat log rather than blocking the request. If the table doesn't
 * exist yet (the database hasn't been migrated), rows are dropped with one
 * warning, and BetterGuac keeps working as before.
 *
 * Old rows are deleted once a day, the first time something is logged after
 * 24 hours, following the retention settings in bg_setting.
 */
public final class AuditLog {

    private static final Logger logger = LoggerFactory.getLogger(AuditLog.class);

    public static final String RETENTION = "audit.retention-days";
    public static final String SESSION_RETENTION = "audit.session-history-retention-days";

    private static final long DAY_MS = 24L * 60 * 60 * 1000;
    private static final AtomicLong lastPurge = new AtomicLong(0);
    private static volatile boolean missingTableWarned = false;

    private static final ThreadPoolExecutor WRITER = new ThreadPoolExecutor(1, 1, 0L,
            TimeUnit.MILLISECONDS, new ArrayBlockingQueue<Runnable>(10000), r -> {
                Thread t = new Thread(r, "betterguac-audit");
                t.setDaemon(true);
                return t;
            }, (r, ex) -> logger.warn("Activity log queue is full; one event was not recorded."));

    private AuditLog() {}

    /** One activity-log row. Fields left null are stored as NULL. */
    public static final class Event {
        final long time = System.currentTimeMillis();
        String category, action, outcome = "success", actor, remoteAddr,
               targetType, targetId, targetName, detail, source = "web";

        public Event(String category, String action) {
            this.category = category;
            this.action = action;
        }
        public Event outcome(String v)    { outcome = v; return this; }
        public Event actor(String v)      { actor = v; return this; }
        public Event remote(String v)     { remoteAddr = v; return this; }
        public Event target(String type, String id, String name) {
            targetType = type; targetId = id; targetName = name; return this;
        }
        public Event detail(String v)     { detail = v; return this; }
        public Event source(String v)     { source = v; return this; }

        /** Queue this row for writing. Never throws. */
        public void record() {
            try {
                WRITER.execute(() -> write(this));
            }
            catch (RuntimeException e) {
                logger.warn("Activity log event dropped: {}", e.getMessage());
            }
        }
    }

    public static Event event(String category, String action) {
        return new Event(category, action);
    }

    static String cut(String v, int max) {
        if (v == null)
            return null;
        v = v.replaceAll("[\\p{Cntrl}&&[^\\t]]", " ");
        return v.length() <= max ? v : v.substring(0, max - 1) + "\u2026";
    }

    private static void write(Event e) {
        try (Connection db = MfaResource.connectDatabase()) {
            if (e.targetName == null && e.targetId != null)
                e.targetName = nameOf(db, e.targetType, e.targetId);
            e.detail = resolveRefs(db, e.detail);
            try (PreparedStatement st = db.prepareStatement(
                    "INSERT INTO bg_audit_event (event_time, category, action, outcome, actor, remote_addr, "
                  + "target_type, target_id, target_name, detail, source) VALUES (?,?,?,?,?,?,?,?,?,?,?)")) {
                st.setTimestamp(1, new Timestamp(e.time));
                st.setString(2, cut(e.category, 16));
                st.setString(3, cut(e.action, 48));
                st.setString(4, cut(e.outcome, 8));
                st.setString(5, cut(e.actor, 128));
                st.setString(6, cut(e.remoteAddr, 256));
                st.setString(7, cut(e.targetType, 32));
                st.setString(8, cut(e.targetId, 128));
                st.setString(9, cut(e.targetName, 256));
                st.setString(10, cut(e.detail, 1024));
                st.setString(11, cut(e.source, 16));
                st.executeUpdate();
            }
            purgeIfDue(db);
        }
        catch (SQLException ex) {
            if ("42S02".equals(ex.getSQLState())) {
                if (!missingTableWarned) {
                    missingTableWarned = true;
                    logger.warn("Activity log table is missing; run `betterguac-admin migrate` "
                            + "(the Docker image does this on start). Events are not being recorded.");
                }
                return;
            }
            logger.warn("Activity log event not recorded: {}", ex.getMessage());
        }
        catch (Exception ex) {
            logger.warn("Activity log event not recorded: {}", ex.getMessage());
        }
    }

    private static final java.util.regex.Pattern REF =
            java.util.regex.Pattern.compile("\\{(server|folder):([0-9]+)\\}");

    /** Turns {server:3} in a detail into 'Web-01' (id 3). */
    static String resolveRefs(Connection db, String detail) throws SQLException {
        if (detail == null || detail.indexOf('{') < 0)
            return detail;
        java.util.regex.Matcher m = REF.matcher(detail);
        StringBuffer out = new StringBuffer();
        while (m.find()) {
            String name = nameOf(db, m.group(1), m.group(2));
            String text = name == null ? "id " + m.group(2) : "'" + name + "' (id " + m.group(2) + ")";
            m.appendReplacement(out, java.util.regex.Matcher.quoteReplacement(text));
        }
        m.appendTail(out);
        return out.toString();
    }

    /** Display name for a server or server folder id; null if unknown. */
    static String nameOf(Connection db, String type, String id) throws SQLException {
        String sql;
        if ("server".equals(type))
            sql = "SELECT connection_name FROM guacamole_connection WHERE connection_id = ?";
        else if ("folder".equals(type))
            sql = "SELECT connection_group_name FROM guacamole_connection_group WHERE connection_group_id = ?";
        else
            return null;
        long n;
        try {
            n = Long.parseLong(id);
        }
        catch (NumberFormatException ex) {
            return null;
        }
        try (PreparedStatement st = db.prepareStatement(sql)) {
            st.setLong(1, n);
            try (ResultSet rs = st.executeQuery()) {
                return rs.next() ? rs.getString(1) : null;
            }
        }
    }

    static int setting(Connection db, String name, int fallback) throws SQLException {
        try (PreparedStatement st = db.prepareStatement("SELECT value FROM bg_setting WHERE name = ?")) {
            st.setString(1, name);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next())
                    return fallback;
                try {
                    return Integer.parseInt(rs.getString(1).trim());
                }
                catch (NumberFormatException ex) {
                    return fallback;
                }
            }
        }
    }

    private static void purgeIfDue(Connection db) {
        long now = System.currentTimeMillis();
        long last = lastPurge.get();
        if (now - last < DAY_MS || !lastPurge.compareAndSet(last, now))
            return;
        try {
            int[] n = purge(db);
            if (n[0] > 0 || n[1] > 0)
                logger.info("Activity log retention: deleted {} activity rows and {} session history rows.", n[0], n[1]);
        }
        catch (SQLException ex) {
            logger.warn("Activity log retention cleanup failed: {}", ex.getMessage());
        }
    }

    /**
     * Deletes rows older than the retention settings. 0 days keeps everything.
     * Returns { activity rows deleted, session history rows deleted }.
     */
    static int[] purge(Connection db) throws SQLException {
        int[] out = new int[2];
        int days = setting(db, RETENTION, 365);
        if (days > 0) {
            try (PreparedStatement st = db.prepareStatement(
                    "DELETE FROM bg_audit_event WHERE event_time < NOW() - INTERVAL ? DAY")) {
                st.setInt(1, days);
                out[0] = st.executeUpdate();
            }
        }
        int sessionDays = setting(db, SESSION_RETENTION, 0);
        if (sessionDays > 0) {
            // Only finished sessions; a session still open keeps its row
            try (PreparedStatement st = db.prepareStatement(
                    "DELETE FROM guacamole_connection_history WHERE end_date IS NOT NULL "
                  + "AND end_date < NOW() - INTERVAL ? DAY")) {
                st.setInt(1, sessionDays);
                out[1] = st.executeUpdate();
            }
        }
        return out;
    }

    /** Lets tests and the shutdown listener wait for queued rows. */
    static void flush(long millis) {
        long end = System.currentTimeMillis() + millis;
        while ((WRITER.getQueue().size() > 0 || WRITER.getActiveCount() > 0)
                && System.currentTimeMillis() < end) {
            try {
                Thread.sleep(25);
            }
            catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

}
