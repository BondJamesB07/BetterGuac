package com.betterguac.profile;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NoRouteToHostException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import javax.ws.rs.Consumes;
import javax.ws.rs.POST;
import javax.ws.rs.Produces;
import javax.ws.rs.core.MediaType;
import org.apache.guacamole.GuacamoleClientException;
import org.apache.guacamole.GuacamoleException;
import org.apache.guacamole.GuacamoleSecurityException;
import org.apache.guacamole.net.auth.User;
import org.apache.guacamole.net.auth.UserContext;
import org.apache.guacamole.net.auth.permission.SystemPermission;

/**
 * Admin-only reachability check, run from the BetterGuac server's network:
 * a TCP connection to the host and port, then a short protocol handshake
 * (SSH and VNC banners, the RDP X.224 connection confirm).
 *
 * POST api/session/ext/{provider}/connectivity
 * [ { "host": "192.0.2.10", "port": "22", "protocol": "ssh" }, ... ]
 */
public class ConnectivityResource {

    public static final int MAX_TARGETS = 200;
    public static final int CONNECT_TIMEOUT_MS = 3000;
    public static final int READ_TIMEOUT_MS = 3000;
    public static final int THREADS = 16;

    private static final Pattern HOST = Pattern.compile("^[A-Za-z0-9._\\-:%]{1,253}$");

    private static final Map<String, Integer> DEFAULT_PORTS = new HashMap<>();
    static {
        DEFAULT_PORTS.put("ssh", 22);
        DEFAULT_PORTS.put("rdp", 3389);
        DEFAULT_PORTS.put("vnc", 5900);
        DEFAULT_PORTS.put("telnet", 23);
        DEFAULT_PORTS.put("kubernetes", 8080);
    }

    /** X.224 Connection Request with an RDP negotiation request (TLS | CredSSP). */
    private static final byte[] RDP_REQUEST = {
        0x03, 0x00, 0x00, 0x13, 0x0e, (byte) 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00
    };

    private final UserContext userContext;

    public ConnectivityResource(UserContext userContext) {
        this.userContext = userContext;
    }

    public static class Target {
        public String host;
        public String port;
        public String protocol;
    }

    public static class Result {
        public String host;
        public String port;
        public String protocol;
        public boolean ok;
        public String detail;
        public long ms;
    }

    private void requireAdmin() throws GuacamoleException {
        User self = userContext.self();
        if (self == null || !self.getEffectivePermissions().getSystemPermissions()
                .hasPermission(SystemPermission.Type.ADMINISTER))
            throw new GuacamoleSecurityException("Only admins can test server connections.");
    }

    @POST
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public List<Result> check(List<Target> targets) throws GuacamoleException {

        requireAdmin();
        if (targets == null || targets.isEmpty())
            return new ArrayList<>();
        if (targets.size() > MAX_TARGETS)
            throw new GuacamoleClientException("At most " + MAX_TARGETS + " servers can be tested at once.");

        ExecutorService pool = Executors.newFixedThreadPool(Math.min(THREADS, targets.size()));
        try {
            List<Future<Result>> futures = new ArrayList<>();
            for (Target t : targets)
                futures.add(pool.submit(() -> probe(t)));
            List<Result> results = new ArrayList<>();
            for (int i = 0; i < futures.size(); i++) {
                Result r;
                try {
                    r = futures.get(i).get(CONNECT_TIMEOUT_MS + READ_TIMEOUT_MS + 5000L, TimeUnit.MILLISECONDS);
                }
                catch (Exception e) {
                    r = base(targets.get(i));
                    r.detail = "The test didn't finish.";
                }
                results.add(r);
            }
            return results;
        }
        finally {
            pool.shutdownNow();
        }
    }

    private static Result base(Target t) {
        Result r = new Result();
        if (t != null) {
            r.host = t.host;
            r.port = t.port;
            r.protocol = t.protocol;
        }
        return r;
    }

    private static String label(String protocol) {
        switch (protocol) {
            case "telnet": return "Telnet";
            case "kubernetes": return "Kubernetes";
            default: return protocol;
        }
    }

    static Result probe(Target t) {

        Result r = base(t);
        long start = System.nanoTime();

        String protocol = t == null || t.protocol == null ? "" : t.protocol.trim().toLowerCase(Locale.ROOT);
        String host = t == null || t.host == null ? "" : t.host.trim();
        if (host.startsWith("[") && host.endsWith("]"))
            host = host.substring(1, host.length() - 1);
        r.protocol = protocol;

        if (host.isEmpty() || !HOST.matcher(host).matches()) {
            r.detail = "The host isn't valid.";
            return r;
        }

        int port;
        String portText = t.port == null ? "" : t.port.trim();
        if (portText.isEmpty()) {
            Integer def = DEFAULT_PORTS.get(protocol);
            if (def == null) {
                r.detail = "No port given.";
                return r;
            }
            port = def;
        }
        else {
            try {
                port = Integer.parseInt(portText);
            }
            catch (NumberFormatException e) {
                port = -1;
            }
            if (port < 1 || port > 65535) {
                r.detail = "The port isn't valid.";
                return r;
            }
        }
        r.port = Integer.toString(port);

        InetAddress address;
        try {
            address = InetAddress.getByName(host);
        }
        catch (UnknownHostException e) {
            r.detail = "Host name not found.";
            r.ms = elapsed(start);
            return r;
        }

        boolean connected = false;
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(address, port), CONNECT_TIMEOUT_MS);
            connected = true;
            socket.setSoTimeout(READ_TIMEOUT_MS);
            InputStream in = socket.getInputStream();
            OutputStream out = socket.getOutputStream();

            switch (protocol) {

                case "ssh": {
                    String banner = readLine(in, 255);
                    if (banner != null && banner.startsWith("SSH-")) {
                        r.ok = true;
                        r.detail = "SSH answered: " + banner;
                    }
                    else
                        r.detail = "Port " + port + " is open, but it didn't answer like an SSH server.";
                    break;
                }

                case "vnc": {
                    String banner = readLine(in, 12);
                    if (banner != null && banner.startsWith("RFB ")) {
                        r.ok = true;
                        r.detail = "VNC answered: " + banner;
                    }
                    else
                        r.detail = "Port " + port + " is open, but it didn't answer like a VNC server.";
                    break;
                }

                case "rdp": {
                    out.write(RDP_REQUEST);
                    out.flush();
                    byte[] head = new byte[11];
                    int n = readFully(in, head);
                    // TPKT version 3, then an X.224 Connection Confirm (0xD0)
                    if (n >= 6 && head[0] == 0x03 && (head[5] & 0xF0) == 0xD0) {
                        r.ok = true;
                        r.detail = "RDP answered.";
                    }
                    else
                        r.detail = "Port " + port + " is open, but it didn't answer like an RDP server.";
                    break;
                }

                default:
                    r.ok = true;
                    r.detail = "Port " + port + " is open. " + label(protocol)
                            + " isn't checked beyond the port.";
            }
        }
        catch (SocketTimeoutException e) {
            r.detail = connected
                    ? "Port " + port + " is open, but there was no " + protocol.toUpperCase(Locale.ROOT) + " answer within 3 seconds."
                    : "No answer within 3 seconds.";
        }
        catch (ConnectException e) {
            String m = e.getMessage() == null ? "" : e.getMessage().toLowerCase(Locale.ROOT);
            r.detail = m.contains("refused") ? "Connection refused: nothing is listening on port " + port + "."
                     : m.contains("timed out") ? "No answer within 3 seconds."
                     : "Couldn't connect: " + e.getMessage();
        }
        catch (NoRouteToHostException e) {
            r.detail = "No route to this host.";
        }
        catch (IOException e) {
            r.detail = "Couldn't connect: " + e.getMessage();
        }

        if (!r.ok && r.detail == null)
            r.detail = "Couldn't connect.";
        r.ms = elapsed(start);
        return r;
    }

    private static long elapsed(long start) {
        return TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
    }

    /** Reads up to max bytes or to a newline, whichever comes first. */
    private static String readLine(InputStream in, int max) throws IOException {
        StringBuilder sb = new StringBuilder();
        while (sb.length() < max) {
            int c = in.read();
            if (c == -1 || c == '\n')
                break;
            if (c >= 0x20 && c < 0x7f)
                sb.append((char) c);
        }
        String s = sb.toString().trim();
        return s.isEmpty() ? null : s;
    }

    private static int readFully(InputStream in, byte[] buf) throws IOException {
        int total = 0;
        while (total < buf.length) {
            int n = in.read(buf, total, buf.length - total);
            if (n == -1)
                break;
            total += n;
        }
        return total;
    }

}
